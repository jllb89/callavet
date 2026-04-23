import { BadRequestException, Body, Controller, Param, Post, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { EndpointRateLimitGuard } from '../rate-limit/endpoint-rate-limit.guard';
import { RateLimit } from '../rate-limit/rate-limit.decorator';
import { ValidatorService } from '../config/validator.service';

@UseGuards(AuthGuard)
@Controller('video')
export class VideoController {
  constructor(private readonly validator: ValidatorService) {}

  @Post('rooms')
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'video.rooms.create', limit: 10, windowMs: 60_000 })
  async createRoom(@Body() body: { sessionId?: string }) {
    const sessionId = (body?.sessionId || '').toString().trim();
    if (!sessionId) throw new BadRequestException('sessionId is required');
    this.validator.validateUUID(sessionId, 'sessionId');
    const roomId = `room_${Math.random().toString(36).slice(2, 10)}`;
    const token = `tok_${Math.random().toString(36).slice(2, 24)}`;
    return { roomId, token, sessionId };
  }

  @Post('rooms/:roomId/end')
  async endRoom(@Param('roomId') roomId: string) {
    return { ok: true, roomId };
  }
}
