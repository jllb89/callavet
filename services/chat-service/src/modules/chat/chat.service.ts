import { Injectable, Logger } from '@nestjs/common';
import { Pool } from 'pg';
import jwt from 'jsonwebtoken';
import type { Socket } from 'socket.io';

export type ActorRole = 'user' | 'vet' | 'admin';

export interface ChatClaims {
  sub?: string;
  email?: string;
  role?: string;
  admin?: boolean;
  [key: string]: unknown;
}

export interface ChatActor {
  claims: ChatClaims;
  userId: string;
}

export interface StoredMessage {
  id: string;
  session_id: string;
  sender_id: string;
  role: 'user' | 'vet' | 'ai';
  content: string;
  client_key: string | null;
  stream_order: number;
  created_at: string;
  edited_at: string | null;
  deleted_at: string | null;
  redacted_at: string | null;
  redaction_reason: string | null;
}

export interface MessageReceipt {
  message_id: string;
  user_id: string;
  delivered_at: string | null;
  read_at: string | null;
}

export interface SessionSync {
  sessionId: string;
  kind: 'chat' | 'video';
  role: ActorRole;
  status: string | null;
  cursor: number;
  messages: StoredMessage[];
  receipts: MessageReceipt[];
}

interface SessionAccess {
  id: string;
  status: string | null;
  mode: 'chat' | 'video';
  actor_role: ActorRole;
  has_messages: boolean;
  latest_stream_order: number;
  consumption_id: string | null;
  consumption_finalized: boolean | null;
}

interface StoredMessageRow {
  id: string;
  session_id: string;
  sender_id: string;
  role: 'user' | 'vet' | 'ai';
  content: string;
  client_key: string | null;
  stream_order: string | number;
  created_at: string;
  edited_at: string | null;
  deleted_at: string | null;
  redacted_at: string | null;
  redaction_reason: string | null;
}

type TxQuery = <T = unknown>(sql: string, args?: unknown[]) => Promise<{ rows: T[] }>;

@Injectable()
export class ChatService {
  private readonly logger = new Logger(ChatService.name);
  private readonly pool?: Pool;

  constructor() {
    const databaseUrl = process.env.DATABASE_URL?.trim();
    if (!databaseUrl) {
      this.logger.warn('DATABASE_URL missing; realtime chat persistence is disabled');
      return;
    }

    const needsSsl = /[?&]sslmode=require/i.test(databaseUrl) || /supabase\.(co|com)/i.test(databaseUrl);
    const connectTimeoutMs = this.readPositiveIntEnv('CHAT_DB_CONNECT_TIMEOUT_MS', 7000);
    const queryTimeoutMs = this.readPositiveIntEnv('CHAT_DB_QUERY_TIMEOUT_MS', 10000);
    this.pool = new Pool({
      connectionString: databaseUrl,
      ssl: needsSsl ? { rejectUnauthorized: false } : undefined,
      connectionTimeoutMillis: connectTimeoutMs,
      query_timeout: queryTimeoutMs,
      statement_timeout: queryTimeoutMs,
    });
    this.pool.on('error', (error: Error) => {
      this.logger.warn(`Postgres pool error: ${error.name}: ${error.message}`);
    });
    this.logger.log(`Realtime DB pool configured (connectTimeoutMs=${connectTimeoutMs}, queryTimeoutMs=${queryTimeoutMs})`);
  }

  authenticateSocket(socket: Socket): ChatActor {
    const authz = this.extractAuthorization(socket);
    const xUserId = this.normalizeHeader(socket.handshake.headers['x-user-id']);
    const claims = this.decodeClaims(authz, xUserId);
    const userId = claims?.sub?.toString().trim();
    if (!userId || !UUID_RE.test(userId)) {
      throw new Error('unauthorized');
    }
    return { claims, userId };
  }

  async authorizeSessionAccess(sessionId: string, claims: ChatClaims): Promise<SessionAccess> {
    return this.withClaims(claims, async (q) => this.getSessionAccessInTx(q, sessionId));
  }

  async syncSession(sessionId: string, claims: ChatClaims, afterStreamOrder?: number): Promise<SessionSync> {
    return this.withClaims(claims, async (q) => {
      const session = await this.getSessionAccessInTx(q, sessionId);
      const messages = await this.listMessagesInTx(q, sessionId, afterStreamOrder);
      if (messages.length > 0) {
        await this.markDeliveredInTx(q, sessionId, messages.map((message) => message.id));
      }
      const receipts = messages.length > 0 ? await this.listReceiptsInTx(q, messages.map((message) => message.id)) : [];
      const cursor = messages.length > 0 ? messages[messages.length - 1].stream_order : session.latest_stream_order;
      return {
        sessionId,
        kind: session.mode,
        role: session.actor_role,
        status: session.status,
        cursor,
        messages,
        receipts,
      };
    });
  }

  async createMessage(sessionId: string, claims: ChatClaims, content: string, clientKey?: string): Promise<{ message: StoredMessage; duplicate: boolean; committed: boolean }> {
    const normalizedContent = content.trim();
    if (!normalizedContent) {
      throw new Error('content_required');
    }
    if (normalizedContent.length > 4000) {
      throw new Error('content_too_long');
    }
    const normalizedClientKey = clientKey?.trim() || null;
    if (normalizedClientKey && normalizedClientKey.length > 128) {
      throw new Error('client_key_too_long');
    }

    return this.withClaims(claims, async (q) => {
      const session = await this.getSessionAccessInTx(q, sessionId);
      if (session.actor_role === 'admin') {
        throw new Error('admin_send_not_supported');
      }
      if (session.status === 'pending_payment') {
        throw new Error('payment_required');
      }

      if (normalizedClientKey) {
        const { rows: existingRows } = await q<StoredMessageRow>(
          `select id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason
             from public.messages
            where session_id = $1
              and client_key = $2
            limit 1`,
          [sessionId, normalizedClientKey],
        );
        if (existingRows[0]) {
          await this.markSenderReadInTx(q, existingRows[0].id);
          return { message: this.mapMessage(existingRows[0]), duplicate: true, committed: false };
        }
      }

      const { rows } = await q<StoredMessageRow>(
        `insert into public.messages (id, session_id, sender_id, role, content, client_key, created_at)
         values (gen_random_uuid(), $1::uuid, auth.uid(), $2::text, $3::text, $4::text, now())
         returning id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason`,
        [sessionId, session.actor_role, normalizedContent, normalizedClientKey],
      );
      const message = rows[0];
      if (!message) {
        throw new Error('message_create_failed');
      }

      await q(
        `update public.chat_sessions
            set status = case when status in ('completed', 'canceled', 'pending_payment') then status else 'active' end,
                started_at = coalesce(started_at, now()),
                updated_at = now()
          where id = $1`,
        [sessionId],
      );

      let committed = false;
      if (session.consumption_id && !session.consumption_finalized) {
        const { rows: commitRows } = await q<{ ok: boolean }>('select fn_commit_consumption($1::uuid) as ok', [session.consumption_id]);
        committed = commitRows[0]?.ok === true;
      }

      await this.markSenderReadInTx(q, message.id);
      return { message: this.mapMessage(message), duplicate: false, committed };
    });
  }

  async markDelivery(sessionId: string, messageId: string, claims: ChatClaims): Promise<MessageReceipt> {
    return this.withClaims(claims, async (q) => {
      await this.getSessionAccessInTx(q, sessionId);
      const receipt = await this.upsertReceiptInTx(q, sessionId, messageId, false);
      return receipt;
    });
  }

  async markRead(sessionId: string, messageId: string, claims: ChatClaims): Promise<MessageReceipt> {
    return this.withClaims(claims, async (q) => {
      await this.getSessionAccessInTx(q, sessionId);
      const receipt = await this.upsertReceiptInTx(q, sessionId, messageId, true);
      return receipt;
    });
  }

  async editMessage(sessionId: string, messageId: string, content: string, claims: ChatClaims): Promise<StoredMessage> {
    const normalizedContent = content.trim();
    if (!normalizedContent) {
      throw new Error('content_required');
    }
    if (normalizedContent.length > 4000) {
      throw new Error('content_too_long');
    }

    return this.withClaims(claims, async (q) => {
      await this.getSessionAccessInTx(q, sessionId);
      const { rows } = await q<StoredMessageRow>(
        `update public.messages
            set content = $3,
                edited_at = now(),
                search_tsv = public.es_en_tsv($3)
          where id = $2
            and session_id = $1
            and deleted_at is null
            and redacted_at is null
            and (sender_id = auth.uid() or is_admin())
          returning id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason`,
        [sessionId, messageId, normalizedContent],
      );
      if (!rows[0]) {
        throw new Error('not_found');
      }
      return this.mapMessage(rows[0]);
    });
  }

  async deleteMessage(sessionId: string, messageId: string, claims: ChatClaims): Promise<StoredMessage> {
    return this.withClaims(claims, async (q) => {
      await this.getSessionAccessInTx(q, sessionId);
      const { rows } = await q<StoredMessageRow>(
        `update public.messages
            set deleted_at = now(),
                redacted_original_content = coalesce(redacted_original_content, content),
                content = '[deleted]',
                search_tsv = null
          where id = $2
            and session_id = $1
            and deleted_at is null
            and (sender_id = auth.uid() or is_admin())
          returning id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason`,
        [sessionId, messageId],
      );
      if (!rows[0]) {
        throw new Error('not_found');
      }
      return this.mapMessage(rows[0]);
    });
  }

  async redactMessage(sessionId: string, messageId: string, reason: string | undefined, claims: ChatClaims): Promise<StoredMessage> {
    const normalizedReason = reason?.trim().slice(0, 500) || null;
    return this.withClaims(claims, async (q) => {
      const session = await this.getSessionAccessInTx(q, sessionId);
      if (session.actor_role === 'user') {
        throw new Error('redaction_forbidden');
      }
      const { rows } = await q<StoredMessageRow>(
        `update public.messages
            set redacted_at = now(),
                redaction_reason = $3,
                redacted_original_content = coalesce(redacted_original_content, content),
                content = '[redacted]',
                search_tsv = null
          where id = $2
            and session_id = $1
            and deleted_at is null
          returning id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason`,
        [sessionId, messageId, normalizedReason],
      );
      if (!rows[0]) {
        throw new Error('not_found');
      }
      return this.mapMessage(rows[0]);
    });
  }

  async releaseSessionIfUnused(sessionId: string, claims: ChatClaims): Promise<{ released: boolean; reason: string }> {
    return this.withClaims(claims, async (q) => {
      const session = await this.getSessionAccessInTx(q, sessionId);
      if (session.has_messages) {
        return { released: false, reason: 'messages_present' };
      }
      if (!session.consumption_id || session.consumption_finalized) {
        return { released: false, reason: 'nothing_to_release' };
      }
      const { rows } = await q<{ ok: boolean }>('select fn_release_consumption($1::uuid) as ok', [session.consumption_id]);
      if (rows[0]?.ok !== true) {
        return { released: false, reason: 'release_failed' };
      }
      await q(
        `update public.chat_sessions
            set status = case when status in ('completed', 'canceled') then status else 'canceled' end,
                ended_at = coalesce(ended_at, now()),
                updated_at = now()
          where id = $1`,
        [sessionId],
      );
      return { released: true, reason: 'released' };
    });
  }

  private async withClaims<T>(claims: ChatClaims, fn: (q: TxQuery) => Promise<T>): Promise<T> {
    if (!this.pool) {
      throw new Error('db_unavailable');
    }
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      await client.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify(claims)]);
      if (claims.sub) {
        await client.query(`select set_config('request.jwt.claims.sub', $1, true)`, [claims.sub]);
      }
      if (claims.email) {
        await client.query(`select set_config('request.jwt.claims.email', $1, true)`, [claims.email]);
      }
      const q: TxQuery = async <T = unknown>(sql: string, args?: unknown[]) => (client.query as unknown as TxQuery)(sql, args);
      const result = await fn(q);
      await client.query('commit');
      return result;
    } catch (error) {
      try {
        await client.query('rollback');
      } catch {
        // noop
      }
      throw error;
    } finally {
      client.release();
    }
  }

  private async getSessionAccessInTx(q: TxQuery, sessionId: string): Promise<SessionAccess> {
    const { rows } = await q<SessionAccess>(
      `select s.id,
              s.status,
              coalesce(s.mode, 'chat')::text as mode,
              case
                when s.user_id = auth.uid() then 'user'
                when s.vet_id = auth.uid() then 'vet'
                else 'admin'
              end::text as actor_role,
              exists(
                select 1
                  from public.messages m
                 where m.session_id = s.id
                   and m.deleted_at is null
              ) as has_messages,
              coalesce((
                select max(m.stream_order)
                  from public.messages m
                 where m.session_id = s.id
              ), 0) as latest_stream_order,
              (
                select ec.id
                  from public.entitlement_consumptions ec
                 where ec.session_id = s.id
                   and ec.canceled_at is null
                 order by ec.created_at desc
                 limit 1
              ) as consumption_id,
              (
                select ec.finalized
                  from public.entitlement_consumptions ec
                 where ec.session_id = s.id
                   and ec.canceled_at is null
                 order by ec.created_at desc
                 limit 1
              ) as consumption_finalized
         from public.chat_sessions s
        where s.id = $1::uuid
          and (s.user_id = auth.uid() or s.vet_id = auth.uid() or is_admin())
        limit 1`,
      [sessionId],
    );
    if (!rows[0]) {
      throw new Error('not_found');
    }
    return {
      ...rows[0],
      mode: rows[0].mode === 'video' ? 'video' : 'chat',
      actor_role: rows[0].actor_role,
      latest_stream_order: Number(rows[0].latest_stream_order || 0),
    };
  }

  private async listMessagesInTx(q: TxQuery, sessionId: string, afterStreamOrder?: number): Promise<StoredMessage[]> {
    const args: unknown[] = [sessionId];
    let sql =
      `select id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason
         from public.messages
        where session_id = $1::uuid
          and deleted_at is null`;
    if (typeof afterStreamOrder === 'number' && Number.isFinite(afterStreamOrder) && afterStreamOrder > 0) {
      args.push(afterStreamOrder);
      sql += ` and stream_order > $2 order by stream_order asc limit 200`;
    } else {
      sql =
        `select id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason
           from (
             select id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason
               from public.messages
              where session_id = $1::uuid
                and deleted_at is null
              order by stream_order desc
              limit 50
           ) recent
          order by stream_order asc`;
    }
    const { rows } = await q<StoredMessageRow>(sql, args);
    return rows.map((row) => this.mapMessage(row));
  }

  private async listReceiptsInTx(q: TxQuery, messageIds: string[]): Promise<MessageReceipt[]> {
    const { rows } = await q<MessageReceipt>(
      `select message_id, user_id, delivered_at, read_at
         from public.message_receipts
        where message_id = any($1::uuid[])
        order by delivered_at asc nulls last, read_at asc nulls last`,
      [messageIds],
    );
    return rows;
  }

  private async markDeliveredInTx(q: TxQuery, sessionId: string, messageIds: string[]): Promise<void> {
    await q(
      `insert into public.message_receipts (message_id, user_id, delivered_at)
       select m.id, auth.uid(), now()
         from public.messages m
        where m.session_id = $1::uuid
          and m.id = any($2::uuid[])
       on conflict (message_id, user_id)
       do update set delivered_at = coalesce(public.message_receipts.delivered_at, excluded.delivered_at)`,
      [sessionId, messageIds],
    );
  }

  private async markSenderReadInTx(q: TxQuery, messageId: string): Promise<void> {
    await q(
      `insert into public.message_receipts (message_id, user_id, delivered_at, read_at)
       values ($1::uuid, auth.uid(), now(), now())
       on conflict (message_id, user_id)
       do update set delivered_at = coalesce(public.message_receipts.delivered_at, excluded.delivered_at),
                     read_at = coalesce(public.message_receipts.read_at, excluded.read_at)`,
      [messageId],
    );
  }

  private async upsertReceiptInTx(q: TxQuery, sessionId: string, messageId: string, read: boolean): Promise<MessageReceipt> {
    const { rows } = await q<MessageReceipt>(
      `insert into public.message_receipts (message_id, user_id, delivered_at, read_at)
       select m.id,
              auth.uid(),
              now(),
              case when $3::boolean then now() else null end
         from public.messages m
        where m.id = $2::uuid
          and m.session_id = $1::uuid
       on conflict (message_id, user_id)
       do update set delivered_at = coalesce(public.message_receipts.delivered_at, excluded.delivered_at),
                     read_at = case
                       when $3::boolean then coalesce(public.message_receipts.read_at, now())
                       else public.message_receipts.read_at
                     end
       returning message_id, user_id, delivered_at, read_at`,
      [sessionId, messageId, read],
    );
    if (!rows[0]) {
      throw new Error('not_found');
    }
    return rows[0];
  }

  private extractAuthorization(socket: Socket): string {
    const headerAuth = this.normalizeHeader(socket.handshake.headers.authorization);
    if (headerAuth?.startsWith('Bearer ')) {
      return headerAuth;
    }
    const authPayload = (socket.handshake.auth || {}) as Record<string, unknown>;
    const authToken = typeof authPayload.token === 'string' ? authPayload.token.trim() : '';
    if (authToken) {
      return authToken.startsWith('Bearer ') ? authToken : `Bearer ${authToken}`;
    }
    const queryToken = this.normalizeUnknown(socket.handshake.query.token);
    if (queryToken) {
      return queryToken.startsWith('Bearer ') ? queryToken : `Bearer ${queryToken}`;
    }
    return '';
  }

  private decodeClaims(authz: string, xUserId?: string): ChatClaims {
    const secret = process.env.SUPABASE_JWT_SECRET || '';
    let claims: ChatClaims | undefined;

    if (authz.startsWith('Bearer ')) {
      const token = authz.slice(7);
      if (secret) {
        try {
          claims = jwt.verify(token, secret) as ChatClaims;
        } catch {
          claims = undefined;
        }
      }
      if (!claims) {
        claims = this.decodeWithoutVerification(token);
      }
      if (claims && !claims.role) {
        claims.role = 'authenticated';
      }
    }

    if (!claims && xUserId && UUID_RE.test(xUserId)) {
      claims = { sub: xUserId, role: 'authenticated' };
    }

    if (!claims && process.env.DEV_TEST_USER_ID && UUID_RE.test(process.env.DEV_TEST_USER_ID.trim())) {
      claims = { sub: process.env.DEV_TEST_USER_ID.trim(), role: 'authenticated' };
    }

    return claims || {};
  }

  private decodeWithoutVerification(token: string): ChatClaims | undefined {
    try {
      const tokenPayload = token.split('.')[1];
      if (!tokenPayload) {
        return undefined;
      }
      let normalized = tokenPayload.replace(/-/g, '+').replace(/_/g, '/');
      while (normalized.length % 4 !== 0) {
        normalized += '=';
      }
      const decoded = JSON.parse(Buffer.from(normalized, 'base64').toString('utf8')) as ChatClaims;
      if (!decoded || typeof decoded !== 'object') {
        return undefined;
      }
      return {
        sub: decoded.sub,
        email: decoded.email,
        role: decoded.role,
        ...decoded,
      };
    } catch {
      return undefined;
    }
  }

  private mapMessage(row: StoredMessageRow): StoredMessage {
    return {
      ...row,
      stream_order: Number(row.stream_order || 0),
    };
  }

  private normalizeHeader(value: string | string[] | undefined): string {
    if (Array.isArray(value)) {
      return value[0]?.toString().trim() || '';
    }
    return value?.toString().trim() || '';
  }

  private normalizeUnknown(value: unknown): string {
    if (Array.isArray(value)) {
      return value[0]?.toString().trim() || '';
    }
    return typeof value === 'string' ? value.trim() : '';
  }

  private readPositiveIntEnv(name: string, fallback: number): number {
    const value = process.env[name]?.trim();
    if (!value) {
      return fallback;
    }
    const parsed = Number.parseInt(value, 10);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;