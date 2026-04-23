import { BadRequestException, Controller, Get, Param, Post, Body, UseGuards, NotFoundException } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { ValidatorService } from '../config/validator.service';

@Controller()
@UseGuards(AuthGuard)
export class RatingsController {
  constructor(
    private readonly db: DbService,
    private readonly rc: RequestContext,
    private readonly validator: ValidatorService,
  ) {}

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
}