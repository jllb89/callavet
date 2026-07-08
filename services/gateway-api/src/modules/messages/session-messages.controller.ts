import { Body, Controller, Get, Headers, HttpCode, HttpException, HttpStatus, Param, Post, Query, UseGuards } from '@nestjs/common';
import { Span, SpanStatusCode, trace } from '@opentelemetry/api';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import WebSocket from 'ws';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';
import { DbService } from '../db/db.service';
import { EndpointRateLimitGuard } from '../rate-limit/endpoint-rate-limit.guard';
import { RateLimit } from '../rate-limit/rate-limit.decorator';

type TxQuery = <R = any>(sql: string, args?: any[]) => Promise<{ rows: R[] }>;

type SessionMessageBody = {
  role?: string;
  content?: string;
  clientKey?: string;
  client_key?: string;
  attachments?: SessionMessageAttachmentRef[];
};

type SessionMessageAttachmentRef = {
  id?: string;
  attachmentId?: string;
  attachment_id?: string;
};

type SessionAttachmentUploadBody = {
  kind?: string;
  contentType?: string;
  content_type?: string;
  byteSize?: string | number;
  byte_size?: string | number;
  fileName?: string;
  file_name?: string;
  width?: string | number;
  height?: string | number;
  durationMs?: string | number;
  duration_ms?: string | number;
  waveform?: unknown;
  metadata?: unknown;
};

type SessionMessageReadBody = {
  lastStreamOrder?: string | number;
};

type SessionTelemetryBody = {
  eventType?: string;
  event_type?: string;
  clientKey?: string;
  client_key?: string;
  messageId?: string;
  message_id?: string;
  attachmentId?: string;
  attachment_id?: string;
  durationMs?: string | number;
  duration_ms?: string | number;
  valueMs?: string | number;
  value_ms?: string | number;
  valueCount?: string | number;
  value_count?: string | number;
  errorCode?: string;
  error_code?: string;
  metadata?: unknown;
};

type SessionMessageAccess = {
  id: string;
  status: string | null;
  mode: string | null;
  actor_role: 'user' | 'vet' | 'admin';
  owner_name: string | null;
  vet_name: string | null;
  consumption_id: string | null;
  consumption_finalized: boolean | null;
};

type SessionMessageRow = {
  id: string;
  session_id: string;
  sender_id: string;
  role: string;
  content: string;
  client_key: string | null;
  stream_order: string | number;
  created_at: string;
  edited_at: string | null;
  deleted_at: string | null;
  redacted_at: string | null;
  redaction_reason: string | null;
  attachments?: MessageAttachmentResponse[];
};

type MessageAttachmentKind = 'image' | 'video' | 'voice';

type MessageAttachmentRow = {
  id: string;
  message_id: string | null;
  session_id: string;
  uploaded_by: string | null;
  kind: MessageAttachmentKind;
  storage_bucket: string;
  storage_path: string;
  content_type: string;
  byte_size: string | number;
  width: number | null;
  height: number | null;
  duration_ms: number | null;
  thumbnail_path: string | null;
  waveform: unknown;
  status: string;
  transcript_text: string | null;
  transcript_status: string;
  metadata: Record<string, any> | null;
  created_at: string;
  updated_at: string;
};

type MessageAttachmentResponse = {
  id: string;
  message_id: string | null;
  session_id: string;
  kind: MessageAttachmentKind;
  content_type: string;
  byte_size: number;
  width: number | null;
  height: number | null;
  duration_ms: number | null;
  thumbnail_path: string | null;
  waveform: unknown;
  status: string;
  transcript_text: string | null;
  transcript_status: string;
  metadata: Record<string, any>;
  created_at: string;
  downloadUrl?: string | null;
  thumbnailUrl?: string | null;
  downloadExpiresIn?: number;
};

@Controller('sessions')
@UseGuards(AuthGuard)
export class SessionMessagesController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}
  private supabase?: SupabaseClient;
  private readonly tracer = trace.getTracer('cav.gateway.chat');
  private readonly uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  private readonly attachmentDownloadExpiresIn = 3600;
  private readonly attachmentContentTypes: Record<MessageAttachmentKind, Set<string>> = {
    image: new Set(['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']),
    video: new Set(['video/mp4', 'video/quicktime']),
    voice: new Set(['audio/aac', 'audio/mp4', 'audio/mpeg', 'audio/wav', 'audio/webm', 'audio/x-m4a']),
  };
  private readonly attachmentExtensions: Record<string, string> = {
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
  private readonly attachmentCompatibleExtensions: Record<string, string[]> = {
    'image/jpeg': ['.jpg', '.jpeg'],
    'image/png': ['.png'],
    'image/webp': ['.webp'],
    'image/heic': ['.heic'],
    'image/heif': ['.heif'],
    'video/mp4': ['.mp4'],
    'video/quicktime': ['.mov', '.qt'],
    'audio/aac': ['.aac'],
    'audio/mp4': ['.m4a', '.mp4'],
    'audio/mpeg': ['.mp3', '.mpeg'],
    'audio/wav': ['.wav'],
    'audio/webm': ['.webm'],
    'audio/x-m4a': ['.m4a'],
  };
  private readonly attachmentByteLimits: Record<MessageAttachmentKind, number> = {
    image: 8 * 1024 * 1024,
    video: 50 * 1024 * 1024,
    voice: 15 * 1024 * 1024,
  };
  private readonly voiceDurationLimitMs = 5 * 60 * 1000;
  private readonly telemetryEventTypes = new Set([
    'send_started',
    'send_completed',
    'send_failed',
    'upload_started',
    'upload_progress',
    'upload_completed',
    'upload_failed',
    'realtime_reconnect',
    'realtime_catchup',
    'playback_refresh',
    'read_receipt_sent',
  ]);

  private normalizeActorHint(value?: string | string[]) {
    const raw = Array.isArray(value) ? value[0] : value;
    const normalized = String(raw || '').trim().toLowerCase();
    return normalized === 'vet' || normalized === 'user' ? normalized : null;
  }

  private parseNonNegativeInt(value: unknown, field: string) {
    if (value == null || value === '') return null;
    const parsed = Number(value);
    if (!Number.isInteger(parsed) || parsed < 0) throw new HttpException(`${field}_invalid`, HttpStatus.BAD_REQUEST);
    return parsed;
  }

  private normalizeTelemetryBody(body: SessionTelemetryBody) {
    const eventType = String(body?.eventType || body?.event_type || '').trim().toLowerCase();
    if (!this.telemetryEventTypes.has(eventType)) throw new HttpException('telemetry_event_type_invalid', HttpStatus.BAD_REQUEST);
    const clientKey = String(body?.clientKey || body?.client_key || '').trim() || null;
    if (clientKey && clientKey.length > 128) throw new HttpException('client_key_too_long', HttpStatus.BAD_REQUEST);
    const messageId = String(body?.messageId || body?.message_id || '').trim() || null;
    if (messageId && !this.uuidRegex.test(messageId)) throw new HttpException('message_id_invalid', HttpStatus.BAD_REQUEST);
    const attachmentId = String(body?.attachmentId || body?.attachment_id || '').trim() || null;
    if (attachmentId && !this.uuidRegex.test(attachmentId)) throw new HttpException('attachment_id_invalid', HttpStatus.BAD_REQUEST);
    const errorCode = String(body?.errorCode || body?.error_code || '').trim().slice(0, 120) || null;
    const metadata = this.sanitizeTelemetryMetadata(body?.metadata);
    return {
      eventType,
      clientKey,
      messageId,
      attachmentId,
      durationMs: this.parseNonNegativeInt(body?.durationMs ?? body?.duration_ms, 'duration_ms'),
      valueMs: this.parseNonNegativeInt(body?.valueMs ?? body?.value_ms, 'value_ms'),
      valueCount: this.parseNonNegativeInt(body?.valueCount ?? body?.value_count, 'value_count'),
      errorCode,
      metadata,
    };
  }

  private sanitizeTelemetryMetadata(value: unknown) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
    const input = value as Record<string, unknown>;
    const allowed = new Set([
      'actor',
      'attachmentCount',
      'attachmentKind',
      'duplicate',
      'status',
      'streamOrder',
      'cursor',
      'afterStreamOrder',
      'progressPercent',
      'retrying',
      'reconnectAttempt',
      'playbackKind',
    ]);
    const output: Record<string, unknown> = {};
    for (const [key, raw] of Object.entries(input)) {
      if (!allowed.has(key)) continue;
      if (typeof raw === 'string') output[key] = raw.slice(0, 120);
      else if (typeof raw === 'number' && Number.isFinite(raw)) output[key] = raw;
      else if (typeof raw === 'boolean') output[key] = raw;
    }
    return output;
  }

  private realtimeLog(event: string, metadata: Record<string, any> = {}) {
    console.log(JSON.stringify({
      scope: 'chat_consultation_realtime',
      component: 'session_messages',
      event,
      at: new Date().toISOString(),
      ...metadata,
    }));
  }

  private startChatSpan(name: string, attributes: Record<string, string | number | boolean | null | undefined> = {}) {
    const cleaned: Record<string, string | number | boolean> = {};
    for (const [key, value] of Object.entries(attributes)) {
      if (value !== null && value !== undefined) cleaned[key] = value;
    }
    return this.tracer.startSpan(name, { attributes: cleaned });
  }

  private recordSpanError(span: Span, error: any) {
    span.recordException(error instanceof Error ? error : new Error(error?.message || String(error || 'unknown_error')));
    span.setStatus({ code: SpanStatusCode.ERROR, message: error?.message || 'operation_failed' });
  }

  private getStorageClient() {
    if (this.supabase) return this.supabase;
    const url = process.env.SUPABASE_URL;
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) throw new HttpException('storage_env_missing', HttpStatus.BAD_REQUEST);
    this.supabase = createClient(url, key, { realtime: { transport: WebSocket as any } });
    return this.supabase;
  }

  private chatMediaBucket() {
    return process.env.CHAT_MEDIA_STORAGE_BUCKET || 'chat-media';
  }

  private async logAttachmentAudit(action: string, targetId: string | null, metadata: Record<string, any> = {}) {
    try {
      await this.db.query(
        `insert into admin_audit_logs (
           id,
           actor_user_id,
           action,
           target_type,
           target_id,
           metadata,
           created_at
         ) values (
           gen_random_uuid(),
           $1::uuid,
           $2::text,
           'message_attachments',
           $3::text,
           $4::jsonb,
           now()
         )`,
        [this.rc.userId || null, action, targetId, JSON.stringify(metadata)]
      );
    } catch {
      // Audit logging should never block chat delivery.
    }
  }

  private normalizeKind(value?: string): MessageAttachmentKind {
    const normalized = String(value || '').trim().toLowerCase();
    if (normalized === 'image' || normalized === 'video' || normalized === 'voice') return normalized;
    throw new HttpException('unsupported_attachment_kind', HttpStatus.BAD_REQUEST);
  }

  private normalizeContentType(value?: string) {
    return String(value || '').trim().toLowerCase();
  }

  private parsePositiveInt(value: unknown, field: string, options: { required?: boolean; max?: number } = {}) {
    if (value == null || value === '') {
      if (options.required) throw new HttpException(`${field}_required`, HttpStatus.BAD_REQUEST);
      return null;
    }
    const parsed = Number(value);
    if (!Number.isInteger(parsed) || parsed <= 0) throw new HttpException(`${field}_invalid`, HttpStatus.BAD_REQUEST);
    if (options.max != null && parsed > options.max) throw new HttpException(`${field}_too_large`, HttpStatus.BAD_REQUEST);
    return parsed;
  }

  private validateAttachmentUpload(body: SessionAttachmentUploadBody) {
    const kind = this.normalizeKind(body?.kind);
    const contentType = this.normalizeContentType(body?.contentType || body?.content_type);
    if (!this.attachmentContentTypes[kind].has(contentType)) {
      throw new HttpException('unsupported_media_type', HttpStatus.BAD_REQUEST);
    }
    const byteSize = this.parsePositiveInt(body?.byteSize ?? body?.byte_size, 'byte_size', { required: true })!;
    if (byteSize > this.attachmentByteLimits[kind]) throw new HttpException('attachment_too_large', HttpStatus.BAD_REQUEST);
    const durationMs = this.parsePositiveInt(body?.durationMs ?? body?.duration_ms, 'duration_ms', {
      max: kind === 'voice' ? this.voiceDurationLimitMs : undefined,
    });
    if (kind === 'voice' && durationMs != null && durationMs > this.voiceDurationLimitMs) {
      throw new HttpException('voice_note_too_long', HttpStatus.BAD_REQUEST);
    }
    const fileName = String(body?.fileName || body?.file_name || '').trim().slice(0, 240) || null;
    if (fileName) {
      const lowerFileName = fileName.toLowerCase();
      const compatibleExtensions = this.attachmentCompatibleExtensions[contentType] || [];
      if (compatibleExtensions.length && !compatibleExtensions.some((extension) => lowerFileName.endsWith(extension))) {
        throw new HttpException('attachment_extension_mismatch', HttpStatus.BAD_REQUEST);
      }
    }
    return {
      kind,
      contentType,
      byteSize,
      fileName,
      width: this.parsePositiveInt(body?.width, 'width'),
      height: this.parsePositiveInt(body?.height, 'height'),
      durationMs,
      waveform: kind === 'voice' ? body?.waveform ?? null : null,
      metadata: this.asRecord(body?.metadata),
    };
  }

  private asRecord(value: unknown): Record<string, any> {
    return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, any> : {};
  }

  private normalizeAttachmentIds(value: unknown) {
    if (value == null) return [];
    if (!Array.isArray(value)) throw new HttpException('attachments_must_be_array', HttpStatus.BAD_REQUEST);
    const ids: string[] = [];
    for (const item of value) {
      const ref = (item || {}) as SessionMessageAttachmentRef;
      const id = String(ref.id || ref.attachmentId || ref.attachment_id || '').trim();
      if (!this.uuidRegex.test(id)) throw new HttpException('attachment_id_invalid', HttpStatus.BAD_REQUEST);
      if (!ids.includes(id)) ids.push(id);
    }
    return ids;
  }

  private validateAttachmentBatch(rows: MessageAttachmentRow[]) {
    if (!rows.length) return;
    const kinds = new Set(rows.map((row) => row.kind));
    if (kinds.size > 1) throw new HttpException('mixed_attachment_kind_not_supported', HttpStatus.BAD_REQUEST);
    const kind = rows[0].kind;
    if (kind === 'image' && rows.length > 6) throw new HttpException('too_many_attachments', HttpStatus.BAD_REQUEST);
    if ((kind === 'video' || kind === 'voice') && rows.length > 1) throw new HttpException('too_many_attachments', HttpStatus.BAD_REQUEST);
    for (const row of rows) {
      const byteSize = Number(row.byte_size || 0);
      if (!Number.isFinite(byteSize) || byteSize <= 0 || byteSize > this.attachmentByteLimits[row.kind]) {
        throw new HttpException('attachment_too_large', HttpStatus.BAD_REQUEST);
      }
      if (row.kind === 'voice' && row.duration_ms != null && row.duration_ms > this.voiceDurationLimitMs) {
        throw new HttpException('voice_note_too_long', HttpStatus.BAD_REQUEST);
      }
    }
  }

  private async createSignedUploadUrl(bucket: string, storagePath: string) {
    const span = this.startChatSpan('chat.attachment.upload_url.sign', { bucket });
    const storage = this.getStorageClient().storage.from(bucket) as any;
    try {
      if (typeof storage.createSignedUploadUrl !== 'function') {
        throw new HttpException('signed_upload_not_supported', HttpStatus.BAD_GATEWAY);
      }
      const { data, error } = await storage.createSignedUploadUrl(storagePath);
      if (error) throw new HttpException(`signed_upload_failed: ${error.message}`, HttpStatus.BAD_GATEWAY);
      span.setStatus({ code: SpanStatusCode.OK });
      return data || {};
    } catch (error) {
      this.recordSpanError(span, error);
      throw error;
    } finally {
      span.end();
    }
  }

  private async signedDownloadUrl(row: MessageAttachmentRow) {
    const span = this.startChatSpan('chat.attachment.download_url.refresh', {
      sessionId: row.session_id,
      attachmentId: row.id,
      kind: row.kind,
    });
    try {
      const { data, error } = await this.getStorageClient()
        .storage
        .from(row.storage_bucket)
        .createSignedUrl(row.storage_path, this.attachmentDownloadExpiresIn);
      if (error) return null;
      span.setStatus({ code: SpanStatusCode.OK });
      return data?.signedUrl || null;
    } catch (error) {
      this.recordSpanError(span, error);
      throw error;
    } finally {
      span.end();
    }
  }

  private async signedThumbnailUrl(row: MessageAttachmentRow) {
    if (!row.thumbnail_path) return null;
    const span = this.startChatSpan('chat.attachment.thumbnail_url.refresh', {
      sessionId: row.session_id,
      attachmentId: row.id,
      kind: row.kind,
    });
    try {
      const { data, error } = await this.getStorageClient()
        .storage
        .from(row.storage_bucket)
        .createSignedUrl(row.thumbnail_path, this.attachmentDownloadExpiresIn);
      if (error) return null;
      span.setStatus({ code: SpanStatusCode.OK });
      return data?.signedUrl || null;
    } catch (error) {
      this.recordSpanError(span, error);
      throw error;
    } finally {
      span.end();
    }
  }

  private async storageObjectByteSize(row: MessageAttachmentRow) {
    const slash = row.storage_path.lastIndexOf('/');
    const prefix = slash >= 0 ? row.storage_path.slice(0, slash) : '';
    const name = slash >= 0 ? row.storage_path.slice(slash + 1) : row.storage_path;
    const { data, error } = await this.getStorageClient()
      .storage
      .from(row.storage_bucket)
      .list(prefix, { limit: 100, search: name });
    if (error) throw new HttpException(`attachment_lookup_failed: ${error.message}`, HttpStatus.BAD_GATEWAY);
    const found = (data || []).find((item: any) => item?.name === name);
    if (!found) return null;
    const size = Number((found as any).metadata?.size ?? (found as any).metadata?.contentLength ?? (found as any).size ?? 0);
    return Number.isFinite(size) && size > 0 ? size : null;
  }

  private async verifyUploadedAttachments(rows: MessageAttachmentRow[]) {
    const span = this.startChatSpan('chat.attachment.verify', {
      attachmentCount: rows.length,
      sessionId: rows[0]?.session_id,
      kind: rows[0]?.kind,
    });
    const verified: Array<MessageAttachmentRow & { actual_byte_size: number }> = [];
    try {
      for (const row of rows) {
        const actualByteSize = await this.storageObjectByteSize(row);
        if (!actualByteSize) throw new HttpException('attachment_not_ready', HttpStatus.CONFLICT);
        if (actualByteSize > this.attachmentByteLimits[row.kind]) {
          throw new HttpException('attachment_too_large', HttpStatus.BAD_REQUEST);
        }
        verified.push({ ...row, actual_byte_size: actualByteSize });
      }
      span.setAttribute('actualByteSizeTotal', verified.reduce((sum, row) => sum + row.actual_byte_size, 0));
      span.setStatus({ code: SpanStatusCode.OK });
      return verified;
    } catch (error) {
      this.recordSpanError(span, error);
      throw error;
    } finally {
      span.end();
    }
  }

  private async shapeAttachment(row: MessageAttachmentRow): Promise<MessageAttachmentResponse> {
    const status = String(row.status || '').toLowerCase();
    const canDownload = status !== 'removed' && status !== 'failed';
    const [downloadUrl, thumbnailUrl] = canDownload
      ? await Promise.all([this.signedDownloadUrl(row), this.signedThumbnailUrl(row)])
      : [null, null];
    return {
      id: row.id,
      message_id: row.message_id,
      session_id: row.session_id,
      kind: row.kind,
      content_type: row.content_type,
      byte_size: Number(row.byte_size || 0),
      width: row.width,
      height: row.height,
      duration_ms: row.duration_ms,
      thumbnail_path: row.thumbnail_path,
      waveform: row.waveform,
      status: row.status,
      transcript_text: row.transcript_text,
      transcript_status: row.transcript_status,
      metadata: row.metadata || {},
      created_at: row.created_at,
      downloadUrl,
      thumbnailUrl,
      downloadExpiresIn: downloadUrl ? this.attachmentDownloadExpiresIn : undefined,
    };
  }

  private async attachmentsForMessages(q: TxQuery, messageIds: string[]) {
    if (!messageIds.length) return new Map<string, MessageAttachmentResponse[]>();
    const { rows } = await q<MessageAttachmentRow>(
      `select id, message_id, session_id, uploaded_by, kind, storage_bucket, storage_path,
              content_type, byte_size, width, height, duration_ms, thumbnail_path, waveform,
              status, transcript_text, transcript_status, metadata, created_at, updated_at
         from message_attachments
        where message_id = any($1::uuid[])
          and deleted_at is null
          and status <> 'removed'
        order by created_at asc`,
      [messageIds]
    );
    const shaped = await Promise.all(rows.map((row) => this.shapeAttachment(row)));
    const byMessage = new Map<string, MessageAttachmentResponse[]>();
    for (const attachment of shaped) {
      const messageId = attachment.message_id;
      if (!messageId) continue;
      const list = byMessage.get(messageId) || [];
      list.push(attachment);
      byMessage.set(messageId, list);
    }
    return byMessage;
  }

  private async attachRowsToMessage(q: TxQuery, sessionId: string, messageId: string, rows: Array<MessageAttachmentRow & { actual_byte_size: number }>) {
    for (const row of rows) {
      await q(
        `update message_attachments
            set message_id = $2::uuid,
                status = 'ready',
                byte_size = $3::bigint,
                transcript_status = case when kind = 'voice' and transcript_status = 'not_requested' then 'pending' else transcript_status end,
                metadata = coalesce(metadata, '{}'::jsonb) || $4::jsonb,
                updated_at = now()
          where id = $1::uuid
            and session_id = $5::uuid
            and uploaded_by = auth.uid()
            and message_id is null
            and deleted_at is null`,
        [
          row.id,
          messageId,
          row.actual_byte_size,
          JSON.stringify({ verifiedAt: new Date().toISOString(), declaredByteSize: Number(row.byte_size || 0) }),
          sessionId,
        ]
      );
    }
  }

  private async getSessionAccess(q: TxQuery, sessionId: string, actorHint?: 'user' | 'vet' | null) {
    const { rows } = await q<SessionMessageAccess>(
      `select s.id,
              s.status,
              s.mode,
              ou.full_name as owner_name,
              vu.full_name as vet_name,
              case
                when s.user_id = auth.uid() and s.vet_id = auth.uid() and $2::text = 'vet' then 'vet'
                when s.user_id = auth.uid() then 'user'
                when s.vet_id = auth.uid() then 'vet'
                else 'admin'
              end::text as actor_role,
              (
                select ec.id
                  from entitlement_consumptions ec
                 where ec.session_id = s.id
                   and ec.canceled_at is null
                 order by ec.created_at desc
                 limit 1
              ) as consumption_id,
              (
                select ec.finalized
                  from entitlement_consumptions ec
                 where ec.session_id = s.id
                   and ec.canceled_at is null
                 order by ec.created_at desc
                 limit 1
              ) as consumption_finalized
         from chat_sessions s
         left join users ou on ou.id = s.user_id
         left join users vu on vu.id = s.vet_id
        where s.id = $1::uuid
          and (s.user_id = auth.uid() or s.vet_id = auth.uid() or is_admin())
        limit 1`,
      [sessionId, actorHint || null]
    );
    return rows[0] || null;
  }

  private normalizeMessage(row: SessionMessageRow, attachments: MessageAttachmentResponse[] = []) {
    return {
      ...row,
      stream_order: Number(row.stream_order || 0),
      attachments,
    };
  }

  private async markSenderRead(q: TxQuery, messageId: string) {
    await q(
      `insert into message_receipts (message_id, user_id, delivered_at, read_at)
       values ($1::uuid, auth.uid(), now(), now())
       on conflict (message_id, user_id)
       do update set delivered_at = coalesce(message_receipts.delivered_at, excluded.delivered_at),
                     read_at = coalesce(message_receipts.read_at, excluded.read_at)`,
      [messageId]
    );
  }

  private async emitRoomBroadcast(q: TxQuery, sessionId: string, event: string, payload: Record<string, any>) {
    const span = this.startChatSpan('chat.broadcast.emit', { sessionId, event });
    try {
      await q(
        `select public.fn_emit_consult_room_broadcast($1::uuid, $2::text, $3::jsonb)`,
        [sessionId, event, JSON.stringify(payload)]
      );
      span.setStatus({ code: SpanStatusCode.OK });
    } catch (error) {
      this.recordSpanError(span, error);
      throw error;
    } finally {
      span.end();
    }
  }

  private async commitConsumptionIfNeeded(q: TxQuery, session: SessionMessageAccess) {
    if (!session.consumption_id || session.consumption_finalized === true) return false;
    const { rows } = await q<{ ok: boolean }>(
      `select fn_commit_consumption($1::uuid) as ok`,
      [session.consumption_id]
    );
    return rows[0]?.ok === true;
  }

  @Post(':sessionId/attachments/upload-url')
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'sessions.attachments.upload-url', limit: 30, windowMs: 60_000 })
  async createAttachmentUploadUrl(
    @Param('sessionId') sessionId: string,
    @Headers('x-cav-actor-role') actorRoleHeader: string | string[] | undefined,
    @Body() body: SessionAttachmentUploadBody,
  ) {
    const span = this.startChatSpan('chat.attachment.upload_url.create', { sessionId });
    try {
      const upload = this.validateAttachmentUpload(body || {});
      const actorHint = this.normalizeActorHint(actorRoleHeader);
      span.setAttributes({ kind: upload.kind, contentType: upload.contentType, byteSize: upload.byteSize });
      if (this.db.isStub) {
        span.setStatus({ code: SpanStatusCode.OK });
        return {
          ok: true,
          sessionId,
          attachment: {
            id: `att_${Date.now()}`,
            kind: upload.kind,
            content_type: upload.contentType,
            byte_size: upload.byteSize,
            status: 'pending',
            stub: true,
          },
          upload: { signedUrl: 'stub', path: 'stub', expiresIn: 3600 },
        } as any;
      }
      const bucket = this.chatMediaBucket();
      const result = await this.db.runInTx(async (q) => {
        const session = await this.getSessionAccess(q, sessionId, actorHint);
        if (!session) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
        if (session.actor_role === 'admin') throw new HttpException('admin_upload_not_supported', HttpStatus.FORBIDDEN);
        if (String(session.status || '').toLowerCase() !== 'active') {
          throw new HttpException('session_not_active', HttpStatus.CONFLICT);
        }
        const extension = this.attachmentExtensions[upload.contentType] || '.bin';
        const metadata = {
          ...upload.metadata,
          originalFileName: upload.fileName,
          declaredByteSize: upload.byteSize,
          uploadRequestedAt: new Date().toISOString(),
        };
        const { rows } = await q<MessageAttachmentRow>(
          `with candidate as (
             select gen_random_uuid() as id
           )
           insert into message_attachments (
             id,
             session_id,
             uploaded_by,
             kind,
             storage_bucket,
             storage_path,
             content_type,
             byte_size,
             width,
             height,
             duration_ms,
             waveform,
             transcript_status,
             metadata,
             status,
             created_at,
             updated_at
           )
           select candidate.id,
                  $1::uuid,
                  auth.uid(),
                  $2::text,
                  $3::text,
                  'chat-consults/' || $1::text || '/' || candidate.id::text || $4::text,
                  $5::text,
                  $6::bigint,
                  $7::int,
                  $8::int,
                  $9::int,
                  $10::jsonb,
                  case when $2::text = 'voice' then 'pending' else 'not_requested' end,
                  $11::jsonb,
                  'pending',
                  now(),
                  now()
             from candidate
           returning id, message_id, session_id, uploaded_by, kind, storage_bucket, storage_path,
                     content_type, byte_size, width, height, duration_ms, thumbnail_path, waveform,
                     status, transcript_text, transcript_status, metadata, created_at, updated_at`,
          [
            sessionId,
            upload.kind,
            bucket,
            extension,
            upload.contentType,
            upload.byteSize,
            upload.width,
            upload.height,
            upload.durationMs,
            JSON.stringify(upload.waveform),
            JSON.stringify(metadata),
          ]
        );
        return rows[0];
      });
      if (!result) throw new HttpException('attachment_create_failed', HttpStatus.BAD_REQUEST);
      const signed = await this.createSignedUploadUrl(result.storage_bucket, result.storage_path);
      span.setAttributes({ attachmentId: result.id, role: result.uploaded_by ? 'member' : 'unknown' });
      span.setStatus({ code: SpanStatusCode.OK });
      this.realtimeLog('attachment.upload_url.created', {
        sessionId,
        attachmentId: result.id,
        kind: result.kind,
        byteSize: Number(result.byte_size || 0),
      });
      await this.logAttachmentAudit('chat.attachments.upload_url.created', result.id, {
        sessionId,
        kind: result.kind,
        contentType: result.content_type,
        byteSize: Number(result.byte_size || 0),
      });
      return {
        ok: true,
        sessionId,
        attachment: await this.shapeAttachment(result),
        upload: {
          bucket: result.storage_bucket,
          path: result.storage_path,
          signedUrl: signed.signedUrl || signed.signedURL || null,
          token: signed.token || null,
          expiresIn: 7200,
        },
      };
    } catch (e: any) {
      await this.logAttachmentAudit('chat.attachments.upload_url.failed', null, {
        sessionId,
        kind: body?.kind || null,
        contentType: body?.contentType || body?.content_type || null,
        byteSize: body?.byteSize || body?.byte_size || null,
        error: e?.message || 'attachment_upload_url_failed',
      });
      this.realtimeLog('attachment.upload_url.failed', {
        sessionId,
        error: e?.message || 'attachment_upload_url_failed',
      });
      this.recordSpanError(span, e);
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'attachment_upload_url_failed', HttpStatus.BAD_REQUEST);
    } finally {
      span.end();
    }
  }

  @Get(':sessionId/attachments/:attachmentId/download-url')
  async refreshAttachmentDownloadUrl(
    @Param('sessionId') sessionId: string,
    @Param('attachmentId') attachmentId: string,
    @Headers('x-cav-actor-role') actorRoleHeader?: string | string[],
  ) {
    const span = this.startChatSpan('chat.attachment.download_url.endpoint', { sessionId, attachmentId });
    try {
      if (!this.uuidRegex.test(attachmentId)) throw new HttpException('attachment_id_invalid', HttpStatus.BAD_REQUEST);
      if (this.db.isStub) {
        span.setStatus({ code: SpanStatusCode.OK });
        return { ok: true, sessionId, attachment: null, mode: 'stub' } as any;
      }
      const actorHint = this.normalizeActorHint(actorRoleHeader);
      const result = await this.db.runInTx(async (q) => {
        const session = await this.getSessionAccess(q, sessionId, actorHint);
        if (!session) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
        const { rows } = await q<MessageAttachmentRow>(
          `select id, message_id, session_id, uploaded_by, kind, storage_bucket, storage_path,
                  content_type, byte_size, width, height, duration_ms, thumbnail_path, waveform,
                  status, transcript_text, transcript_status, metadata, created_at, updated_at
             from message_attachments
            where id = $2::uuid
              and session_id = $1::uuid
              and deleted_at is null
              and status not in ('removed', 'failed')
            limit 1`,
          [sessionId, attachmentId]
        );
        if (!rows[0]) throw new HttpException('attachment_not_found', HttpStatus.NOT_FOUND);
        return { session, attachment: rows[0] };
      });
      const attachment = await this.shapeAttachment(result.attachment);
      await this.logAttachmentAudit('chat.attachments.download_url.refreshed', attachmentId, {
        sessionId,
        role: result.session.actor_role,
        kind: result.attachment.kind,
      });
      span.setAttributes({ role: result.session.actor_role, kind: result.attachment.kind });
      span.setStatus({ code: SpanStatusCode.OK });
      return { ok: true, sessionId, attachment };
    } catch (e: any) {
      this.recordSpanError(span, e);
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'attachment_download_url_failed', HttpStatus.BAD_REQUEST);
    } finally {
      span.end();
    }
  }

  @Post(':sessionId/attachments/:attachmentId/remove')
  @HttpCode(HttpStatus.OK)
  async removeAttachment(
    @Param('sessionId') sessionId: string,
    @Param('attachmentId') attachmentId: string,
    @Headers('x-cav-actor-role') actorRoleHeader: string | string[] | undefined,
  ) {
    try {
      if (!this.uuidRegex.test(attachmentId)) throw new HttpException('attachment_id_invalid', HttpStatus.BAD_REQUEST);
      if (this.db.isStub) return { ok: true, sessionId, attachmentId, removed: true, mode: 'stub' } as any;
      const actorHint = this.normalizeActorHint(actorRoleHeader);
      const result = await this.db.runInTx(async (q) => {
        const session = await this.getSessionAccess(q, sessionId, actorHint);
        if (!session) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
        const { rows } = await q<{ id: string; kind: string }>(
          `update message_attachments
              set status = 'removed',
                  deleted_at = now(),
                  deleted_by = auth.uid(),
                  metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('removedAt', now(), 'removedByRole', $3::text),
                  updated_at = now()
            where id = $2::uuid
              and session_id = $1::uuid
              and deleted_at is null
              and (uploaded_by = auth.uid() or is_admin())
          returning id, kind`,
          [sessionId, attachmentId, session.actor_role]
        );
        if (!rows[0]) throw new HttpException('attachment_remove_forbidden', HttpStatus.FORBIDDEN);
        return { session, attachment: rows[0] };
      });
      await this.logAttachmentAudit('chat.attachments.removed', attachmentId, {
        sessionId,
        role: result.session.actor_role,
        kind: result.attachment.kind,
      });
      return { ok: true, sessionId, attachmentId, removed: true };
    } catch (e: any) {
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'attachment_remove_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get(':sessionId/messages')
  async list(
    @Param('sessionId') sessionId: string,
    @Headers('x-cav-actor-role') actorRoleHeader?: string | string[],
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string,
    @Query('since') since?: string,
    @Query('until') until?: string,
    @Query('sort') sort?: string,
    @Query('includeDeleted') includeDeletedStr?: string,
    @Query('afterStreamOrder') afterStreamOrderStr?: string,
  ) {
    const span = this.startChatSpan('chat.messages.list', { sessionId });
    try {
      const limit = Math.min(Math.max(parseInt(limitStr || '50', 10) || 50, 1), 200);
      const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
      span.setAttributes({ limit, offset, afterStreamOrder: Number(afterStreamOrderStr || 0) || 0 });
      if (this.db.isStub) {
        span.setStatus({ code: SpanStatusCode.OK });
        return { ok: true, sessionId, cursor: 0, items: [], receipts: [], mode: 'stub' } as any;
      }
      const actorHint = this.normalizeActorHint(actorRoleHeader);
      const result = await this.db.runInTx(async (q) => {
        const session = await this.getSessionAccess(q, sessionId, actorHint);
        if (!session) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
        const includeDeleted = ['1','true','yes'].includes((includeDeletedStr || '').toLowerCase());
        const filters: string[] = ['session_id = $1::uuid'];
        const args: any[] = [sessionId];
        let idx = 2;
        filters.push(`((( ${includeDeleted ? 'true' : 'false'} ) = true AND is_admin()) OR deleted_at IS NULL)`);
        const afterStreamOrder = Number(afterStreamOrderStr || 0);
        if (Number.isFinite(afterStreamOrder) && afterStreamOrder > 0) {
          filters.push(`stream_order > $${idx++}`);
          args.push(Math.floor(afterStreamOrder));
        }
        if (since) {
          const d = new Date(since); if (!isNaN(d.getTime())) { filters.push(`created_at >= $${idx++}`); args.push(d.toISOString()); }
        }
        if (until) {
          const d = new Date(until); if (!isNaN(d.getTime())) { filters.push(`created_at <= $${idx++}`); args.push(d.toISOString()); }
        }
        let order = 'stream_order asc';
        if (sort) {
          const v = sort.toLowerCase();
          if (v === 'created_at.asc') order = 'created_at asc';
          else if (v === 'created_at.desc') order = 'created_at desc';
          else if (v === 'stream_order.asc') order = 'stream_order asc';
          else if (v === 'stream_order.desc') order = 'stream_order desc';
        }
        const where = 'where ' + filters.join(' and ');
        const { rows } = await q<SessionMessageRow>(
          `select id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason
             from messages
             ${where}
            order by ${order}
            limit $${idx} offset $${idx+1}`,
          [...args, limit, offset]
        );
        const messageIds = rows.map((row) => row.id);
        const receipts = messageIds.length
          ? (await q(
              `select message_id, user_id, delivered_at, read_at
                 from message_receipts
                where message_id = any($1::uuid[])
                order by delivered_at asc nulls last, read_at asc nulls last`,
              [messageIds]
            )).rows
          : [];
        const items = rows.map((row) => this.normalizeMessage(row));
        const attachments = await this.attachmentsForMessages(q, messageIds);
        const hydratedItems = rows.map((row) => this.normalizeMessage(row, attachments.get(row.id) || []));
        const cursor = items.length ? items[items.length - 1].stream_order : 0;
        return { session, items: hydratedItems, receipts, cursor };
      });
      this.realtimeLog('messages.sync.completed', {
        sessionId,
        role: result.session.actor_role,
        status: result.session.status,
        count: result.items.length,
        receiptCount: result.receipts.length,
        cursor: result.cursor,
        afterStreamOrder: afterStreamOrderStr || null,
      });
      span.setAttributes({ role: result.session.actor_role, messageCount: result.items.length, receiptCount: result.receipts.length, cursor: result.cursor });
      span.setStatus({ code: SpanStatusCode.OK });
      return {
        ok: true,
        sessionId,
        session: {
          id: result.session.id,
          status: result.session.status,
          mode: result.session.mode,
          role: result.session.actor_role,
          ownerName: result.session.owner_name,
          vetName: result.session.vet_name,
        },
        cursor: result.cursor,
        items: result.items,
        receipts: result.receipts,
        sort: sort || 'stream_order.asc',
        since: since || null,
        until: until || null,
        afterStreamOrder: afterStreamOrderStr || null,
        includeDeleted: !!includeDeletedStr,
      };
    } catch (e: any) {
      this.realtimeLog('messages.sync.failed', {
        sessionId,
        error: e?.message || 'list_failed',
      });
      this.recordSpanError(span, e);
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'list_failed', HttpStatus.BAD_REQUEST);
    } finally {
      span.end();
    }
  }

  @Post(':sessionId/messages')
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'sessions.messages.create', limit: 30, windowMs: 60_000 })
  async create(
    @Param('sessionId') sessionId: string,
    @Headers('x-cav-actor-role') actorRoleHeader: string | string[] | undefined,
    @Body() body: SessionMessageBody,
  ) {
    const span = this.startChatSpan('chat.messages.create', { sessionId });
    try {
      const content = (body?.content || '').toString().trim();
      const clientKey = (body?.clientKey || body?.client_key || '').toString().trim() || null;
      const attachmentIds = this.normalizeAttachmentIds(body?.attachments);
      const actorHint = this.normalizeActorHint(actorRoleHeader);
      span.setAttributes({ contentLength: content.length, attachmentCount: attachmentIds.length, clientKeyPresent: !!clientKey });
      if (!content && attachmentIds.length === 0) {
        throw new HttpException('message_content_or_attachment_required', HttpStatus.BAD_REQUEST);
      }
      if (content.length > 4000) {
        throw new HttpException('content_too_long', HttpStatus.BAD_REQUEST);
      }
      if (clientKey && clientKey.length > 128) {
        throw new HttpException('client_key_too_long', HttpStatus.BAD_REQUEST);
      }
      if (this.db.isStub) {
        span.setStatus({ code: SpanStatusCode.OK });
        return {
          ok: true,
          sessionId,
          duplicate: false,
          committed: false,
          message: { id: `msg_${Date.now()}`, role: 'user', content, client_key: clientKey, stream_order: Date.now(), created_at: new Date().toISOString(), attachments: [], stub: true }
        } as any;
      }
      const result = await this.db.runInTx(async (q) => {
        const session = await this.getSessionAccess(q, sessionId, actorHint);
        if (!session) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
        if (session.actor_role === 'admin') throw new HttpException('admin_send_not_supported', HttpStatus.FORBIDDEN);
        const status = String(session.status || '').toLowerCase();
        if (status === 'pending_payment') throw new HttpException('payment_required', HttpStatus.PAYMENT_REQUIRED);
        if (status !== 'active') throw new HttpException('session_not_active', HttpStatus.CONFLICT);

        if (clientKey) {
          const { rows: existingRows } = await q<SessionMessageRow>(
            `select id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason
               from messages
              where session_id = $1::uuid
                and client_key = $2
              limit 1`,
            [sessionId, clientKey]
          );
          if (existingRows[0]) {
            await this.markSenderRead(q, existingRows[0].id);
            const committed = await this.commitConsumptionIfNeeded(q, session);
            const attachments = await this.attachmentsForMessages(q, [existingRows[0].id]);
            return { message: this.normalizeMessage(existingRows[0], attachments.get(existingRows[0].id) || []), duplicate: true, committed };
          }
        }

        let verifiedAttachments: Array<MessageAttachmentRow & { actual_byte_size: number }> = [];
        if (attachmentIds.length) {
          const { rows: attachmentRows } = await q<MessageAttachmentRow>(
            `select id, message_id, session_id, uploaded_by, kind, storage_bucket, storage_path,
                    content_type, byte_size, width, height, duration_ms, thumbnail_path, waveform,
                    status, transcript_text, transcript_status, metadata, created_at, updated_at
               from message_attachments
              where id = any($1::uuid[])
                and session_id = $2::uuid
                and uploaded_by = auth.uid()
                and message_id is null
                and deleted_at is null
              for update`,
            [attachmentIds, sessionId]
          );
          if (attachmentRows.length !== attachmentIds.length) {
            throw new HttpException('attachment_not_owned', HttpStatus.BAD_REQUEST);
          }
          this.validateAttachmentBatch(attachmentRows);
          verifiedAttachments = await this.verifyUploadedAttachments(attachmentRows);
        }

        const { rows } = await q<SessionMessageRow>(
          `insert into messages (id, session_id, sender_id, role, content, client_key, created_at)
           values (gen_random_uuid(), $1::uuid, auth.uid(), $2::text, $3::text, $4::text, now())
           returning id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason`,
          [sessionId, session.actor_role, content, clientKey]
        );
        const inserted = rows[0];
        if (!inserted) throw new HttpException('create_failed', HttpStatus.BAD_REQUEST);
        if (verifiedAttachments.length) {
          await this.attachRowsToMessage(q, sessionId, inserted.id, verifiedAttachments);
        }
        await q(
          `update chat_sessions
              set updated_at = now()
            where id = $1::uuid`,
          [sessionId]
        );
        const committed = await this.commitConsumptionIfNeeded(q, session);
        await this.markSenderRead(q, inserted.id);
        const attachments = await this.attachmentsForMessages(q, [inserted.id]);
        const message = this.normalizeMessage(inserted, attachments.get(inserted.id) || []);
        await this.emitRoomBroadcast(q, sessionId, 'messages', { sessionId, message });
        return { message, duplicate: false, committed };
      });
      this.realtimeLog('messages.send.completed', {
        sessionId,
        messageId: result.message?.id || null,
        role: result.message?.role || null,
        streamOrder: result.message?.stream_order || null,
        attachmentCount: result.message?.attachments?.length || 0,
        clientKeyPresent: !!clientKey,
        duplicate: result.duplicate === true,
        committed: result.committed === true,
      });
      if ((result.message?.attachments?.length || 0) > 0) {
        await this.logAttachmentAudit('chat.attachments.message.attached', result.message.id, {
          sessionId,
          messageId: result.message.id,
          attachmentIds: result.message.attachments.map((attachment: MessageAttachmentResponse) => attachment.id),
          attachmentCount: result.message.attachments.length,
          kinds: Array.from(new Set(result.message.attachments.map((attachment: MessageAttachmentResponse) => attachment.kind))),
          duplicate: result.duplicate === true,
        });
      }
      span.setAttributes({ messageId: result.message?.id || '', role: result.message?.role || '', streamOrder: result.message?.stream_order || 0, duplicate: result.duplicate === true, committed: result.committed === true });
      span.setStatus({ code: SpanStatusCode.OK });
      return { ok: true, sessionId, ...result };
    } catch (e: any) {
      if (Array.isArray(body?.attachments) && body.attachments.length > 0) {
        await this.logAttachmentAudit('chat.attachments.message.failed', null, {
          sessionId,
          attachmentCount: body.attachments.length,
          error: e?.message || 'create_failed',
        });
      }
      this.realtimeLog('messages.send.failed', {
        sessionId,
        clientKeyPresent: !!(body?.clientKey || body?.client_key),
        contentLength: (body?.content || '').toString().trim().length,
        attachmentCount: Array.isArray(body?.attachments) ? body.attachments.length : 0,
        error: e?.message || 'create_failed',
      });
      this.recordSpanError(span, e);
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'create_failed', HttpStatus.BAD_REQUEST);
    } finally {
      span.end();
    }
  }

  @Post(':sessionId/messages/read')
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'sessions.messages.read', limit: 60, windowMs: 60_000 })
  async markRead(
    @Param('sessionId') sessionId: string,
    @Headers('x-cav-actor-role') actorRoleHeader: string | string[] | undefined,
    @Body() body: SessionMessageReadBody,
  ) {
    const span = this.startChatSpan('chat.messages.read', { sessionId });
    try {
      const lastStreamOrder = Math.max(Number(body?.lastStreamOrder || 0) || 0, 0);
      span.setAttribute('lastStreamOrder', Math.floor(lastStreamOrder));
      if (!Number.isFinite(lastStreamOrder) || lastStreamOrder <= 0) {
        throw new HttpException('last_stream_order_required', HttpStatus.BAD_REQUEST);
      }
      if (this.db.isStub) {
        span.setStatus({ code: SpanStatusCode.OK });
        return { ok: true, sessionId, marked: 0, mode: 'stub' } as any;
      }
      const actorHint = this.normalizeActorHint(actorRoleHeader);
      const result = await this.db.runInTx(async (q) => {
        const session = await this.getSessionAccess(q, sessionId, actorHint);
        if (!session) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
        if (session.actor_role === 'admin') throw new HttpException('admin_read_not_supported', HttpStatus.FORBIDDEN);
        const { rows } = await q<{ message_id: string; user_id: string; delivered_at: string; read_at: string }>(
          `with visible_messages as (
             select m.id as message_id
               from messages m
              where m.session_id = $1::uuid
                and m.role <> $3::text
                and m.deleted_at is null
                and m.stream_order <= $2::bigint
           ), upserted as (
             insert into message_receipts (message_id, user_id, delivered_at, read_at)
             select message_id, auth.uid(), now(), now()
               from visible_messages
             on conflict (message_id, user_id)
             do update set delivered_at = coalesce(message_receipts.delivered_at, excluded.delivered_at),
                           read_at = coalesce(message_receipts.read_at, excluded.read_at)
             returning message_id, user_id, delivered_at, read_at
           )
           select message_id, user_id, delivered_at, read_at from upserted`,
          [sessionId, Math.floor(lastStreamOrder), session.actor_role]
        );
        if (rows.length) {
          await this.emitRoomBroadcast(q, sessionId, 'receipts', {
            sessionId,
            receipts: rows.map((row) => ({
              message_id: row.message_id,
              user_id: row.user_id,
              delivered_at: row.delivered_at,
              read_at: row.read_at,
            })),
          });
        }
        return { marked: rows.length };
      });
      this.realtimeLog('messages.read.completed', {
        sessionId,
        lastStreamOrder: Math.floor(lastStreamOrder),
        marked: result.marked,
      });
      span.setAttribute('marked', result.marked);
      span.setStatus({ code: SpanStatusCode.OK });
      return { ok: true, sessionId, ...result };
    } catch (e: any) {
      this.realtimeLog('messages.read.failed', {
        sessionId,
        lastStreamOrder: body?.lastStreamOrder || null,
        error: e?.message || 'mark_read_failed',
      });
      this.recordSpanError(span, e);
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'mark_read_failed', HttpStatus.BAD_REQUEST);
    } finally {
      span.end();
    }
  }

  @Post(':sessionId/telemetry')
  @HttpCode(204)
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'sessions.telemetry.create', limit: 180, windowMs: 60_000 })
  async telemetry(
    @Param('sessionId') sessionId: string,
    @Headers('x-cav-actor-role') actorRoleHeader: string | string[] | undefined,
    @Body() body: SessionTelemetryBody,
  ) {
    try {
      const actorHint = this.normalizeActorHint(actorRoleHeader);
      const event = this.normalizeTelemetryBody(body);
      if (this.db.isStub) return;
      await this.db.runInTx(async (q) => {
        const session = await this.getSessionAccess(q, sessionId, actorHint);
        if (!session) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
        if (session.actor_role === 'admin') throw new HttpException('admin_telemetry_not_supported', HttpStatus.FORBIDDEN);
        await q(
          `insert into chat_telemetry_events (
             id,
             session_id,
             actor_user_id,
             actor_role,
             event_type,
             client_key,
             message_id,
             attachment_id,
             duration_ms,
             value_ms,
             value_count,
             error_code,
             metadata,
             created_at
           ) values (
             gen_random_uuid(),
             $1::uuid,
             auth.uid(),
             $2::text,
             $3::text,
             $4::text,
             $5::uuid,
             $6::uuid,
             $7::int,
             $8::int,
             $9::int,
             $10::text,
             $11::jsonb,
             now()
           )`,
          [
            sessionId,
            session.actor_role,
            event.eventType,
            event.clientKey,
            event.messageId,
            event.attachmentId,
            event.durationMs,
            event.valueMs,
            event.valueCount,
            event.errorCode,
            JSON.stringify(event.metadata),
          ]
        );
      });
      this.realtimeLog('telemetry.recorded', {
        sessionId,
        eventType: event.eventType,
        clientKeyPresent: !!event.clientKey,
        messageIdPresent: !!event.messageId,
        attachmentIdPresent: !!event.attachmentId,
        errorCode: event.errorCode || null,
      });
      return;
    } catch (e: any) {
      this.realtimeLog('telemetry.failed', {
        sessionId,
        eventType: body?.eventType || body?.event_type || null,
        error: e?.message || 'telemetry_failed',
      });
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'telemetry_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get(':sessionId/transcript')
  async transcript(@Param('sessionId') sessionId: string, @Query('since') since?: string, @Query('until') until?: string, @Query('includeDeleted') includeDeletedStr?: string) {
    try {
      if (this.db.isStub) return { ok: true, sessionId, transcript: [], mode: 'stub' } as any;
      const rows = await this.db.runInTx(async (q) => {
        const includeDeleted = ['1','true','yes'].includes((includeDeletedStr || '').toLowerCase());
        const filters: string[] = ['session_id = $1', 'deleted_at is null'];
        const args: any[] = [sessionId];
        let idx = 2;
        filters[1] = `( ( ${includeDeleted ? 'true' : 'false'} ) = true AND is_admin() ) OR deleted_at IS NULL`;
        if (since) { const d = new Date(since); if (!isNaN(d.getTime())) { filters.push(`created_at >= $${idx++}`); args.push(d.toISOString()); } }
        if (until) { const d = new Date(until); if (!isNaN(d.getTime())) { filters.push(`created_at <= $${idx++}`); args.push(d.toISOString()); } }
        const where = 'where ' + filters.join(' and ');
        const { rows } = await q(
          `select id, role, content, created_at
             from messages
             ${where}
            order by created_at asc`,
          args
        );
        return rows as any[];
      });
      return { ok: true, sessionId, transcript: rows, since: since || null, until: until || null, includeDeleted: !!includeDeletedStr };
    } catch (e: any) {
      throw new HttpException(e?.message || 'transcript_failed', HttpStatus.BAD_REQUEST);
    }
  }
}