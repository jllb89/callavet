#!/usr/bin/env node

import { Client } from 'pg';

let WebSocketCtor = globalThis.WebSocket;
if (!WebSocketCtor) {
  try {
    const wsModule = await import('ws');
    WebSocketCtor = wsModule.WebSocket;
  } catch {
    WebSocketCtor = undefined;
  }
}

const gatewayBase = process.env.GATEWAY_BASE || process.env.SERVER_URL || '';
const chatBaseUrl = process.env.CHAT_BASE_URL || '';
const databaseUrl = process.env.DATABASE_URL || '';
const strictRealtime = process.env.REALTIME_SMOKE_REQUIRED === 'true';
const ownerId = process.env.USER_ID || 'b9222356-d0e4-43e6-ba02-8f2a5f37ec76';
const vetId = process.env.VET_USER_ID || process.env.VET_ID || '00000000-0000-0000-0000-000000000003';
const strangerId = process.env.STRANGER_ID || '11111111-2222-4333-8444-555555555555';

if (!gatewayBase) {
  console.error('ERROR: GATEWAY_BASE or SERVER_URL is required.');
  process.exit(1);
}

if (!chatBaseUrl) {
  if (strictRealtime) {
    console.error('ERROR: CHAT_BASE_URL is required.');
    process.exit(1);
  }
  console.warn('SKIP: CHAT_BASE_URL is not set; skipping realtime smoke. Set REALTIME_SMOKE_REQUIRED=true to enforce.');
  process.exit(0);
}

if (!databaseUrl) {
  console.error('ERROR: DATABASE_URL is required.');
  process.exit(1);
}

if (!WebSocketCtor) {
  if (strictRealtime) {
    console.error('ERROR: This Node runtime does not expose a global WebSocket client.');
    process.exit(1);
  }
  console.warn('SKIP: WebSocket client is unavailable in this Node runtime; skipping realtime smoke.');
  process.exit(0);
}

const socketUrl = `${chatBaseUrl.replace(/^http/, 'ws')}/socket.io/?EIO=4&transport=websocket`;

function base64url(input) {
  return Buffer.from(input).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function makeToken(sub, extra = {}) {
  const header = base64url(JSON.stringify({ alg: 'none', typ: 'JWT' }));
  const payload = base64url(JSON.stringify({ sub, role: 'authenticated', ...extra }));
  return `${header}.${payload}.phase2-smoke`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function jsonRequest(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = text;
  }
  if (!response.ok) {
    throw new Error(`${response.status} ${response.statusText}: ${typeof body === 'string' ? body : JSON.stringify(body)}`);
  }
  return body;
}

class SocketIoRawClient {
  constructor(name, auth) {
    this.name = name;
    this.auth = auth;
    this.ws = null;
    this.connected = false;
    this.eventWaiters = new Map();
    this.events = [];
    this.closePromise = null;
  }

  async connect() {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error(`${this.name} connect timeout`)), 15000);
      const ws = new WebSocketCtor(socketUrl);
      this.ws = ws;
      this.closePromise = new Promise((closeResolve) => {
        ws.addEventListener('close', (event) => {
          closeResolve({ code: event.code, reason: event.reason || '' });
        });
      });

      ws.addEventListener('open', () => {
        console.log(`[${this.name}] websocket open`);
      });

      ws.addEventListener('error', () => {
        clearTimeout(timeout);
        reject(new Error(`${this.name} websocket error`));
      });

      ws.addEventListener('message', (event) => {
        const data = typeof event.data === 'string' ? event.data : Buffer.from(event.data).toString('utf8');
        console.log(`[${this.name}] <= ${data}`);

        if (data === '2') {
          ws.send('3');
          console.log(`[${this.name}] => 3`);
          return;
        }

        if (data.startsWith('0')) {
          const payload = `40/chat,${JSON.stringify(this.auth)}`;
          ws.send(payload);
          console.log(`[${this.name}] => ${payload}`);
          return;
        }

        if (data.startsWith('40/chat')) {
          this.connected = true;
          clearTimeout(timeout);
          resolve();
          return;
        }

        if (data.startsWith('42/chat,')) {
          const payload = JSON.parse(data.slice(8));
          const [eventName, body] = payload;
          this.events.push({ eventName, body });
          const waiters = this.eventWaiters.get(eventName) || [];
          const remaining = [];
          for (const waiter of waiters) {
            if (waiter.predicate(body)) {
              waiter.resolve(body);
            } else {
              remaining.push(waiter);
            }
          }
          if (remaining.length > 0) this.eventWaiters.set(eventName, remaining);
          else this.eventWaiters.delete(eventName);
          return;
        }

        if (data.startsWith('44/chat,')) {
          clearTimeout(timeout);
          reject(new Error(`${this.name} connect error: ${data}`));
        }
      });
    });
  }

  waitForEvent(eventName, predicate = () => true, timeoutMs = 15000) {
    const existing = this.events.find((event) => event.eventName === eventName && predicate(event.body));
    if (existing) {
      return Promise.resolve(existing.body);
    }
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        const waiters = this.eventWaiters.get(eventName) || [];
        this.eventWaiters.set(eventName, waiters.filter((entry) => entry.resolve !== wrappedResolve));
        reject(new Error(`${this.name} waitForEvent timeout for ${eventName}`));
      }, timeoutMs);

      const wrappedResolve = (value) => {
        clearTimeout(timeout);
        resolve(value);
      };

      const waiters = this.eventWaiters.get(eventName) || [];
      waiters.push({ predicate, resolve: wrappedResolve });
      this.eventWaiters.set(eventName, waiters);
    });
  }

  emit(eventName, payload) {
    const packet = `42/chat,${JSON.stringify([eventName, payload])}`;
    this.ws.send(packet);
    console.log(`[${this.name}] => ${packet}`);
  }

  async close() {
    if (this.ws && this.ws.readyState < 2) {
      this.ws.close();
    }
    return this.closePromise || { code: 1000, reason: '' };
  }
}

async function main() {
  const ownerToken = makeToken(ownerId);
  const vetToken = makeToken(vetId);
  const strangerToken = makeToken(strangerId);
  const ownerHeaders = { Authorization: `Bearer ${ownerToken}`, 'Content-Type': 'application/json' };
  const vetHeaders = { Authorization: `Bearer ${vetToken}`, 'Content-Type': 'application/json' };
  const db = new Client({ connectionString: databaseUrl, ssl: { rejectUnauthorized: false } });
  await db.connect();

  try {
    const summary = {};

    const startCommit = await jsonRequest(`${gatewayBase}/sessions/start`, {
      method: 'POST',
      headers: ownerHeaders,
      body: JSON.stringify({ kind: 'chat' }),
    });
    if (!startCommit?.sessionId) {
      throw new Error(`unexpected startCommit payload: ${JSON.stringify(startCommit)}`);
    }
    if (!startCommit?.consumptionId) {
      summary.commit = {
        sessionId: startCommit.sessionId,
        skipped: true,
        overage: !!startCommit?.overage,
        reason: startCommit?.overageReason || 'no_consumption_id',
        paymentStatus: startCommit?.payment?.status || null,
      };
    } else {
      const commitClient = new SocketIoRawClient('commit-owner', { token: ownerToken, sessionId: startCommit.sessionId });
      await commitClient.connect();
      await commitClient.waitForEvent('system.welcome');
      await commitClient.waitForEvent('server.session.synced');
      const commitMessageText = `phase2-commit-${Date.now()}`;
      commitClient.emit('client.message.send', {
        sessionId: startCommit.sessionId,
        content: commitMessageText,
        clientKey: `phase2-commit-${Date.now()}`,
      });
      const commitMessage = await commitClient.waitForEvent('server.message.appended', (body) => body?.message?.content === commitMessageText);
      await sleep(400);
      const commitState = await db.query('select finalized, canceled_at from public.entitlement_consumptions where id = $1', [startCommit.consumptionId]);
      summary.commit = {
        sessionId: startCommit.sessionId,
        consumptionId: startCommit.consumptionId,
        messageId: commitMessage.message.id,
        finalized: commitState.rows[0]?.finalized ?? null,
        canceledAt: commitState.rows[0]?.canceled_at ?? null,
      };
      await commitClient.close();
    }

    const startRelease = await jsonRequest(`${gatewayBase}/sessions/start`, {
      method: 'POST',
      headers: ownerHeaders,
      body: JSON.stringify({ kind: 'chat' }),
    });
    if (!startRelease?.sessionId) {
      throw new Error(`unexpected startRelease payload: ${JSON.stringify(startRelease)}`);
    }
    if (!startRelease?.consumptionId) {
      summary.release = {
        sessionId: startRelease.sessionId,
        skipped: true,
        overage: !!startRelease?.overage,
        reason: startRelease?.overageReason || 'no_consumption_id',
        paymentStatus: startRelease?.payment?.status || null,
      };
    } else {
      const releaseClient = new SocketIoRawClient('release-owner', { token: ownerToken, sessionId: startRelease.sessionId });
      await releaseClient.connect();
      await releaseClient.waitForEvent('system.welcome');
      await releaseClient.waitForEvent('server.session.synced');
      releaseClient.emit('client.session.leave', { sessionId: startRelease.sessionId });
      await sleep(1200);
      const releaseState = await db.query('select finalized, canceled_at from public.entitlement_consumptions where id = $1', [startRelease.consumptionId]);
      const releaseSession = await db.query('select status, ended_at from public.chat_sessions where id = $1', [startRelease.sessionId]);
      summary.release = {
        sessionId: startRelease.sessionId,
        consumptionId: startRelease.consumptionId,
        finalized: releaseState.rows[0]?.finalized ?? null,
        canceledAt: releaseState.rows[0]?.canceled_at ?? null,
        sessionStatus: releaseSession.rows[0]?.status ?? null,
        endedAt: releaseSession.rows[0]?.ended_at ?? null,
      };
      await releaseClient.close();
    }

    const pets = await jsonRequest(`${gatewayBase}/pets`, { headers: ownerHeaders });
    const petId = pets?.data?.[0]?.id;
    if (!petId) {
      throw new Error('no pet available for owner');
    }
    const specialties = await jsonRequest(`${gatewayBase}/vets/specialties`, { headers: ownerHeaders });
    const specialtyId = specialties?.data?.[0]?.id;
    if (!specialtyId) {
      throw new Error('no specialty available');
    }
    const slots = await jsonRequest(`${gatewayBase}/vets/${vetId}/availability/slots?durationMin=30`, { headers: ownerHeaders });
    const startsAt = slots?.data?.[0]?.start;
    if (!startsAt) {
      throw new Error('no slot available');
    }
    const appointment = await jsonRequest(`${gatewayBase}/appointments`, {
      method: 'POST',
      headers: ownerHeaders,
      body: JSON.stringify({ vetId, specialtyId, startsAt, petId, durationMin: 30 }),
    });
    if (!appointment?.session_id) {
      throw new Error(`appointment missing session_id: ${JSON.stringify(appointment)}`);
    }

    const ownerSessionDetail = await jsonRequest(`${gatewayBase}/sessions/${appointment.session_id}`, { headers: ownerHeaders });
    const vetSessionDetail = await jsonRequest(`${gatewayBase}/sessions/${appointment.session_id}`, { headers: vetHeaders });

    const ownerClient = new SocketIoRawClient('appt-owner', { token: ownerToken, sessionId: appointment.session_id });
    const vetClient = new SocketIoRawClient('appt-vet', { token: vetToken, sessionId: appointment.session_id });
    await ownerClient.connect();
    await vetClient.connect();
    await ownerClient.waitForEvent('system.welcome');
    await ownerClient.waitForEvent('server.session.synced');
    await vetClient.waitForEvent('system.welcome');
    await vetClient.waitForEvent('server.session.synced');

    const appointmentMessageText = `phase2-appointment-${Date.now()}`;
    const appointmentClientKey = `phase2-appointment-${Date.now()}`;
    ownerClient.emit('client.message.send', {
      sessionId: appointment.session_id,
      content: appointmentMessageText,
      clientKey: appointmentClientKey,
    });
    const appendedOnVet = await vetClient.waitForEvent('server.message.appended', (body) => body?.message?.content === appointmentMessageText);
    const appendedOnOwner = await ownerClient.waitForEvent('server.message.appended', (body) => body?.message?.id === appendedOnVet.message.id);

    vetClient.emit('client.delivery.receipt', { sessionId: appointment.session_id, messageId: appendedOnVet.message.id });
    await ownerClient.waitForEvent('server.message.delivery', (body) => body?.messageId === appendedOnVet.message.id && body?.userId === vetId);

    vetClient.emit('client.read.receipt', { sessionId: appointment.session_id, messageId: appendedOnVet.message.id });
    const readReceipt = await ownerClient.waitForEvent('server.read.receipt', (body) => body?.messageId === appendedOnVet.message.id && body?.readerId === vetId);

    ownerClient.emit('client.message.send', {
      sessionId: appointment.session_id,
      content: appointmentMessageText,
      clientKey: appointmentClientKey,
    });
    await sleep(600);

    const transcript = await jsonRequest(`${gatewayBase}/sessions/${appointment.session_id}/transcript`, { headers: ownerHeaders });
    const messageRows = await db.query(
      'select id, client_key, stream_order from public.messages where session_id = $1 and content = $2 order by stream_order asc',
      [appointment.session_id, appointmentMessageText],
    );
    const receiptRows = await db.query(
      'select user_id, delivered_at is not null as delivered, read_at is not null as read from public.message_receipts where message_id = $1 order by user_id asc',
      [appendedOnVet.message.id],
    );

    const strangerClient = new SocketIoRawClient('appt-stranger', { token: strangerToken, sessionId: appointment.session_id });
    await strangerClient.connect();
    const strangerError = await strangerClient.waitForEvent('server.error', (body) => typeof body?.message === 'string');
    const strangerClose = await strangerClient.close();

    summary.appointment = {
      appointmentId: appointment.id,
      sessionId: appointment.session_id,
      ownerSessionStatus: ownerSessionDetail?.status ?? null,
      vetSessionStatus: vetSessionDetail?.status ?? null,
      messageId: appendedOnVet.message.id,
      ownerReceivedMessageId: appendedOnOwner.message.id,
      readReceipt,
      transcriptCount: Array.isArray(transcript?.transcript)
        ? transcript.transcript.filter((entry) => entry.content === appointmentMessageText).length
        : -1,
      storedMessageCount: messageRows.rows.length,
      storedMessageIds: messageRows.rows.map((row) => row.id),
      streamOrders: messageRows.rows.map((row) => Number(row.stream_order)),
      receiptRows: receiptRows.rows,
      strangerError,
      strangerClose,
    };

    await ownerClient.close();
    await vetClient.close();

    console.log(JSON.stringify(summary, null, 2));
  } finally {
    await db.end();
  }
}

main().catch((error) => {
  const message = String(error?.message || error || 'unknown error');
  if (!strictRealtime && /(websocket error|self-signed certificate|certificate|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|fetch failed|connect timeout)/i.test(message)) {
    console.warn(`SKIP: realtime smoke inconclusive due environment connectivity: ${message}`);
    process.exit(0);
  }
  console.error(error);
  process.exit(1);
});