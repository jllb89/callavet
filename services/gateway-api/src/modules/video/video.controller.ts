import { BadRequestException, Body, Controller, Param, Post, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { EndpointRateLimitGuard } from '../rate-limit/endpoint-rate-limit.guard';
import { RateLimit } from '../rate-limit/rate-limit.decorator';

@UseGuards(AuthGuard)
@Controller('video')
export class VideoController {
  @Post('rooms')
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'video.rooms.create', limit: 10, windowMs: 60_000 })
  async createRoom(@Body() body: { sessionId?: string }) {
    const sessionId = (body?.sessionId || '').toString().trim();
    if (!sessionId) throw new BadRequestException('sessionId is required');
    if (!/^[0-9a-fA-F-]{36}$/.test(sessionId)) {
      throw new BadRequestException('sessionId must be a UUID');
    }
    const roomId = `room_${Math.random().toString(36).slice(2, 10)}`;
    const token = `tok_${Math.random().toString(36).slice(2, 24)}`;
    return { roomId, token, sessionId };
  }

  @Post('rooms/:roomId/end')
  async endRoom(@Param('roomId') roomId: string) {
    return { ok: true, roomId };
  }
}
