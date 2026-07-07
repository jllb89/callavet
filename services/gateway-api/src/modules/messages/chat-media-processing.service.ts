import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { promisify } from 'node:util';
import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { DbService } from '../db/db.service';

const execFileAsync = promisify(execFile);

type ChatMediaTask = 'thumbnail' | 'waveform' | 'transcription' | 'safety_scan';
type ChatMediaJobStatus = 'succeeded' | 'failed' | 'skipped';

type ChatMediaProcessingOptions = {
  limit?: number;
  dryRun?: boolean;
};

type ChatMediaProcessingJobRow = {
  job_id: string;
  attachment_id: string;
  session_id: string;
  task: ChatMediaTask;
  attempts: number;
  kind: 'image' | 'video' | 'voice';
  storage_bucket: string;
  storage_path: string;
  content_type: string;
  byte_size: string | number;
  thumbnail_path: string | null;
  waveform: unknown;
  transcript_status: string;
  metadata: Record<string, any> | null;
};

type ChatMediaJobTelemetryRow = {
  task: string;
  status: string;
  count: string | number;
  avg_duration_ms: string | number | null;
  p95_duration_ms: string | number | null;
};

type ChatMediaProcessingResult = {
  status: ChatMediaJobStatus;
  errorCode?: string;
  result: Record<string, any>;
};

type TranscriptHandoffSummary = {
  summaryText: string;
  reportedSigns: string[];
  redFlags: string[];
  questionsAnswered: Array<{ question: string; answer: string }>;
  questionsUnanswered: string[];
  recommendedFirstChecks: string[];
};

@Injectable()
export class ChatMediaProcessingService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(ChatMediaProcessingService.name);
  private supabase?: SupabaseClient;
  private scheduler?: NodeJS.Timeout;
  private schedulerRunning = false;

  constructor(private readonly db: DbService) {}

  onModuleInit() {
    if (!this.envBool('CHAT_MEDIA_PROCESSING_ENABLED', false)) return;
    const intervalMs = this.clampNumber(process.env.CHAT_MEDIA_PROCESSING_INTERVAL_MS, 60_000, 10_000, 15 * 60_000);
    this.scheduler = setInterval(() => void this.runScheduledTick(), intervalMs);
    this.scheduler.unref?.();
    this.logger.log(`chat media processing scheduler enabled intervalMs=${intervalMs}`);
    if (this.envBool('CHAT_MEDIA_PROCESSING_RUN_ON_START', true)) {
      setTimeout(() => void this.runScheduledTick(), 5_000).unref?.();
    }
  }

  onModuleDestroy() {
    if (this.scheduler) clearInterval(this.scheduler);
  }

  async processPending(options: ChatMediaProcessingOptions = {}) {
    const limit = Math.min(Math.max(Number(options.limit || 25), 1), 100);
    const dryRun = options.dryRun !== false;
    const hasJobs = await this.tableExists('public.chat_media_processing_jobs');
    if (!hasJobs) {
      return { ok: true, dryRun, tableReady: false, matched: 0, processed: 0, jobs: [] };
    }

    await this.requeueStaleRunningJobs();
    const jobs = await this.nextJobs(limit);
    if (dryRun) {
      return { ok: true, dryRun, tableReady: true, matched: jobs.length, processed: 0, jobs: jobs.map((job) => this.describeJob(job)) };
    }

    const processed: Array<Record<string, any>> = [];
    for (const job of jobs) {
      const claimed = await this.claimJob(job.job_id);
      if (!claimed) continue;
      const result = await this.processJob(job).catch((error: any) => ({
        status: 'failed' as ChatMediaJobStatus,
        errorCode: this.errorCode(error),
        result: { message: error?.message || 'media_processing_failed' },
      }));
      await this.completeJob(job, result);
      processed.push({ ...this.describeJob(job), status: result.status, errorCode: result.errorCode || null, result: result.result });
    }

    return { ok: true, dryRun, tableReady: true, matched: jobs.length, processed: processed.length, jobs: processed };
  }

  private async tableExists(tableName: string) {
    const { rows } = await this.db.query<{ exists: boolean }>(`select to_regclass($1) is not null as exists`, [tableName]);
    return rows[0]?.exists === true;
  }

  private async nextJobs(limit: number) {
    const { rows } = await this.db.query<ChatMediaProcessingJobRow>(
      `select j.id as job_id,
              j.attachment_id,
              j.session_id,
              j.task,
              j.attempts,
              a.kind,
              a.storage_bucket,
              a.storage_path,
              a.content_type,
              a.byte_size,
              a.thumbnail_path,
              a.waveform,
              a.transcript_status,
              a.metadata
         from chat_media_processing_jobs j
         join message_attachments a on a.id = j.attachment_id
        where j.status in ('pending', 'failed')
          and j.attempts < 3
          and a.status = 'ready'
          and a.deleted_at is null
        order by j.created_at asc
        limit $1`,
      [limit]
    );
    return rows;
  }

  private async claimJob(jobId: string) {
    const { rows } = await this.db.query<{ id: string }>(
      `update chat_media_processing_jobs
          set status = 'running',
              attempts = attempts + 1,
              started_at = now(),
              error_code = null,
              updated_at = now()
        where id = $1::uuid
          and status in ('pending', 'failed')
          and attempts < 3
      returning id`,
      [jobId]
    );
    return rows.length > 0;
  }

  private async requeueStaleRunningJobs() {
    const staleMinutes = this.clampNumber(process.env.CHAT_MEDIA_PROCESSING_STALE_MINUTES, 15, 1, 240);
    await this.db.query(
      `update chat_media_processing_jobs
          set status = 'failed',
              error_code = 'worker_timeout',
              completed_at = now(),
              updated_at = now()
        where status = 'running'
          and started_at < now() - ($1::int * interval '1 minute')`,
      [staleMinutes]
    );
  }

  private async processJob(job: ChatMediaProcessingJobRow): Promise<ChatMediaProcessingResult> {
    switch (job.task) {
      case 'safety_scan':
        return this.processSafetyScan(job);
      case 'thumbnail':
        return this.processThumbnail(job);
      case 'waveform':
        return this.processWaveform(job);
      case 'transcription':
        return this.processTranscription(job);
    }
  }

  private async processSafetyScan(job: ChatMediaProcessingJobRow): Promise<ChatMediaProcessingResult> {
    const allowedTypes: Record<string, Set<string>> = {
      image: new Set(['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']),
      video: new Set(['video/mp4', 'video/quicktime']),
      voice: new Set(['audio/aac', 'audio/mp4', 'audio/mpeg', 'audio/wav', 'audio/webm', 'audio/x-m4a']),
    };
    const byteLimits = { image: 8_388_608, video: 52_428_800, voice: 15_728_640 };
    const byteSize = Number(job.byte_size || 0);
    const checks = {
      contentTypeAllowed: allowedTypes[job.kind]?.has(job.content_type) === true,
      byteSizeAllowed: byteSize > 0 && byteSize <= byteLimits[job.kind],
      privateStoragePath: job.storage_path.startsWith(`chat-consults/${job.session_id}/`),
    };
    const coarsePassed = Object.values(checks).every(Boolean);
    if (!coarsePassed) {
      return {
        status: 'failed',
        errorCode: 'media_safety_check_failed',
        result: { verdict: 'failed', checks, scanner: { configured: false }, scannedAt: new Date().toISOString() },
      };
    }
    const scannerCommand = (process.env.CHAT_MEDIA_MALWARE_SCAN_COMMAND || '').trim();
    if (!scannerCommand) {
      return {
        status: 'succeeded',
        result: { verdict: 'passed', checks, scanner: { configured: false }, scannedAt: new Date().toISOString() },
      };
    }
    const scan = await this.withDownloadedTempFile(job, (inputPath) => this.scanFile(scannerCommand, inputPath));
    if (!scan.clean) {
      return {
        status: 'failed',
        errorCode: scan.errorCode || 'malware_scan_failed',
        result: { verdict: scan.infected ? 'infected' : 'failed', checks, scanner: scan, scannedAt: new Date().toISOString() },
      };
    }
    return {
      status: 'succeeded',
      result: { verdict: 'passed', checks, scanner: scan, scannedAt: new Date().toISOString() },
    };
  }

  private async processThumbnail(job: ChatMediaProcessingJobRow): Promise<ChatMediaProcessingResult> {
    const metadataThumbnail = typeof job.metadata?.thumbnailPath === 'string' ? job.metadata.thumbnailPath : null;
    if (job.thumbnail_path || metadataThumbnail) {
      return {
        status: 'succeeded',
        result: { thumbnailPath: job.thumbnail_path || metadataThumbnail, source: job.thumbnail_path ? 'attachment' : 'metadata' },
      };
    }
    if (job.kind !== 'image' && job.kind !== 'video') {
      return { status: 'skipped', errorCode: 'thumbnail_not_applicable', result: { reason: 'thumbnail_not_applicable' } };
    }
    if (!this.getStorageClient()) {
      return { status: 'failed', errorCode: 'storage_client_not_configured', result: { reason: 'storage_client_not_configured' } };
    }
    const thumbnailPath = await this.withDownloadedTempFile(job, async (inputPath) => {
      const outputPath = join(dirname(inputPath), 'thumbnail.jpg');
      const width = this.clampNumber(process.env.CHAT_MEDIA_THUMBNAIL_WIDTH, 480, 160, 1280);
      const args = ['-hide_banner', '-loglevel', 'error', '-y'];
      if (job.kind === 'video') args.push('-ss', process.env.CHAT_MEDIA_VIDEO_THUMBNAIL_AT || '00:00:01');
      args.push('-i', inputPath, '-frames:v', '1', '-vf', `scale=${width}:-2`, outputPath);
      await execFileAsync(this.ffmpegPath(), args, { timeout: this.commandTimeoutMs(), maxBuffer: 256 * 1024 });
      const thumbnail = await readFile(outputPath);
      if (!thumbnail.length) throw new Error('thumbnail_empty');
      const path = this.thumbnailPathFor(job);
      await this.uploadBuffer(job.storage_bucket, path, thumbnail, 'image/jpeg');
      return path;
    });
    return {
      status: 'succeeded',
      result: { thumbnailPath, source: 'ffmpeg', generatedAt: new Date().toISOString() },
    };
  }

  private async processWaveform(job: ChatMediaProcessingJobRow): Promise<ChatMediaProcessingResult> {
    if (Array.isArray(job.waveform) && job.waveform.length > 0) {
      return { status: 'succeeded', result: { source: 'client', points: job.waveform.length } };
    }
    if (job.kind !== 'voice') {
      return { status: 'skipped', errorCode: 'waveform_not_applicable', result: { reason: 'waveform_not_applicable' } };
    }
    const points = await this.withDownloadedTempFile(job, async (inputPath) => {
      const { stdout } = await execFileAsync(
        this.ffmpegPath(),
        ['-hide_banner', '-loglevel', 'error', '-i', inputPath, '-ac', '1', '-ar', '8000', '-f', 'f32le', 'pipe:1'],
        { timeout: this.commandTimeoutMs(), maxBuffer: 24 * 1024 * 1024, encoding: 'buffer' as any }
      );
      return this.waveformFromPcm(Buffer.isBuffer(stdout) ? stdout : Buffer.from(stdout));
    });
    if (!points.length) {
      return { status: 'failed', errorCode: 'waveform_empty', result: { reason: 'waveform_empty' } };
    }
    return { status: 'succeeded', result: { source: 'ffmpeg', points, pointCount: points.length, generatedAt: new Date().toISOString() } };
  }

  private async processTranscription(job: ChatMediaProcessingJobRow): Promise<ChatMediaProcessingResult> {
    if (job.kind !== 'voice') {
      return { status: 'skipped', errorCode: 'transcription_not_applicable', result: { reason: 'transcription_not_applicable' } };
    }
    const apiKey = process.env.AI_PROVIDER_API_KEY || process.env.OPENAI_API_KEY || '';
    if (!apiKey) {
      return {
        status: 'skipped',
        errorCode: 'transcription_provider_not_configured',
        result: { reason: 'transcription_provider_not_configured' },
      };
    }
    const client = this.getStorageClient();
    if (!client) {
      return { status: 'failed', errorCode: 'storage_client_not_configured', result: { reason: 'storage_client_not_configured' } };
    }
    const { data, error } = await client.storage.from(job.storage_bucket).download(job.storage_path);
    if (error || !data) {
      return { status: 'failed', errorCode: 'storage_download_failed', result: { reason: error?.message || 'storage_download_failed' } };
    }
    const text = await this.transcribeAudio(data, job);
    if (!text) {
      return { status: 'failed', errorCode: 'transcription_empty', result: { reason: 'transcription_empty' } };
    }
    return { status: 'succeeded', result: { provider: 'openai', text, transcribedAt: new Date().toISOString() } };
  }

  private getStorageClient() {
    if (this.supabase) return this.supabase;
    const url = process.env.SUPABASE_URL;
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) return null;
    this.supabase = createClient(url, key);
    return this.supabase;
  }

  private async transcribeAudio(blob: Blob, job: ChatMediaProcessingJobRow) {
    const apiKey = process.env.AI_PROVIDER_API_KEY || process.env.OPENAI_API_KEY || '';
    const baseUrl = (process.env.AI_PROVIDER_BASE_URL || 'https://api.openai.com/v1').replace(/\/$/, '');
    const model = process.env.AI_TRANSCRIPTION_MODEL || 'gpt-4o-mini-transcribe';
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 60_000);
    try {
      const form = new FormData();
      form.append('model', model);
      form.append('file', blob, `chat-voice-${job.attachment_id}${this.extensionFor(job.content_type)}`);
      const response = await fetch(`${baseUrl}/audio/transcriptions`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${apiKey}` },
        body: form,
        signal: controller.signal,
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload?.error?.message || `transcription_${response.status}`);
      return typeof payload?.text === 'string' ? payload.text.trim() : '';
    } finally {
      clearTimeout(timer);
    }
  }

  private extensionFor(contentType: string) {
    const extensions: Record<string, string> = {
      'image/jpeg': '.jpg',
      'image/png': '.png',
      'image/webp': '.webp',
      'image/heic': '.heic',
      'image/heif': '.heif',
      'video/mp4': '.mp4',
      'video/quicktime': '.mov',
      'audio/aac': '.aac',
      'audio/mp4': '.m4a',
      'audio/mpeg': '.mp3',
      'audio/wav': '.wav',
      'audio/webm': '.webm',
      'audio/x-m4a': '.m4a',
    };
    return extensions[contentType] || '.bin';
  }

  private async completeJob(job: ChatMediaProcessingJobRow, result: ChatMediaProcessingResult) {
    await this.applyAttachmentResult(job, result);
    await this.db.query(
      `update chat_media_processing_jobs
          set status = $2,
              error_code = $3,
              result = $4::jsonb,
              completed_at = now(),
              updated_at = now()
        where id = $1::uuid`,
      [job.job_id, result.status, result.errorCode || null, JSON.stringify(result.result || {})]
    );
    await this.emitProcessingStatus(job, result);
  }

  private async applyAttachmentResult(job: ChatMediaProcessingJobRow, result: ChatMediaProcessingResult) {
    const processingRecord = {
      status: result.status,
      errorCode: result.errorCode || null,
      result: result.result,
      updatedAt: new Date().toISOString(),
    };
    if (job.task === 'thumbnail' && result.status === 'succeeded' && typeof result.result.thumbnailPath === 'string') {
      await this.db.query(
        `update message_attachments
            set thumbnail_path = coalesce(thumbnail_path, $2),
                metadata = jsonb_set(coalesce(metadata, '{}'::jsonb), $3::text[], $4::jsonb, true),
                updated_at = now()
          where id = $1::uuid`,
        [job.attachment_id, result.result.thumbnailPath, ['mediaProcessing', job.task], JSON.stringify(processingRecord)]
      );
      return;
    }
    if (job.task === 'transcription') {
      const transcriptReady = result.status === 'succeeded' && typeof result.result.text === 'string';
      await this.db.query(
        `update message_attachments
            set transcript_status = $2,
                transcript_text = case when $3::text is null then transcript_text else $3::text end,
                metadata = jsonb_set(coalesce(metadata, '{}'::jsonb), $4::text[], $5::jsonb, true),
                updated_at = now()
          where id = $1::uuid`,
        [
          job.attachment_id,
          transcriptReady ? 'ready' : 'failed',
          transcriptReady ? result.result.text : null,
          ['mediaProcessing', job.task],
          JSON.stringify(processingRecord),
        ]
      );
      if (transcriptReady) {
        await this.upsertTranscriptHandoffSummary(job, result.result.text);
      }
      return;
    }
    if (job.task === 'safety_scan' && result.status === 'failed') {
      await this.db.query(
        `update message_attachments
            set status = 'failed',
                metadata = jsonb_set(coalesce(metadata, '{}'::jsonb), $2::text[], $3::jsonb, true),
                updated_at = now()
          where id = $1::uuid`,
        [job.attachment_id, ['mediaProcessing', job.task], JSON.stringify(processingRecord)]
      );
      return;
    }
    if (job.task === 'waveform' && result.status === 'succeeded' && Array.isArray(result.result.points)) {
      await this.db.query(
        `update message_attachments
            set waveform = $2::jsonb,
                metadata = jsonb_set(coalesce(metadata, '{}'::jsonb), $3::text[], $4::jsonb, true),
                updated_at = now()
          where id = $1::uuid`,
        [job.attachment_id, JSON.stringify(result.result.points), ['mediaProcessing', job.task], JSON.stringify(processingRecord)]
      );
      return;
    }
    await this.db.query(
      `update message_attachments
          set metadata = jsonb_set(coalesce(metadata, '{}'::jsonb), $2::text[], $3::jsonb, true),
              updated_at = now()
        where id = $1::uuid`,
      [job.attachment_id, ['mediaProcessing', job.task], JSON.stringify(processingRecord)]
    );
  }

  private describeJob(job: ChatMediaProcessingJobRow) {
    return {
      jobId: job.job_id,
      attachmentId: job.attachment_id,
      sessionId: job.session_id,
      task: job.task,
      attempts: Number(job.attempts || 0),
      kind: job.kind,
      contentType: job.content_type,
      byteSize: Number(job.byte_size || 0),
    };
  }

  private errorCode(error: any) {
    const raw = String(error?.message || error?.code || 'media_processing_failed').toLowerCase();
    return raw.replace(/[^a-z0-9_]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 80) || 'media_processing_failed';
  }

  async metrics() {
    const hasJobs = await this.tableExists('public.chat_media_processing_jobs');
    if (!hasJobs) return { tableReady: false, byTask: [], failuresByReason: [] };
    const { rows: byTask } = await this.db.query<ChatMediaJobTelemetryRow>(
      `select task,
              status,
              count(*)::int as count,
              avg(extract(epoch from (completed_at - started_at)) * 1000) filter (where started_at is not null and completed_at is not null) as avg_duration_ms,
              percentile_cont(0.95) within group (order by extract(epoch from (completed_at - started_at)) * 1000)
                filter (where started_at is not null and completed_at is not null) as p95_duration_ms
         from chat_media_processing_jobs
        group by task, status
        order by task asc, status asc`
    );
    const { rows: failuresByReason } = await this.db.query<any>(
      `select task,
              coalesce(error_code, 'unknown') as error_code,
              count(*)::int as count
         from chat_media_processing_jobs
        where status in ('failed', 'skipped')
        group by task, coalesce(error_code, 'unknown')
        order by count desc, task asc, error_code asc
        limit 20`
    );
    return {
      tableReady: true,
      byTask: byTask.map((row) => ({
        task: row.task,
        status: row.status,
        count: Number(row.count || 0),
        avgDurationMs: row.avg_duration_ms == null ? null : Number(row.avg_duration_ms),
        p95DurationMs: row.p95_duration_ms == null ? null : Number(row.p95_duration_ms),
      })),
      failuresByReason: failuresByReason.map((row) => ({
        task: row.task,
        errorCode: row.error_code,
        count: Number(row.count || 0),
      })),
    };
  }

  private async emitProcessingStatus(job: ChatMediaProcessingJobRow, result: ChatMediaProcessingResult) {
    try {
      await this.db.query(
        `select public.fn_emit_consult_room_broadcast($1::uuid, 'attachment_processing', $2::jsonb)`,
        [
          job.session_id,
          JSON.stringify({
            sessionId: job.session_id,
            attachmentId: job.attachment_id,
            task: job.task,
            status: result.status,
            errorCode: result.errorCode || null,
            result: this.publicProcessingResult(job.task, result),
          }),
        ]
      );
    } catch (error: any) {
      this.logger.warn(`attachment processing broadcast failed: ${error?.message || error}`);
    }
  }

  private publicProcessingResult(task: ChatMediaTask, result: ChatMediaProcessingResult) {
    if (task === 'transcription') {
      return { provider: result.result.provider || null, transcribedAt: result.result.transcribedAt || null };
    }
    if (task === 'waveform') {
      return { source: result.result.source || null, pointCount: result.result.pointCount || (Array.isArray(result.result.points) ? result.result.points.length : null) };
    }
    if (task === 'thumbnail') {
      return { source: result.result.source || null, thumbnailReady: result.status === 'succeeded' };
    }
    if (task === 'safety_scan') {
      return { verdict: result.result.verdict || null, scannedAt: result.result.scannedAt || null };
    }
    return {};
  }

  private async upsertTranscriptHandoffSummary(job: ChatMediaProcessingJobRow, transcriptText: string) {
    const transcript = transcriptText.trim().slice(0, 6000);
    if (!transcript) return;
    const summary = await this.summarizeTranscriptForHandoff(job, transcript).catch((error: any) => {
      this.logger.warn(`transcript handoff summary failed attachmentId=${job.attachment_id}: ${error?.message || error}`);
      return this.fallbackTranscriptSummary(transcript);
    });
    const sourceRecord = {
      attachmentId: job.attachment_id,
      task: 'transcript_summary',
      summary,
      transcriptExcerpt: transcript.slice(0, 1200),
      model: process.env.AI_HANDOFF_TRANSCRIPT_MODEL || process.env.AI_MODEL || null,
      updatedAt: new Date().toISOString(),
    };
    await this.db.query(
      `with session_row as (
          select s.id,
                 s.user_id,
                 s.pet_id,
                 s.vet_id,
                 s.specialty_id,
                 coalesce(nullif(s.priority, ''), 'routine') as priority
            from chat_sessions s
           where s.id = $1::uuid
           limit 1
        ), existing as (
          select h.*
            from ai_handoffs h
           where h.session_id = $1::uuid
           limit 1
        ), merged as (
          select sr.id as session_id,
                 coalesce(existing.actor_user_id, sr.user_id) as actor_user_id,
                 sr.pet_id,
                 sr.vet_id,
                 sr.specialty_id,
                 case
                   when existing.urgency = 'emergency' or $3::jsonb ? 'emergency' then 'emergency'
                   when existing.urgency = 'urgent' or $3::jsonb ? 'urgent' then 'urgent'
                   else coalesce(existing.urgency, sr.priority, 'routine')
                 end as urgency,
                 trim(both E'\n' from concat_ws(E'\n\n', nullif(existing.summary_text, ''), $2::text)) as summary_text,
                 (
                   select jsonb_agg(distinct value)
                     from jsonb_array_elements_text(coalesce(existing.reported_signs, '[]'::jsonb) || coalesce($3::jsonb->'reportedSigns', '[]'::jsonb)) as item(value)
                 ) as reported_signs,
                 (
                   select jsonb_agg(distinct value)
                     from jsonb_array_elements_text(coalesce(existing.red_flags, '[]'::jsonb) || coalesce($3::jsonb->'redFlags', '[]'::jsonb)) as item(value)
                 ) as red_flags,
                 coalesce(existing.questions_answered, '[]'::jsonb) || coalesce($3::jsonb->'questionsAnswered', '[]'::jsonb) as questions_answered,
                 (
                   select jsonb_agg(distinct value)
                     from jsonb_array_elements_text(coalesce(existing.questions_unanswered, '[]'::jsonb) || coalesce($3::jsonb->'questionsUnanswered', '[]'::jsonb)) as item(value)
                 ) as questions_unanswered,
                 (
                   select jsonb_agg(distinct value)
                     from jsonb_array_elements_text(coalesce(existing.recommended_first_checks, '[]'::jsonb) || coalesce($3::jsonb->'recommendedFirstChecks', '[]'::jsonb)) as item(value)
                 ) as recommended_first_checks,
                 jsonb_set(
                   coalesce(existing.source_payload, '{}'::jsonb),
                   '{mediaTranscriptSummaries}',
                   coalesce(existing.source_payload->'mediaTranscriptSummaries', '[]'::jsonb) || jsonb_build_array($4::jsonb),
                   true
                 ) as source_payload
            from session_row sr
            left join existing on true
        )
        insert into ai_handoffs (
          id, session_id, actor_user_id, pet_id, vet_id, specialty_id, urgency, summary_text,
          reported_signs, red_flags, questions_answered, questions_unanswered, recommended_first_checks,
          source_payload, created_at, updated_at
        )
        select gen_random_uuid(), session_id, actor_user_id, pet_id, vet_id, specialty_id, urgency, left(summary_text, 2000),
               coalesce(reported_signs, '[]'::jsonb),
               coalesce(red_flags, '[]'::jsonb),
               coalesce(questions_answered, '[]'::jsonb),
               coalesce(questions_unanswered, '[]'::jsonb),
               coalesce(recommended_first_checks, '[]'::jsonb),
               source_payload,
               now(),
               now()
          from merged
        on conflict (session_id) do update
           set urgency = excluded.urgency,
               summary_text = excluded.summary_text,
               reported_signs = excluded.reported_signs,
               red_flags = excluded.red_flags,
               questions_answered = excluded.questions_answered,
               questions_unanswered = excluded.questions_unanswered,
               recommended_first_checks = excluded.recommended_first_checks,
               source_payload = excluded.source_payload,
               updated_at = now()`,
      [job.session_id, this.transcriptSummaryBlock(summary.summaryText), JSON.stringify(summary), JSON.stringify(sourceRecord)]
    );
    await this.emitHandoffUpdated(job, summary);
  }

  private async summarizeTranscriptForHandoff(job: ChatMediaProcessingJobRow, transcript: string): Promise<TranscriptHandoffSummary> {
    const apiKey = process.env.AI_PROVIDER_API_KEY || process.env.OPENAI_API_KEY || '';
    if (!apiKey) return this.fallbackTranscriptSummary(transcript);
    const baseUrl = (process.env.AI_PROVIDER_BASE_URL || 'https://api.openai.com/v1').replace(/\/$/, '');
    const model = process.env.AI_HANDOFF_TRANSCRIPT_MODEL || process.env.AI_MODEL || 'gpt-5.4-mini';
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.commandTimeoutMs());
    try {
      const response = await fetch(`${baseUrl}/responses`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model,
          store: false,
          instructions: this.transcriptHandoffInstructions(),
          input: [{
            role: 'user',
            content: JSON.stringify({
              sessionId: job.session_id,
              attachmentId: job.attachment_id,
              contentType: job.content_type,
              transcript,
            }),
          }],
          text: { format: this.transcriptHandoffResponseFormat() },
        }),
        signal: controller.signal,
      });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(payload?.error?.message || `handoff_transcript_summary_${response.status}`);
      return this.normalizeTranscriptHandoffSummary(this.extractResponsesText(payload));
    } finally {
      clearTimeout(timer);
    }
  }

  private transcriptHandoffInstructions() {
    return [
      'You summarize a transcribed owner voice note for a veterinarian handoff in an equine consult.',
      'Return Spanish unless the transcript is clearly in another language.',
      'Use only facts present in the transcript. Do not infer exam findings, diagnoses, prognosis, medications, or treatments.',
      'Write for the human veterinarian, not the owner. Keep it concise, factual, and non-diagnostic.',
      'If the transcript is unclear or missing information, put it in questionsUnanswered instead of guessing.',
    ].join('\n');
  }

  private transcriptHandoffResponseFormat() {
    return {
      type: 'json_schema',
      name: 'chat_media_transcript_handoff_summary',
      strict: true,
      schema: {
        type: 'object',
        additionalProperties: false,
        required: ['summaryText', 'reportedSigns', 'redFlags', 'questionsAnswered', 'questionsUnanswered', 'recommendedFirstChecks'],
        properties: {
          summaryText: { type: 'string' },
          reportedSigns: { type: 'array', items: { type: 'string' } },
          redFlags: { type: 'array', items: { type: 'string' } },
          questionsAnswered: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['question', 'answer'],
              properties: { question: { type: 'string' }, answer: { type: 'string' } },
            },
          },
          questionsUnanswered: { type: 'array', items: { type: 'string' } },
          recommendedFirstChecks: { type: 'array', items: { type: 'string' } },
        },
      },
    };
  }

  private extractResponsesText(data: any) {
    if (typeof data?.output_text === 'string' && data.output_text.trim()) return data.output_text;
    const parts: string[] = [];
    for (const item of Array.isArray(data?.output) ? data.output : []) {
      for (const content of Array.isArray(item?.content) ? item.content : []) {
        if (typeof content?.text === 'string') parts.push(content.text);
      }
    }
    return parts.join('\n').trim();
  }

  private normalizeTranscriptHandoffSummary(raw: string): TranscriptHandoffSummary {
    const parsed = JSON.parse(raw || '{}');
    const normalizeStrings = (value: any, maxItems: number, maxLength = 240) => Array.isArray(value)
      ? value.map((item) => String(item || '').trim().slice(0, maxLength)).filter(Boolean).slice(0, maxItems)
      : [];
    const questionsAnswered = Array.isArray(parsed?.questionsAnswered)
      ? parsed.questionsAnswered.map((item: any) => {
          const question = String(item?.question || '').trim().slice(0, 280);
          const answer = String(item?.answer || '').trim().slice(0, 600);
          return question && answer ? { question, answer } : null;
        }).filter(Boolean).slice(0, 12)
      : [];
    const summaryText = String(parsed?.summaryText || '').trim().slice(0, 900);
    if (!summaryText) throw new Error('transcript_handoff_summary_empty');
    return {
      summaryText,
      reportedSigns: normalizeStrings(parsed?.reportedSigns, 10),
      redFlags: normalizeStrings(parsed?.redFlags, 8),
      questionsAnswered,
      questionsUnanswered: normalizeStrings(parsed?.questionsUnanswered, 8),
      recommendedFirstChecks: normalizeStrings(parsed?.recommendedFirstChecks, 6),
    };
  }

  private fallbackTranscriptSummary(transcript: string): TranscriptHandoffSummary {
    return {
      summaryText: `Nota de voz transcrita del propietario: ${transcript.slice(0, 700)}`,
      reportedSigns: [],
      redFlags: [],
      questionsAnswered: [],
      questionsUnanswered: ['Confirmar detalles clínicos relevantes mencionados en la nota de voz.'],
      recommendedFirstChecks: ['Revisar la transcripción de la nota de voz antes de responder.'],
    };
  }

  private transcriptSummaryBlock(summaryText: string) {
    return `Resumen de nota de voz para el veterinario: ${summaryText}`.slice(0, 1000);
  }

  private async emitHandoffUpdated(job: ChatMediaProcessingJobRow, summary: TranscriptHandoffSummary) {
    try {
      await this.db.query(
        `select public.fn_emit_consult_room_broadcast($1::uuid, 'handoff_updated', $2::jsonb)`,
        [job.session_id, JSON.stringify({ sessionId: job.session_id, attachmentId: job.attachment_id, source: 'voice_transcript', summaryReady: !!summary.summaryText })]
      );
    } catch (error: any) {
      this.logger.warn(`handoff update broadcast failed: ${error?.message || error}`);
    }
  }

  private async runScheduledTick() {
    if (this.schedulerRunning) return;
    this.schedulerRunning = true;
    try {
      const limit = this.clampNumber(process.env.CHAT_MEDIA_PROCESSING_BATCH_SIZE, 10, 1, 100);
      const result = await this.processPending({ dryRun: false, limit });
      if (result.processed > 0) this.logger.log(`processed chat media jobs=${result.processed}`);
    } catch (error: any) {
      this.logger.warn(`chat media processing tick failed: ${error?.message || error}`);
    } finally {
      this.schedulerRunning = false;
    }
  }

  private async withDownloadedTempFile<T>(job: ChatMediaProcessingJobRow, fn: (inputPath: string) => Promise<T>) {
    const client = this.getStorageClient();
    if (!client) throw new Error('storage_client_not_configured');
    const { data, error } = await client.storage.from(job.storage_bucket).download(job.storage_path);
    if (error || !data) throw new Error(error?.message || 'storage_download_failed');
    const dir = await mkdtemp(join(tmpdir(), 'cav-chat-media-'));
    const inputPath = join(dir, `input${this.extensionFor(job.content_type)}`);
    try {
      await writeFile(inputPath, Buffer.from(await data.arrayBuffer()));
      return await fn(inputPath);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  }

  private async uploadBuffer(bucket: string, path: string, data: Buffer, contentType: string) {
    const client = this.getStorageClient();
    if (!client) throw new Error('storage_client_not_configured');
    const { error } = await client.storage.from(bucket).upload(path, data, { contentType, upsert: true });
    if (error) throw new Error(error.message || 'storage_upload_failed');
  }

  private async scanFile(scannerCommand: string, inputPath: string) {
    const scannerArgs = this.splitArgs(process.env.CHAT_MEDIA_MALWARE_SCAN_ARGS || '--no-summary');
    try {
      await execFileAsync(scannerCommand, [...scannerArgs, inputPath], { timeout: this.commandTimeoutMs(), maxBuffer: 1024 * 1024 });
      return { configured: true, engine: scannerCommand, clean: true, infected: false };
    } catch (error: any) {
      if (Number(error?.code) === 1) {
        return { configured: true, engine: scannerCommand, clean: false, infected: true, errorCode: 'malware_detected' };
      }
      return { configured: true, engine: scannerCommand, clean: false, infected: false, errorCode: this.errorCode(error) || 'malware_scan_error' };
    }
  }

  private waveformFromPcm(buffer: Buffer) {
    const totalSamples = Math.floor(buffer.length / 4);
    if (totalSamples <= 0) return [];
    const bucketCount = this.clampNumber(process.env.CHAT_MEDIA_WAVEFORM_POINTS, 64, 16, 256);
    const buckets = Array.from({ length: bucketCount }, () => 0);
    for (let bucket = 0; bucket < bucketCount; bucket += 1) {
      const start = Math.floor((bucket / bucketCount) * totalSamples);
      const end = Math.max(start + 1, Math.floor(((bucket + 1) / bucketCount) * totalSamples));
      let peak = 0;
      for (let sample = start; sample < end; sample += 1) {
        const value = Math.abs(buffer.readFloatLE(sample * 4));
        if (Number.isFinite(value) && value > peak) peak = value;
      }
      buckets[bucket] = peak;
    }
    const max = Math.max(...buckets, 0);
    return buckets.map((value) => Number((max > 0 ? value / max : 0).toFixed(3)));
  }

  private thumbnailPathFor(job: ChatMediaProcessingJobRow) {
    return `chat-consults/${job.session_id}/${job.attachment_id}/thumbnail.jpg`;
  }

  private ffmpegPath() {
    return process.env.CHAT_MEDIA_FFMPEG_PATH || 'ffmpeg';
  }

  private commandTimeoutMs() {
    return this.clampNumber(process.env.CHAT_MEDIA_PROCESSING_COMMAND_TIMEOUT_MS, 60_000, 5_000, 5 * 60_000);
  }

  private splitArgs(value: string) {
    return value.split(/\s+/).map((part) => part.trim()).filter(Boolean);
  }

  private envBool(name: string, fallback: boolean) {
    const value = process.env[name];
    if (value == null || value === '') return fallback;
    return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
  }

  private clampNumber(value: string | number | undefined, fallback: number, min: number, max: number) {
    const parsed = Number(value ?? fallback);
    if (!Number.isFinite(parsed)) return fallback;
    return Math.min(Math.max(Math.trunc(parsed), min), max);
  }
}