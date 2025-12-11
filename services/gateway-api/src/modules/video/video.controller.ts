import { Body, Controller, Post, Param, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';

@UseGuards(AuthGuard)
@Controller('video')
export class VideoController {
  @Post('rooms')
  async createRoom(@Body() body: { sessionId?: string }) {
    const roomId = `room_${Math.random().toString(36).slice(2, 10)}`;
    const token = `tok_${Math.random().toString(36).slice(2, 24)}`;
    return { roomId, token };
  }

  @Post('rooms/:roomId/end')
  async endRoom(@Param('roomId') roomId: string) {
    return { ok: true, roomId };
  }
}
