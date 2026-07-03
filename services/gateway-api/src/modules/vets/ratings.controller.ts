import { BadRequestException, Controller, Get, Param, Patch, Post, Body, UseGuards, NotFoundException } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { ValidatorService } from '../config/validator.service';

type SurveyPromptAnswer = 'now' | 'later' | 'dismiss';
type SurveyStatus = 'pending' | 'accepted' | 'declined' | 'deferred' | 'completed' | 'dismissed';
type TxQuery = <R = any>(sql: string, args?: any[]) => Promise<{ rows: R[] }>;

const SURVEY_DEFER_INTERVAL = '24 hours';
const SURVEY_SCORE_OPTIONS = [
  { label: 'Excelente', score: 5 },
  { label: 'Buena', score: 4 },
  { label: 'Regular', score: 3 },
  { label: 'Mala', score: 2 },
  { label: 'Pésima', score: 1 },
];
const SURVEY_QUESTIONS = {
  vetAssistance: '¿Cómo calificas la asistencia proporcionada por parte del veterinario?',
  appService: '¿Cómo calificas el funcionamiento general de la aplicación?',
  openFeedback: '¿Hay algo más que quieras contarnos?',
};

@Controller()
@UseGuards(AuthGuard)
export class RatingsController {
  constructor(
    private readonly db: DbService,
    private readonly rc: RequestContext,
    private readonly validator: ValidatorService,
  ) {}

  private surveyLog(event: string, metadata: Record<string, any> = {}) {
    console.log(JSON.stringify({
      scope: 'consult_survey',
      component: 'ratings',
      event,
      at: new Date().toISOString(),
      ...metadata,
    }));
  }

  private surveyMeta() {
    return {
      deferHours: 24,
      questions: SURVEY_QUESTIONS,
      scoreOptions: SURVEY_SCORE_OPTIONS,
    };
  }

  private normalizeSurvey(row: any) {
    if (!row) return null;
    return {
      id: row.id,
      sessionId: row.session_id,
      userId: row.user_id,
      vetId: row.vet_id,
      petId: row.pet_id,
      status: row.status,
      promptedAt: row.prompted_at,
      acceptedAt: row.accepted_at,
      declinedAt: row.declined_at,
      deferredAt: row.deferred_at,
      nextPromptAt: row.next_prompt_at,
      completedAt: row.completed_at,
      vetAssistanceScore: row.vet_assistance_score,
      appServiceScore: row.app_service_score,
      openFeedback: row.open_feedback,
      source: row.source,
      metadata: row.metadata || {},
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }

  private normalizeSurveySession(row: any) {
    if (!row) return null;
    return {
      id: row.id,
      userId: row.user_id,
      vetId: row.vet_id,
      petId: row.pet_id,
      mode: row.mode,
      status: row.status,
      petName: row.pet_name,
      vetName: row.vet_name,
      roomFinishedAt: row.room_finished_at,
      endReason: row.end_reason,
    };
  }

  private surveyResponse(args: { eligible: boolean; reason?: string | null; survey?: any; session?: any }) {
    return {
      ok: true,
      eligible: args.eligible,
      reason: args.reason || null,
      session: this.normalizeSurveySession(args.session),
      survey: this.normalizeSurvey(args.survey),
      ...this.surveyMeta(),
    };
  }

  private validateSurveyScore(value: unknown, name: string) {
    if (value === undefined || value === null || value === '') return null;
    const score = Number(value);
    if (!Number.isInteger(score) || score < 1 || score > 5) {
      throw new BadRequestException(`${name}_must_be_integer_between_1_and_5`);
    }
    return score;
  }

  private validateSurveyStatus(value: unknown): SurveyStatus | null {
    const status = String(value || '').trim().toLowerCase();
    if (!status) return null;
    if (!['pending', 'accepted', 'declined', 'deferred', 'completed', 'dismissed'].includes(status)) {
      throw new BadRequestException('invalid_survey_status');
    }
    return status as SurveyStatus;
  }

  private async loadSurveySession(q: TxQuery, sessionId: string) {
    const { rows } = await q<any>(
      `select s.id,
              s.user_id,
              s.vet_id,
              s.pet_id,
              s.mode,
              s.status,
              p.name as pet_name,
              vu.full_name as vet_name,
              v.room_finished_at,
              coalesce(v.end_reason, v.safety_reason) as end_reason
         from chat_sessions s
    left join pets p on p.id = s.pet_id
    left join users vu on vu.id = s.vet_id
    left join video_session_lifecycle v on v.session_id = s.id
        where s.id = $1::uuid
        limit 1`,
      [sessionId]
    );
    return rows[0] || null;
  }

  private surveyEligibility(session: any) {
    if (!session) return { eligible: false, reason: 'session_not_found' };
    if (!session.vet_id) return { eligible: false, reason: 'session_has_no_vet' };
    const status = String(session.status || '').toLowerCase();
    const mode = String(session.mode || '').toLowerCase();
    const closed = ['completed', 'canceled', 'no_show'].includes(status);
    const videoEnded = mode === 'video' && (!!session.room_finished_at || !!session.end_reason);
    if (closed || videoEnded) return { eligible: true, reason: null };
    return { eligible: false, reason: 'consult_not_finished' };
  }

  private async loadExistingSurvey(q: TxQuery, sessionId: string, userId: string) {
    const { rows } = await q<any>(
      `select *
         from consult_surveys
        where session_id = $1::uuid
          and user_id = $2::uuid
        limit 1`,
      [sessionId, userId]
    );
    return rows[0] || null;
  }

  private async ensureSurvey(q: TxQuery, sessionId: string, actorId: string) {
    const session = await this.loadSurveySession(q, sessionId);
    if (!session) throw new NotFoundException('not_found');
    if (!this.rc.isAdmin && session.user_id !== actorId) throw new BadRequestException('only_session_owner_can_answer_survey');
    const existing = await this.loadExistingSurvey(q, sessionId, session.user_id);
    if (existing) return { eligible: true, reason: null, session, survey: existing };
    const eligibility = this.surveyEligibility(session);
    if (!eligibility.eligible) return { ...eligibility, session, survey: null };
    const { rows } = await q<any>(
      `insert into consult_surveys (session_id, user_id, vet_id, pet_id, status, prompted_at, next_prompt_at, source, metadata)
       values ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 'pending', now(), now(), 'post_call_chat', jsonb_build_object('createdBy', $5::text))
       returning *`,
      [session.id, session.user_id, session.vet_id, session.pet_id, actorId]
    );
    this.surveyLog('created', { sessionId, userId: session.user_id, vetId: session.vet_id, source: 'post_call_chat' });
    return { eligible: true, reason: null, session, survey: rows[0] };
  }

  private async upsertRatingFromSurvey(q: TxQuery, survey: any) {
    const comment = typeof survey.open_feedback === 'string' && survey.open_feedback.trim()
      ? survey.open_feedback.trim()
      : null;
    const { rows: existingRows } = await q<{ id: string }>(
      `select id
         from ratings
        where session_id = $1::uuid
          and user_id = $2::uuid
        limit 1`,
      [survey.session_id, survey.user_id]
    );
    if (existingRows[0]) {
      const { rows } = await q<any>(
        `update ratings
            set score = $2,
                comment = $3,
                search_tsv = es_en_tsv(coalesce($3, ''))
          where id = $1::uuid
          returning id, session_id, vet_id, user_id, score, comment, created_at`,
        [existingRows[0].id, survey.vet_assistance_score, comment]
      );
      return rows[0];
    }
    const { rows } = await q<any>(
      `insert into ratings (id, session_id, vet_id, user_id, score, comment, created_at, search_tsv)
       values (gen_random_uuid(), $1::uuid, $2::uuid, $3::uuid, $4, $5, now(), es_en_tsv(coalesce($5, '')))
       returning id, session_id, vet_id, user_id, score, comment, created_at`,
      [survey.session_id, survey.vet_id, survey.user_id, survey.vet_assistance_score, comment]
    );
    return rows[0];
  }

  @Get('vets/:vetId/ratings')
  async listForVet(@Param('vetId') vetId: string) {
    this.validator.validateUUID(vetId, 'vetId');
    if (this.db.isStub) return { data: [] } as any;
    const { rows } = await this.db.query(
      `select r.id,
              r.session_id,
              r.vet_id,
              r.user_id,
              r.score,
              r.comment,
              r.created_at,
              u.full_name as user_name
         from ratings r
         join users u on u.id = r.user_id
        where r.vet_id = $1::uuid
        order by r.created_at desc`,
      [vetId]
    );
    return { data: rows };
  }

  @Post('sessions/:sessionId/ratings')
  async createForSession(
    @Param('sessionId') sessionId: string,
    @Body() body: { score?: number; comment?: string }
  ) {
    this.validator.validateUUID(sessionId, 'sessionId');
    const actorId = this.rc.requireUuidUserId();
    const score = Number(body?.score);
    if (!Number.isInteger(score) || score < 1 || score > 5) {
      throw new BadRequestException('score must be an integer between 1 and 5');
    }
    const comment = typeof body?.comment === 'string' ? body.comment.trim() : null;

    if (this.db.isStub) {
      return {
        id: `rating_${Date.now()}`,
        session_id: sessionId,
        vet_id: null,
        user_id: actorId,
        score,
        comment,
      } as any;
    }

    const row = await this.db.runInTx(async (q) => {
      const { rows: actorRows } = await q<{ role: string }>(
        `select role from users where id = $1::uuid limit 1`,
        [actorId]
      );
      const actorRole = actorRows[0]?.role;
      const { rows: sessionRows } = await q<any>(
        `select id, user_id, vet_id, status
           from chat_sessions
          where id = $1::uuid
          limit 1`,
        [sessionId]
      );
      const session = sessionRows[0];
      if (!session) throw new NotFoundException('not_found');
      if (!session.vet_id) throw new BadRequestException('session_has_no_vet');
      if (actorRole !== 'admin' && session.user_id !== actorId) {
        throw new BadRequestException('only_session_owner_can_rate');
      }
      if (actorRole !== 'admin' && session.status !== 'completed') {
        throw new BadRequestException('rating_requires_completed_session');
      }

      const { rows: existingRows } = await q<{ id: string }>(
        `select id
           from ratings
          where session_id = $1::uuid
            and user_id = $2::uuid
          limit 1`,
        [sessionId, actorId]
      );

      if (existingRows[0]) {
        const { rows } = await q<any>(
          `update ratings
              set score = $2,
                  comment = $3,
                  search_tsv = es_en_tsv(coalesce($3, ''))
            where id = $1::uuid
            returning id, session_id, vet_id, user_id, score, comment, created_at`,
          [existingRows[0].id, score, comment]
        );
        return rows[0];
      }

      const { rows } = await q<any>(
        `insert into ratings (id, session_id, vet_id, user_id, score, comment, created_at, search_tsv)
         values (gen_random_uuid(), $1::uuid, $2::uuid, $3::uuid, $4, $5, now(), es_en_tsv(coalesce($5, '')))
         returning id, session_id, vet_id, user_id, score, comment, created_at`,
        [sessionId, session.vet_id, actorId, score, comment]
      );
      return rows[0];
    });

    return row;
  }

  @Get('sessions/:sessionId/survey')
  async getSurvey(@Param('sessionId') sessionId: string) {
    this.validator.validateUUID(sessionId, 'sessionId');
    const actorId = this.rc.requireUuidUserId();
    if (this.db.isStub) return this.surveyResponse({ eligible: false, reason: 'stub_mode' });
    const result = await this.db.runInTx(async (q) => this.ensureSurvey(q, sessionId, actorId));
    return this.surveyResponse(result);
  }

  @Post('sessions/:sessionId/survey/prompt-response')
  async answerSurveyPrompt(
    @Param('sessionId') sessionId: string,
    @Body() body: { answer?: SurveyPromptAnswer }
  ) {
    this.validator.validateUUID(sessionId, 'sessionId');
    const actorId = this.rc.requireUuidUserId();
    const answer = String(body?.answer || '').trim().toLowerCase() as SurveyPromptAnswer;
    if (!['now', 'later', 'dismiss'].includes(answer)) throw new BadRequestException('invalid_prompt_answer');
    if (this.db.isStub) return this.surveyResponse({ eligible: false, reason: 'stub_mode' });

    const result = await this.db.runInTx(async (q) => {
      const ensured = await this.ensureSurvey(q, sessionId, actorId);
      if (!ensured.eligible || !ensured.survey) throw new BadRequestException(ensured.reason || 'survey_not_eligible');
      const status = answer === 'now' ? 'accepted' : answer === 'later' ? 'deferred' : 'dismissed';
      const { rows } = await q<any>(
        `update consult_surveys
            set status = $2,
                prompted_at = coalesce(prompted_at, now()),
                accepted_at = case when $2 = 'accepted' then coalesce(accepted_at, now()) else accepted_at end,
                deferred_at = case when $2 = 'deferred' then now() else deferred_at end,
                declined_at = case when $2 = 'dismissed' then coalesce(declined_at, now()) else declined_at end,
                next_prompt_at = case when $2 = 'deferred' then now() + $3::interval else null end,
                metadata = metadata || jsonb_build_object('lastPromptAnswer', $4::text)
          where id = $1::uuid
          returning *`,
        [ensured.survey.id, status, SURVEY_DEFER_INTERVAL, answer]
      );
      this.surveyLog('prompt_answered', { sessionId, surveyId: ensured.survey.id, answer, status });
      return { ...ensured, survey: rows[0] };
    });
    return this.surveyResponse(result);
  }

  @Patch('sessions/:sessionId/survey')
  async updateSurvey(
    @Param('sessionId') sessionId: string,
    @Body() body: { vetAssistanceScore?: number; appServiceScore?: number; openFeedback?: string | null; status?: SurveyStatus }
  ) {
    this.validator.validateUUID(sessionId, 'sessionId');
    const actorId = this.rc.requireUuidUserId();
    const vetScore = this.validateSurveyScore(body?.vetAssistanceScore, 'vet_assistance_score');
    const appScore = this.validateSurveyScore(body?.appServiceScore, 'app_service_score');
    const status = this.validateSurveyStatus(body?.status);
    const feedbackProvided = Object.prototype.hasOwnProperty.call(body || {}, 'openFeedback');
    const openFeedback = feedbackProvided && typeof body?.openFeedback === 'string' ? body.openFeedback.trim() : null;
    if (this.db.isStub) return this.surveyResponse({ eligible: false, reason: 'stub_mode' });

    const result = await this.db.runInTx(async (q) => {
      const ensured = await this.ensureSurvey(q, sessionId, actorId);
      if (!ensured.eligible || !ensured.survey) throw new BadRequestException(ensured.reason || 'survey_not_eligible');
      const currentVetScore = vetScore ?? ensured.survey.vet_assistance_score;
      const currentAppScore = appScore ?? ensured.survey.app_service_score;
      const complete = status === 'completed';
      if (complete && (!currentVetScore || !currentAppScore)) {
        throw new BadRequestException('survey_completion_requires_vet_and_app_scores');
      }
      const nextStatus = complete ? 'completed' : status || (ensured.survey.status === 'pending' || ensured.survey.status === 'deferred' ? 'accepted' : ensured.survey.status);
      const { rows } = await q<any>(
        `update consult_surveys
            set vet_assistance_score = coalesce($2::int, vet_assistance_score),
                app_service_score = coalesce($3::int, app_service_score),
                open_feedback = case when $4 then $5 else open_feedback end,
                status = $6,
                accepted_at = case when $6 in ('accepted', 'completed') then coalesce(accepted_at, now()) else accepted_at end,
                completed_at = case when $6 = 'completed' then coalesce(completed_at, now()) else completed_at end,
                next_prompt_at = case when $6 in ('accepted', 'completed') then null else next_prompt_at end,
                metadata = metadata || jsonb_build_object('lastPatchBy', $7::text)
          where id = $1::uuid
          returning *`,
        [ensured.survey.id, vetScore, appScore, feedbackProvided, openFeedback, nextStatus, actorId]
      );
      const survey = rows[0];
      let rating: any = null;
      if (survey.status === 'completed') rating = await this.upsertRatingFromSurvey(q, survey);
      this.surveyLog('updated', {
        sessionId,
        surveyId: survey.id,
        status: survey.status,
        hasVetScore: !!survey.vet_assistance_score,
        hasAppScore: !!survey.app_service_score,
        hasFeedback: !!survey.open_feedback,
        ratingId: rating?.id || null,
      });
      return { ...ensured, survey, rating };
    });
    return { ...this.surveyResponse(result), rating: result.rating || null };
  }

  @Get('me/surveys/pending')
  async listPendingSurveys() {
    const actorId = this.rc.requireUuidUserId();
    if (this.db.isStub) return { data: [], ...this.surveyMeta() } as any;
    const { rows } = await this.db.runInTx(async (q) => q<any>(
      `select cs.*,
              s.mode,
              s.status as session_status,
              p.name as pet_name,
              vu.full_name as vet_name
         from consult_surveys cs
         join chat_sessions s on s.id = cs.session_id
    left join pets p on p.id = cs.pet_id
    left join users vu on vu.id = cs.vet_id
        where cs.user_id = $1::uuid
          and cs.status in ('pending', 'deferred')
          and (cs.next_prompt_at is null or cs.next_prompt_at <= now())
        order by cs.next_prompt_at nulls first, cs.created_at desc
        limit 10`,
      [actorId]
    ));
    return {
      data: rows.map((row) => ({
        ...this.normalizeSurvey(row),
        session: {
          id: row.session_id,
          mode: row.mode,
          status: row.session_status,
          petName: row.pet_name,
          vetName: row.vet_name,
        },
      })),
      ...this.surveyMeta(),
    };
  }
}