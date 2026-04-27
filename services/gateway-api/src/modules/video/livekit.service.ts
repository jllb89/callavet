import { Injectable, ServiceUnavailableException } from '@nestjs/common';
import { AccessToken, RoomServiceClient } from 'livekit-server-sdk';

export type LiveKitParticipantRole = 'owner' | 'vet' | 'admin' | 'participant';

type JoinTokenInput = {
  roomName: string;
  identity: string;
  name: string;
  role: LiveKitParticipantRole;
  metadata: Record<string, string>;
  ttlSeconds?: number;
};

@Injectable()
export class LiveKitService {
  private roomClient?: RoomServiceClient;

  get publicUrl(): string {
    return (process.env.LIVEKIT_URL || '').trim().replace(/\/+$/, '');
  }

  private get apiKey(): string {
    return (process.env.LIVEKIT_API_KEY || '').trim();
  }

  private get apiSecret(): string {
    return (process.env.LIVEKIT_API_SECRET || '').trim();
  }

  get isConfigured(): boolean {
    return !!this.publicUrl && !!this.apiKey && !!this.apiSecret;
  }

  assertConfigured() {
    if (!this.isConfigured) {
      throw new ServiceUnavailableException('livekit_not_configured');
    }
  }

  roomNameForSession(sessionId: string): string {
    return `cav-${sessionId}`;
  }

  sessionIdFromRoomName(roomName: string): string {
    return String(roomName || '').replace(/^cav-/, '');
  }

  private rooms(): RoomServiceClient {
    this.assertConfigured();
    if (!this.roomClient) {
      this.roomClient = new RoomServiceClient(this.publicUrl, this.apiKey, this.apiSecret);
    }
    return this.roomClient;
  }

  async ensureRoom(roomName: string, metadata: Record<string, string>) {
    const rooms = this.rooms();
    const existing = await rooms.listRooms([roomName]);
    if (existing.length > 0) return existing[0];

    return rooms.createRoom({
      name: roomName,
      emptyTimeout: 300,
      departureTimeout: 120,
      maxParticipants: 4,
      metadata: JSON.stringify(metadata),
    });
  }

  async createJoinToken(input: JoinTokenInput): Promise<string> {
    this.assertConfigured();
    const token = new AccessToken(this.apiKey, this.apiSecret, {
      identity: input.identity,
      name: input.name,
      ttl: input.ttlSeconds || 60 * 60,
      metadata: JSON.stringify(input.metadata),
      attributes: {
        sessionId: input.metadata.sessionId,
        role: input.role,
      },
    });

    token.addGrant({
      room: input.roomName,
      roomJoin: true,
      roomAdmin: input.role === 'vet' || input.role === 'admin',
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
      canUpdateOwnMetadata: true,
    });

    return token.toJwt();
  }

  async endRoom(roomName: string): Promise<{ ended: boolean }> {
    try {
      await this.rooms().deleteRoom(roomName);
      return { ended: true };
    } catch (error: any) {
      const message = String(error?.message || error || '').toLowerCase();
      if (message.includes('not found') || message.includes('not_found')) {
        return { ended: false };
      }
      throw error;
    }
  }
}
