import { Body, Controller, Get, Param, Post, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';

@Controller('sessions')
@UseGuards(AuthGuard)
export class SessionMessagesController {
  @Get(':sessionId/messages')
  list(@Param('sessionId') sessionId: string) {
    return {
      ok: true,
      sessionId,
      items: [],
    } as any;
  }

  @Post(':sessionId/messages')
  create(@Param('sessionId') sessionId: string, @Body() body: { role?: string; content?: string }) {
    return {
      ok: true,
      sessionId,
      message: {
        id: `msg_${Date.now()}`,
        role: body?.role || 'user',
        content: body?.content || '',
        created_at: new Date().toISOString(),
      }
    } as any;
  }

  @Get(':sessionId/transcript')
  transcript(@Param('sessionId') sessionId: string) {
    return {
      ok: true,
      sessionId,
      transcript: [],
    } as any;
  }
}