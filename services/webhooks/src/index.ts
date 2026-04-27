import express from "express";
import Stripe from "stripe";
import bodyParser from "body-parser";
import { Pool, PoolClient } from "pg";
import { WebhookReceiver } from "livekit-server-sdk";
const app = express();
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY || "", { apiVersion: "2024-06-20" });
const endpointSecret = process.env.STRIPE_WEBHOOK_SECRET || "";
let pool: Pool | undefined;

function db() {
  if (pool) return pool;
  const connectionString = process.env.DATABASE_URL || "";
  if (!connectionString) throw new Error("DATABASE_URL is not set");
  const needsSsl = /[?&]sslmode=require/.test(connectionString) || /supabase\.(co|com)/i.test(connectionString) || /pooler\.supabase\.com/i.test(connectionString);
  pool = new Pool({
    connectionString,
    ssl: needsSsl ? { rejectUnauthorized: false } : undefined,
  });
  return pool;
}

function firstHeader(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] : value;
}

function internalSecretFromRequest(req: express.Request) {
  const headerSecret = firstHeader(req.headers["x-internal-secret"] as string | string[] | undefined);
  const authHeader = firstHeader(req.headers.authorization);
  if (headerSecret) return headerSecret;
  if (authHeader?.toLowerCase().startsWith("bearer ")) return authHeader.slice(7).trim();
  return "";
}

function parseJsonObject(value: unknown): Record<string, any> {
  if (!value || typeof value !== "string") return {};
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

function safePayload(event: any) {
  try {
    return JSON.parse(JSON.stringify(event));
  } catch {
    return {
      event: event?.event || null,
      room: event?.room ? { name: event.room.name, sid: event.room.sid, metadata: event.room.metadata } : null,
      participant: event?.participant ? { identity: event.participant.identity, sid: event.participant.sid } : null,
    };
  }
}

function extractLiveKitFields(event: any) {
  const room = event?.room || {};
  const participant = event?.participant || {};
  const roomName = String(room.name || "").trim() || null;
  const metadata = parseJsonObject(room.metadata);
  const roomSessionId = roomName?.startsWith("cav-") ? roomName.slice(4) : "";
  const metadataSessionId = String(metadata.sessionId || "").trim();
  const sessionId = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(metadataSessionId)
    ? metadataSessionId
    : /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(roomSessionId)
      ? roomSessionId
      : null;

  return {
    eventType: String(event?.event || "").trim() || "unknown",
    roomName,
    roomSid: String(room.sid || "").trim() || null,
    sessionId,
    participantIdentity: String(participant.identity || "").trim() || null,
    participantSid: String(participant.sid || "").trim() || null,
  };
}

type LiveKitFields = ReturnType<typeof extractLiveKitFields>;

type VideoLifecycleState = {
  session_id: string;
  room_name: string | null;
  room_sid: string | null;
  status: string;
  first_room_started_at: string | null;
  first_participant_joined_at: string | null;
  owner_joined_at: string | null;
  host_joined_at: string | null;
  first_both_joined_at: string | null;
  room_finished_at: string | null;
  forced_end_at: string | null;
  entitlement_consumption_id: string | null;
  entitlement_finalized_at: string | null;
  entitlement_released_at: string | null;
  safety_reason: string | null;
  consumption_id: string | null;
  consumption_finalized: boolean | null;
  consumption_canceled_at: string | null;
};

function participantRoleFromIdentity(identity: string | null) {
  const prefix = String(identity || "").split(":", 1)[0];
  if (prefix === "owner" || prefix === "vet" || prefix === "admin") return prefix;
  return "participant";
}

function releaseReasonForState(state: Pick<VideoLifecycleState, "first_participant_joined_at" | "owner_joined_at" | "host_joined_at">) {
  if (!state.first_participant_joined_at) return "join_timeout";
  if (!state.host_joined_at) return "host_absent";
  if (!state.owner_joined_at) return "owner_absent";
  return "room_finished_before_consult";
}

function lifecycleStatusForReleaseReason(reason: string) {
  if (reason === "forced_end") return "forced_ended";
  if (reason === "join_timeout") return "timed_out";
  if (reason === "host_absent") return "host_absent";
  return "released";
}

async function insertLiveKitEvent(event: any) {
  const fields = extractLiveKitFields(event);
  const payload = safePayload(event);
  const { rows } = await db().query<{ id: string }>(
    `insert into livekit_video_events (
       id,
       event_type,
       room_name,
       room_sid,
       session_id,
       participant_identity,
       participant_sid,
       payload,
       received_at
     ) values (
       gen_random_uuid(),
       $1,
       $2,
       $3,
       $4::uuid,
       $5,
       $6,
       $7::jsonb,
       now()
     ) returning id`,
    [
      fields.eventType,
      fields.roomName,
      fields.roomSid,
      fields.sessionId,
      fields.participantIdentity,
      fields.participantSid,
      JSON.stringify(payload),
    ]
  );
  return { id: rows[0]?.id, ...fields };
}

async function markLiveKitEventProcessed(eventId: string, error?: string) {
  await db().query(
    `update livekit_video_events
        set processed_at = now(),
            processing_error = $2
      where id = $1::uuid`,
    [eventId, error || null]
  );
}

async function getVideoLifecycleState(client: PoolClient, sessionId: string) {
  const { rows } = await client.query<VideoLifecycleState>(
    `select v.session_id,
            v.room_name,
            v.room_sid,
            v.status,
            v.first_room_started_at::text,
            v.first_participant_joined_at::text,
            v.owner_joined_at::text,
            v.host_joined_at::text,
            v.first_both_joined_at::text,
            v.room_finished_at::text,
            v.forced_end_at::text,
            v.entitlement_consumption_id,
            v.entitlement_finalized_at::text,
            v.entitlement_released_at::text,
            v.safety_reason,
            ec.id as consumption_id,
            ec.finalized as consumption_finalized,
            ec.canceled_at::text as consumption_canceled_at
       from video_session_lifecycle v
  left join lateral (
        select id, finalized, canceled_at
          from entitlement_consumptions
         where session_id = v.session_id
           and consumption_type = 'video'
           and canceled_at is null
         order by created_at desc
         limit 1
       ) ec on true
      where v.session_id = $1::uuid
      limit 1`,
    [sessionId]
  );
  return rows[0] || null;
}

async function upsertVideoLifecycleForEvent(client: PoolClient, fields: LiveKitFields) {
  if (!fields.sessionId) return null;
  await client.query(
    `insert into video_session_lifecycle (session_id, room_name, room_sid, status, created_at, updated_at)
     values ($1::uuid, $2, $3, 'pending', now(), now())
     on conflict (session_id) do update
       set room_name = coalesce(excluded.room_name, video_session_lifecycle.room_name),
           room_sid = coalesce(excluded.room_sid, video_session_lifecycle.room_sid),
           updated_at = now()`,
    [fields.sessionId, fields.roomName, fields.roomSid]
  );

  if (fields.eventType === "room_started") {
    await client.query(
      `update video_session_lifecycle
          set first_room_started_at = coalesce(first_room_started_at, now()),
              status = case when status in ('ended', 'released', 'timed_out', 'host_absent', 'forced_ended') then status else 'waiting' end,
              updated_at = now()
        where session_id = $1::uuid`,
      [fields.sessionId]
    );
  }

  if (fields.eventType === "participant_joined") {
    const role = participantRoleFromIdentity(fields.participantIdentity);
    const ownerJoined = role === "owner";
    const hostJoined = role === "vet" || role === "admin";
    await client.query(
      `update video_session_lifecycle
          set first_participant_joined_at = coalesce(first_participant_joined_at, now()),
              owner_joined_at = case when $2 then coalesce(owner_joined_at, now()) else owner_joined_at end,
              host_joined_at = case when $3 then coalesce(host_joined_at, now()) else host_joined_at end,
              status = case when status in ('ended', 'released', 'timed_out', 'host_absent', 'forced_ended') then status else 'waiting' end,
              updated_at = now()
        where session_id = $1::uuid`,
      [fields.sessionId, ownerJoined, hostJoined]
    );
    await client.query(
      `update video_session_lifecycle
          set first_both_joined_at = coalesce(first_both_joined_at, case when owner_joined_at is not null and host_joined_at is not null then now() end),
              status = case
                when status in ('ended', 'released', 'timed_out', 'host_absent', 'forced_ended') then status
                when owner_joined_at is not null and host_joined_at is not null then 'live'
                else status
              end,
              safety_reason = case when owner_joined_at is not null and host_joined_at is not null then null else safety_reason end,
              updated_at = now()
        where session_id = $1::uuid`,
      [fields.sessionId]
    );
  }

  if (fields.eventType === "participant_left") {
    await client.query(
      `update video_session_lifecycle
          set last_participant_left_at = now(),
              updated_at = now()
        where session_id = $1::uuid`,
      [fields.sessionId]
    );
  }

  if (fields.eventType === "room_finished") {
    await client.query(
      `update video_session_lifecycle
          set room_finished_at = coalesce(room_finished_at, now()),
              updated_at = now()
        where session_id = $1::uuid`,
      [fields.sessionId]
    );
  }

  return getVideoLifecycleState(client, fields.sessionId);
}

async function commitVideoEntitlement(client: PoolClient, state: VideoLifecycleState) {
  const consumptionId = state.consumption_id || state.entitlement_consumption_id;
  if (!consumptionId) return false;
  if (state.consumption_finalized || state.entitlement_finalized_at) return true;
  const { rows } = await client.query<{ ok: boolean }>(`select fn_commit_consumption($1::uuid) as ok`, [consumptionId]);
  const committed = rows[0]?.ok === true;
  if (committed) {
    await client.query(
      `update video_session_lifecycle
          set entitlement_consumption_id = $2::uuid,
              entitlement_finalized_at = coalesce(entitlement_finalized_at, now()),
              entitlement_released_at = null,
              updated_at = now()
        where session_id = $1::uuid`,
      [state.session_id, consumptionId]
    );
  }
  return committed;
}

async function releaseVideoEntitlement(client: PoolClient, state: VideoLifecycleState) {
  const consumptionId = state.consumption_id || state.entitlement_consumption_id;
  if (!consumptionId) return false;
  if (state.entitlement_released_at) return true;
  const { rows } = await client.query<{ ok: boolean }>(`select fn_release_consumption($1::uuid) as ok`, [consumptionId]);
  const released = rows[0]?.ok === true;
  if (released) {
    await client.query(
      `update video_session_lifecycle
          set entitlement_consumption_id = $2::uuid,
              entitlement_released_at = coalesce(entitlement_released_at, now()),
              updated_at = now()
        where session_id = $1::uuid`,
      [state.session_id, consumptionId]
    );
  }
  return released;
}

async function finalizeVideoLifecycle(client: PoolClient, state: VideoLifecycleState, reason?: string) {
  const engaged = !!state.first_both_joined_at || state.consumption_finalized === true || !!state.entitlement_finalized_at;
  if (engaged) {
    await commitVideoEntitlement(client, state);
    await client.query(
      `update video_session_lifecycle
          set status = 'ended',
              room_finished_at = coalesce(room_finished_at, now()),
              safety_reason = coalesce($2, safety_reason),
              updated_at = now()
        where session_id = $1::uuid`,
      [state.session_id, reason || "completed"]
    );
    await client.query(
      `update chat_sessions
          set status = case when status = 'canceled' then status else 'completed' end,
              ended_at = coalesce(ended_at, now()),
              updated_at = now()
        where id = $1::uuid`,
      [state.session_id]
    );
    await client.query(
      `update appointments
          set status = case when status in ('canceled', 'no_show') then status else 'completed' end
        where session_id = $1::uuid`,
      [state.session_id]
    );
    await client.query(
      `update clinical_encounters
          set status = 'closed',
              ended_at = coalesce(ended_at, now()),
              updated_at = now()
        where session_id = $1::uuid`,
      [state.session_id]
    );
    return { action: "committed", reason: reason || "completed" };
  }

  const releaseReason = reason || (state.forced_end_at ? "forced_end" : releaseReasonForState(state));
  await releaseVideoEntitlement(client, state);
  await client.query(
    `update video_session_lifecycle
        set status = $2,
            room_finished_at = coalesce(room_finished_at, now()),
            safety_reason = $3,
            updated_at = now()
      where session_id = $1::uuid`,
    [state.session_id, lifecycleStatusForReleaseReason(releaseReason), releaseReason]
  );
  await client.query(
    `update chat_sessions
        set status = case when status = 'completed' then status else 'canceled' end,
            ended_at = coalesce(ended_at, now()),
            updated_at = now()
      where id = $1::uuid`,
    [state.session_id]
  );
  await client.query(
    `update appointments
        set status = case when status in ('completed', 'canceled') then status else 'no_show' end
      where session_id = $1::uuid`,
    [state.session_id]
  );
  await client.query(
    `update clinical_encounters
        set status = 'closed',
            ended_at = coalesce(ended_at, now()),
            updated_at = now()
      where session_id = $1::uuid`,
    [state.session_id]
  );
  return { action: "released", reason: releaseReason };
}

async function reconcileStaleVideoSessions(limit: number, timeoutMinutes: number) {
  const client = await db().connect();
  try {
    await client.query("begin");
    const { rows } = await client.query<VideoLifecycleState>(
      `select v.session_id,
              v.room_name,
              v.room_sid,
              v.status,
              v.first_room_started_at::text,
              v.first_participant_joined_at::text,
              v.owner_joined_at::text,
              v.host_joined_at::text,
              v.first_both_joined_at::text,
              v.room_finished_at::text,
              v.forced_end_at::text,
              v.entitlement_consumption_id,
              v.entitlement_finalized_at::text,
              v.entitlement_released_at::text,
              v.safety_reason,
              ec.id as consumption_id,
              ec.finalized as consumption_finalized,
              ec.canceled_at::text as consumption_canceled_at
         from video_session_lifecycle v
    left join lateral (
          select id, finalized, canceled_at
            from entitlement_consumptions
           where session_id = v.session_id
             and consumption_type = 'video'
             and canceled_at is null
           order by created_at desc
           limit 1
         ) ec on true
        where v.status in ('pending', 'waiting')
          and v.first_both_joined_at is null
          and coalesce(v.first_participant_joined_at, v.first_room_started_at, v.created_at) < now() - ($1::int * interval '1 minute')
        order by coalesce(v.first_participant_joined_at, v.first_room_started_at, v.created_at)
        limit $2
        for update of v skip locked`,
      [timeoutMinutes, limit]
    );

    const processed: Array<{ sessionId: string; action: string; reason: string }> = [];
    for (const row of rows) {
      const result = await finalizeVideoLifecycle(client, row, releaseReasonForState(row));
      processed.push({ sessionId: row.session_id, action: result.action, reason: result.reason });
    }
    await client.query("commit");
    return processed;
  } catch (error) {
    try { await client.query("rollback"); } catch {}
    throw error;
  } finally {
    client.release();
  }
}

async function syncLiveKitSessionState(fields: LiveKitFields) {
  if (!fields.sessionId) return;
  const client = await db().connect();
  try {
    await client.query("begin");
    await client.query(
      `update clinical_encounters
          set video_room_id = coalesce($2, video_room_id),
              updated_at = now()
        where session_id = $1::uuid`,
      [fields.sessionId, fields.roomName]
    );

    let lifecycle = await upsertVideoLifecycleForEvent(client, fields);

    if (fields.eventType === "room_started" || fields.eventType === "participant_joined") {
      await client.query(
        `update chat_sessions
            set status = case when status in ('completed', 'canceled') then status else 'active' end,
                started_at = coalesce(started_at, now()),
                updated_at = now()
          where id = $1::uuid`,
        [fields.sessionId]
      );
      await client.query(
        `update clinical_encounters
            set status = case when status = 'closed' then status else 'open' end,
                started_at = coalesce(started_at, now()),
                updated_at = now()
          where session_id = $1::uuid`,
        [fields.sessionId]
      );
      await client.query(
        `update appointments
            set status = case when status in ('scheduled', 'confirmed') then 'active' else status end
          where session_id = $1::uuid`,
        [fields.sessionId]
      );

      if (lifecycle?.first_both_joined_at) {
        await commitVideoEntitlement(client, lifecycle);
        await client.query(
          `update video_session_lifecycle
              set status = case when status in ('ended', 'released', 'timed_out', 'host_absent', 'forced_ended') then status else 'live' end,
                  updated_at = now()
            where session_id = $1::uuid`,
          [fields.sessionId]
        );
      }
    }

    if (fields.eventType === "room_finished") {
      lifecycle = lifecycle || await getVideoLifecycleState(client, fields.sessionId);
      if (lifecycle) await finalizeVideoLifecycle(client, lifecycle);
    }

    await client.query("commit");
  } catch (error) {
    try { await client.query("rollback"); } catch {}
    throw error;
  } finally {
    client.release();
  }
}

// Health
app.get("/health", (_req,res)=>res.json({ok:true, service:'webhooks'}));

app.get("/livekit/webhook", (_req, res) => {
  res.json({
    ok: true,
    service: "webhooks",
    endpoint: "/livekit/webhook",
    configured: {
      database: !!process.env.DATABASE_URL,
      livekitApiKey: !!process.env.LIVEKIT_API_KEY,
      livekitSecret: !!process.env.LIVEKIT_API_SECRET,
      reconcileSecret: !!process.env.INTERNAL_LIVEKIT_RECONCILE_SECRET,
    },
  });
});

app.post("/livekit/reconcile", bodyParser.json({ type: "application/json" }), async (req, res) => {
  const expectedSecret = process.env.INTERNAL_LIVEKIT_RECONCILE_SECRET || "";
  if (!expectedSecret) {
    console.error("[livekit-reconcile] missing INTERNAL_LIVEKIT_RECONCILE_SECRET env");
    return res.status(500).json({ ok: false, reason: "reconcile_secret_missing" });
  }
  if (internalSecretFromRequest(req) !== expectedSecret) {
    return res.status(401).json({ ok: false, reason: "unauthorized" });
  }
  const limit = Math.min(Math.max(Number(req.body?.limit || 50) || 50, 1), 200);
  const timeoutMinutes = Math.min(Math.max(Number(req.body?.timeoutMinutes || 10) || 10, 1), 240);
  try {
    const processed = await reconcileStaleVideoSessions(limit, timeoutMinutes);
    return res.json({ ok: true, processed: processed.length, results: processed });
  } catch (e: any) {
    console.error("[livekit-reconcile] failed", e?.message);
    return res.status(500).json({ ok: false, reason: "reconcile_failed" });
  }
});

app.post("/livekit/webhook", bodyParser.raw({ type: "application/json" }), async (req, res) => {
  const apiKey = process.env.LIVEKIT_API_KEY || "";
  const apiSecret = process.env.LIVEKIT_API_SECRET || "";
  if (!apiKey || !apiSecret) {
    console.error("[livekit-webhook] missing LiveKit webhook credentials");
    return res.status(500).json({ ok: false, reason: "livekit_credentials_missing" });
  }
  const rawBody = Buffer.isBuffer(req.body) ? req.body.toString("utf8") : JSON.stringify(req.body || {});
  const authHeader = firstHeader(req.headers.authorization) || firstHeader(req.headers["authorize"] as string | string[] | undefined);

  let event: any;
  try {
    event = await new WebhookReceiver(apiKey, apiSecret).receive(rawBody, authHeader);
  } catch (e: any) {
    console.error("[livekit-webhook] signature verification failed", e?.message);
    return res.status(400).json({ ok: false, reason: "signature_verification_failed" });
  }

  let persisted: Awaited<ReturnType<typeof insertLiveKitEvent>>;
  try {
    persisted = await insertLiveKitEvent(event);
  } catch (e: any) {
    console.error("[livekit-webhook] persist failed", e?.message);
    return res.status(500).json({ ok: false, reason: "persist_failed" });
  }

  try {
    await syncLiveKitSessionState(persisted);
    if (persisted.id) await markLiveKitEventProcessed(persisted.id);
  } catch (e: any) {
    const message = e?.message || "sync_failed";
    if (persisted.id) await markLiveKitEventProcessed(persisted.id, message).catch(() => {});
    console.error("[livekit-webhook] sync failed", persisted.eventType, persisted.sessionId, message);
    return res.status(500).json({ ok: false, reason: "sync_failed" });
  }

  console.log("[livekit-webhook] processed", persisted.eventType, persisted.roomName, persisted.sessionId);
  return res.json({ ok: true, received: true, eventType: persisted.eventType, eventId: persisted.id });
});

// Stripe Webhooks
app.post("/stripe/webhook", bodyParser.raw({ type: "application/json" }), (req, res) => {
  if (!endpointSecret) {
    console.error('[stripe-webhook] Missing STRIPE_WEBHOOK_SECRET env');
    return res.status(500).json({ ok: false, reason: 'webhook_secret_missing' });
  }
  const sig = req.headers["stripe-signature"] as string;
  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(req.body, sig, endpointSecret);
  } catch (e: any) {
    console.error('[stripe-webhook] signature verification failed', e?.message);
    return res.status(400).json({ ok: false, reason: 'signature_verification_failed' });
  }

  // Forward selected events to internal gateway for persistence
  async function forwardToGateway(event: Stripe.Event) {
    const gatewayUrl = process.env.GATEWAY_INTERNAL_URL; // e.g. http://gateway-api:3000/internal/stripe/event
    const secret = process.env.INTERNAL_STRIPE_EVENT_SECRET;
    if (!gatewayUrl) return console.warn('[stripe-webhook] GATEWAY_INTERNAL_URL not set, skipping forward');
    if (!secret) return console.warn('[stripe-webhook] INTERNAL_STRIPE_EVENT_SECRET not set, skipping forward');
    // Minimal payload; gateway will pull required fields
    const payload = { id: event.id, type: event.type, data: event.data.object };
    const started = Date.now();
    console.log('[stripe-webhook] forward start', event.id, event.type);
    try {
      const res = await fetch(gatewayUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-internal-secret': secret },
        body: JSON.stringify(payload),
      });
      const ms = Date.now() - started;
      if (!res.ok) {
        const text = await res.text();
        console.error('[stripe-webhook] forward error', event.id, event.type, res.status, `${ms}ms`, text.slice(0,200));
      } else {
        console.log('[stripe-webhook] forward ok', event.id, event.type, res.status, `${ms}ms`);
      }
    } catch (err: any) {
      const ms = Date.now() - started;
      console.error('[stripe-webhook] forward exception', event.id, event.type, `${ms}ms`, err?.message);
    }
  }

  switch (event.type) {
    case 'customer.subscription.created': {
      const sub = event.data.object as Stripe.Subscription;
      console.log('[stripe-webhook] subscription created', sub.id, sub.status, sub.customer);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'checkout.session.completed': {
      const session = event.data.object as Stripe.Checkout.Session;
      console.log('[stripe-webhook] checkout.session.completed', session.id, session.customer);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'payment_intent.succeeded': {
      const pi = event.data.object as Stripe.PaymentIntent;
      console.log('[stripe-webhook] payment_intent.succeeded', pi.id, pi.amount, pi.currency);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'payment_intent.payment_failed': {
      const pi = event.data.object as Stripe.PaymentIntent;
      console.log('[stripe-webhook] payment_intent.payment_failed', pi.id);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'charge.refunded':
    case 'charge.refund.updated': {
      const ch = event.data.object as Stripe.Charge;
      console.log('[stripe-webhook] charge refund event', event.type, ch.id, ch.payment_intent);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'invoice.payment_succeeded': {
      const invoice = event.data.object as Stripe.Invoice;
      console.log('[stripe-webhook] invoice.payment_succeeded', invoice.id);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'invoice.payment_failed': {
      const invoice = event.data.object as Stripe.Invoice;
      console.log('[stripe-webhook] invoice.payment_failed', invoice.id);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted': {
      const sub = event.data.object as Stripe.Subscription;
      console.log('[stripe-webhook] subscription change', event.type, sub.id);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    default:
      console.log('[stripe-webhook] Unhandled event', event.type);
  }
  return res.json({ ok: true, received: true });
});

// Test-forward endpoint: bypass Stripe signature, forward a synthetic event
// Guarded by TEST_FORWARD_SECRET env.
app.post("/stripe/webhook/test-forward", express.json(), async (req, res) => {
  const testSecret = process.env.TEST_FORWARD_SECRET || "";
  const hdr = (req.headers["x-test-forward-secret"] || "") as string;
  if (!testSecret || hdr !== testSecret) {
    return res.status(403).json({ ok: false, reason: "forbidden" });
  }
  const gatewayUrl = process.env.GATEWAY_INTERNAL_URL;
  const internalSecret = process.env.INTERNAL_STRIPE_EVENT_SECRET;
  if (!gatewayUrl || !internalSecret) {
    return res.status(500).json({ ok: false, reason: "missing_gateway_or_secret" });
  }
  const payload = req.body && req.body.id && req.body.type && req.body.data ? req.body : { id: `evt_test_${Date.now()}`, type: "charge.refunded", data: { payment_intent: "pi_test_manual" } };
  try {
    const r = await fetch(gatewayUrl, {
      method: "POST",
      headers: { "content-type": "application/json", "x-internal-secret": internalSecret },
      body: JSON.stringify(payload),
    });
    const text = await r.text();
    return res.status(r.status).send(text);
  } catch (e: any) {
    return res.status(500).json({ ok: false, reason: e?.message || "forward_failed" });
  }
});

app.listen(4200, '0.0.0.0', ()=>console.log("Webhooks :4200"));
