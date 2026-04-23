import {
  ConnectedSocket,
  MessageBody,
  OnGatewayConnection,
  OnGatewayDisconnect,
  OnGatewayInit,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
  WsException,
} from '@nestjs/websockets';
import { Logger } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import { z } from 'zod';
import { ChatActor, ChatService, MessageReceipt, StoredMessage } from './chat.service';

@WebSocketGateway({ namespace: '/chat', cors: { origin: '*' } })
export class ChatGateway implements OnGatewayInit, OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server!: Server;

  private readonly logger = new Logger(ChatGateway.name);

  constructor(private readonly chat: ChatService) {}

  afterInit(server: Server) {
    server.use((socket, next) => {
      try {
        const actor = this.chat.authenticateSocket(socket);
        this.getState(socket).actor = actor;
        this.getState(socket).sessions = this.getState(socket).sessions || new Set<string>();
        next();
      } catch (error) {
        next(new Error(this.toErrorMessage(error)));
      }
    });
  }

  async handleConnection(client: Socket) {
    const sessionId = this.normalizeUnknown((client.handshake.auth as Record<string, unknown> | undefined)?.sessionId) || this.normalizeUnknown(client.handshake.query.sessionId);
    const afterStreamOrder = this.parseOptionalNumber(
      this.normalizeUnknown((client.handshake.auth as Record<string, unknown> | undefined)?.afterStreamOrder) || this.normalizeUnknown(client.handshake.query.afterStreamOrder),
    );
    if (!sessionId) {
      return;
    }
    try {
      await this.joinSession(client, { sessionId, afterStreamOrder });
    } catch (error) {
      client.emit('server.error', { message: this.toErrorMessage(error) });
      client.disconnect(true);
    }
  }

  handleDisconnect(client: Socket) {
    const actor = this.getActor(client);
    if (!actor) {
      return;
    }
    for (const sessionId of this.getSessions(client)) {
      client.to(sessionId).emit('presence', { sessionId, userId: actor.userId, left: true });
    }
  }

  @SubscribeMessage('join')
  async onJoinLegacy(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    return this.joinSession(client, this.parseJoinPayload(data));
  }

  @SubscribeMessage('client.session.join')
  async onJoin(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    return this.joinSession(client, this.parseJoinPayload(data));
  }

  @SubscribeMessage('leave')
  async onLeaveLegacy(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    return this.leaveSession(client, this.parseSessionOnlyPayload(data));
  }

  @SubscribeMessage('client.session.leave')
  async onLeave(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    return this.leaveSession(client, this.parseSessionOnlyPayload(data));
  }

  @SubscribeMessage('typing')
  async onTypingLegacy(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    return this.broadcastTyping(client, this.parseTypingPayload(data));
  }

  @SubscribeMessage('client.typing')
  async onTyping(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    return this.broadcastTyping(client, this.parseTypingPayload(data));
  }

  @SubscribeMessage('message:new')
  async onMessageLegacy(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    return this.createMessage(client, this.parseMessagePayload(data));
  }

  @SubscribeMessage('client.message.send')
  async onMessage(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    return this.createMessage(client, this.parseMessagePayload(data));
  }

  @SubscribeMessage('client.delivery.receipt')
  async onDelivery(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    const payload = this.parseReceiptPayload(data);
    const actor = this.requireActor(client);
    try {
      const receipt = await this.chat.markDelivery(payload.sessionId, payload.messageId, actor.claims);
      this.emitDelivery(payload.sessionId, receipt);
      return { ok: true, receipt };
    } catch (error) {
      throw new WsException(this.toErrorMessage(error));
    }
  }

  @SubscribeMessage('client.read.receipt')
  async onRead(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    const payload = this.parseReceiptPayload(data);
    const actor = this.requireActor(client);
    try {
      const receipt = await this.chat.markRead(payload.sessionId, payload.messageId, actor.claims);
      this.server.to(payload.sessionId).emit('server.read.receipt', {
        messageId: receipt.message_id,
        readerId: receipt.user_id,
        readAt: receipt.read_at,
      });
      return { ok: true, receipt };
    } catch (error) {
      throw new WsException(this.toErrorMessage(error));
    }
  }

  @SubscribeMessage('client.message.edit')
  async onEdit(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    const payload = this.parseEditPayload(data);
    const actor = this.requireActor(client);
    try {
      const message = await this.chat.editMessage(payload.sessionId, payload.messageId, payload.content, actor.claims);
      this.server.to(payload.sessionId).emit('server.message.edited', { message });
      return { ok: true, message };
    } catch (error) {
      throw new WsException(this.toErrorMessage(error));
    }
  }

  @SubscribeMessage('client.message.delete')
  async onDelete(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    const payload = this.parseDeletePayload(data);
    const actor = this.requireActor(client);
    try {
      const message = await this.chat.deleteMessage(payload.sessionId, payload.messageId, actor.claims);
      this.server.to(payload.sessionId).emit('server.message.deleted', { messageId: message.id, deletedAt: message.deleted_at });
      return { ok: true, message };
    } catch (error) {
      throw new WsException(this.toErrorMessage(error));
    }
  }

  @SubscribeMessage('client.message.redact')
  async onRedact(@MessageBody() data: unknown, @ConnectedSocket() client: Socket) {
    const payload = this.parseRedactPayload(data);
    const actor = this.requireActor(client);
    try {
      const message = await this.chat.redactMessage(payload.sessionId, payload.messageId, payload.reason, actor.claims);
      this.server.to(payload.sessionId).emit('server.message.redacted', {
        messageId: message.id,
        redactedAt: message.redacted_at,
        reason: message.redaction_reason,
      });
      return { ok: true, message };
    } catch (error) {
      throw new WsException(this.toErrorMessage(error));
    }
  }

  private async joinSession(client: Socket, payload: JoinPayload) {
    const actor = this.requireActor(client);
    try {
      const sync = await this.chat.syncSession(payload.sessionId, actor.claims, payload.afterStreamOrder);
      client.join(payload.sessionId);
      this.getSessions(client).add(payload.sessionId);
      client.emit('system.welcome', {
        sessionId: sync.sessionId,
        userId: actor.userId,
        kind: sync.kind,
        role: sync.role,
        status: sync.status,
        cursor: sync.cursor,
      });
      client.emit('server.session.synced', sync);
      this.server.to(payload.sessionId).emit('presence', {
        sessionId: payload.sessionId,
        userId: actor.userId,
        joined: true,
        role: sync.role,
      });
      return { ok: true, sessionId: payload.sessionId, cursor: sync.cursor };
    } catch (error) {
      throw new WsException(this.toErrorMessage(error));
    }
  }

  private async leaveSession(client: Socket, payload: SessionOnlyPayload) {
    const actor = this.requireActor(client);
    try {
      await this.chat.authorizeSessionAccess(payload.sessionId, actor.claims);
      client.leave(payload.sessionId);
      this.getSessions(client).delete(payload.sessionId);
      this.server.to(payload.sessionId).emit('presence', { sessionId: payload.sessionId, userId: actor.userId, left: true });
      const roomSize = this.server.sockets.adapter.rooms.get(payload.sessionId)?.size ?? 0;
      const release = roomSize === 0 ? await this.chat.releaseSessionIfUnused(payload.sessionId, actor.claims) : { released: false, reason: 'room_not_empty' };
      return { ok: true, sessionId: payload.sessionId, release };
    } catch (error) {
      throw new WsException(this.toErrorMessage(error));
    }
  }

  private async broadcastTyping(client: Socket, payload: TypingPayload) {
    const actor = this.requireActor(client);
    try {
      await this.chat.authorizeSessionAccess(payload.sessionId, actor.claims);
      this.server.to(payload.sessionId).emit('server.typing', {
        sessionId: payload.sessionId,
        actorId: actor.userId,
        isTyping: payload.isTyping,
      });
      this.server.to(payload.sessionId).emit('typing', {
        roomId: payload.sessionId,
        userId: actor.userId,
        typing: payload.isTyping,
      });
      return { ok: true };
    } catch (error) {
      throw new WsException(this.toErrorMessage(error));
    }
  }

  private async createMessage(client: Socket, payload: MessagePayload) {
    const actor = this.requireActor(client);
    try {
      const result = await this.chat.createMessage(payload.sessionId, actor.claims, payload.content, payload.clientKey);
      this.server.to(payload.sessionId).emit('server.message.appended', { message: result.message });
      this.server.to(payload.sessionId).emit('message:new', this.toLegacyMessage(result.message));
      this.emitDelivery(payload.sessionId, {
        message_id: result.message.id,
        user_id: actor.userId,
        delivered_at: result.message.created_at,
        read_at: result.message.created_at,
      });
      return { ok: true, duplicate: result.duplicate, committed: result.committed, message: result.message };
    } catch (error) {
      throw new WsException(this.toErrorMessage(error));
    }
  }

  private emitDelivery(sessionId: string, receipt: MessageReceipt) {
    this.server.to(sessionId).emit('server.message.delivery', {
      messageId: receipt.message_id,
      userId: receipt.user_id,
      deliveredAt: receipt.delivered_at,
      readAt: receipt.read_at,
    });
    this.server.to(sessionId).emit('message:delivery', {
      id: receipt.message_id,
      delivered: !!receipt.delivered_at,
      read: !!receipt.read_at,
      userId: receipt.user_id,
    });
  }

  private requireActor(client: Socket): ChatActor {
    const actor = this.getActor(client);
    if (!actor) {
      throw new WsException('unauthorized');
    }
    return actor;
  }

  private getActor(client: Socket): ChatActor | undefined {
    return this.getState(client).actor;
  }

  private getSessions(client: Socket): Set<string> {
    const state = this.getState(client);
    state.sessions = state.sessions || new Set<string>();
    return state.sessions;
  }

  private getState(client: Socket): SocketState {
    return client.data as SocketState;
  }

  private parseJoinPayload(value: unknown): JoinPayload {
    const parsed = joinSchema.safeParse(value);
    if (!parsed.success) {
      throw new WsException(parsed.error.issues[0]?.message || 'invalid_join_payload');
    }
    return {
      sessionId: parsed.data.sessionId || parsed.data.roomId || '',
      afterStreamOrder: parsed.data.afterStreamOrder,
    };
  }

  private parseSessionOnlyPayload(value: unknown): SessionOnlyPayload {
    const parsed = sessionOnlySchema.safeParse(value);
    if (!parsed.success) {
      throw new WsException(parsed.error.issues[0]?.message || 'invalid_session_payload');
    }
    return { sessionId: parsed.data.sessionId || parsed.data.roomId || '' };
  }

  private parseTypingPayload(value: unknown): TypingPayload {
    const parsed = typingSchema.safeParse(value);
    if (!parsed.success) {
      throw new WsException(parsed.error.issues[0]?.message || 'invalid_typing_payload');
    }
    return {
      sessionId: parsed.data.sessionId || parsed.data.roomId || '',
      isTyping: parsed.data.isTyping ?? parsed.data.typing ?? false,
    };
  }

  private parseMessagePayload(value: unknown): MessagePayload {
    const parsed = messageSchema.safeParse(value);
    if (!parsed.success) {
      throw new WsException(parsed.error.issues[0]?.message || 'invalid_message_payload');
    }
    return {
      sessionId: parsed.data.sessionId || parsed.data.roomId || '',
      content: parsed.data.content || parsed.data.text || '',
      clientKey: parsed.data.clientKey,
    };
  }

  private parseReceiptPayload(value: unknown): ReceiptPayload {
    const parsed = receiptSchema.safeParse(value);
    if (!parsed.success) {
      throw new WsException(parsed.error.issues[0]?.message || 'invalid_receipt_payload');
    }
    return parsed.data;
  }

  private parseEditPayload(value: unknown): EditPayload {
    const parsed = editSchema.safeParse(value);
    if (!parsed.success) {
      throw new WsException(parsed.error.issues[0]?.message || 'invalid_edit_payload');
    }
    return parsed.data;
  }

  private parseDeletePayload(value: unknown): DeletePayload {
    const parsed = deleteSchema.safeParse(value);
    if (!parsed.success) {
      throw new WsException(parsed.error.issues[0]?.message || 'invalid_delete_payload');
    }
    return parsed.data;
  }

  private parseRedactPayload(value: unknown): RedactPayload {
    const parsed = redactSchema.safeParse(value);
    if (!parsed.success) {
      throw new WsException(parsed.error.issues[0]?.message || 'invalid_redact_payload');
    }
    return parsed.data;
  }

  private parseOptionalNumber(value: string): number | undefined {
    if (!value) {
      return undefined;
    }
    const parsed = Number(value);
    return Number.isFinite(parsed) && parsed >= 0 ? parsed : undefined;
  }

  private normalizeUnknown(value: unknown): string {
    if (Array.isArray(value)) {
      return value[0]?.toString().trim() || '';
    }
    return typeof value === 'string' ? value.trim() : '';
  }

  private toLegacyMessage(message: StoredMessage) {
    return {
      id: message.id,
      roomId: message.session_id,
      from: message.sender_id,
      text: message.content,
      ts: Date.parse(message.created_at),
      streamOrder: message.stream_order,
    };
  }

  private toErrorMessage(error: unknown): string {
    if (error instanceof WsException) {
      const cause = error.getError();
      return typeof cause === 'string' ? cause : 'chat_error';
    }
    if (error instanceof Error && error.message) {
      return error.message;
    }
    this.logger.warn(`Unexpected chat error: ${String(error)}`);
    return 'chat_error';
  }
  }

type SocketState = {
  actor?: ChatActor;
  sessions?: Set<string>;
};

type JoinPayload = {
  sessionId: string;
  afterStreamOrder?: number;
};

type SessionOnlyPayload = {
  sessionId: string;
};

type TypingPayload = {
  sessionId: string;
  isTyping: boolean;
};

type MessagePayload = {
  sessionId: string;
  content: string;
  clientKey?: string;
};

type ReceiptPayload = {
  sessionId: string;
  messageId: string;
};

type EditPayload = {
  sessionId: string;
  messageId: string;
  content: string;
};

type DeletePayload = {
  sessionId: string;
  messageId: string;
};

type RedactPayload = {
  sessionId: string;
  messageId: string;
  reason?: string;
};

const joinSchema = z
  .object({
    sessionId: z.string().uuid().optional(),
    roomId: z.string().uuid().optional(),
    afterStreamOrder: z.coerce.number().int().nonnegative().optional(),
  })
  .refine((value) => Boolean(value.sessionId || value.roomId), { message: 'sessionId_required' });

const sessionOnlySchema = z
  .object({
    sessionId: z.string().uuid().optional(),
    roomId: z.string().uuid().optional(),
  })
  .refine((value) => Boolean(value.sessionId || value.roomId), { message: 'sessionId_required' });

const typingSchema = z
  .object({
    sessionId: z.string().uuid().optional(),
    roomId: z.string().uuid().optional(),
    isTyping: z.boolean().optional(),
    typing: z.boolean().optional(),
  })
  .refine((value) => Boolean(value.sessionId || value.roomId), { message: 'sessionId_required' })
  .refine((value) => value.isTyping !== undefined || value.typing !== undefined, { message: 'typing_required' });

const messageSchema = z
  .object({
    sessionId: z.string().uuid().optional(),
    roomId: z.string().uuid().optional(),
    content: z.string().trim().min(1).max(4000).optional(),
    text: z.string().trim().min(1).max(4000).optional(),
    clientKey: z.string().trim().min(1).max(128).optional(),
  })
  .refine((value) => Boolean(value.sessionId || value.roomId), { message: 'sessionId_required' })
  .refine((value) => Boolean(value.content || value.text), { message: 'content_required' });

const receiptSchema = z.object({
  sessionId: z.string().uuid(),
  messageId: z.string().uuid(),
});

const editSchema = z.object({
  sessionId: z.string().uuid(),
  messageId: z.string().uuid(),
  content: z.string().trim().min(1).max(4000),
});

const deleteSchema = z.object({
  sessionId: z.string().uuid(),
  messageId: z.string().uuid(),
});

const redactSchema = z.object({
  sessionId: z.string().uuid(),
  messageId: z.string().uuid(),
  reason: z.string().trim().max(500).optional(),
});
