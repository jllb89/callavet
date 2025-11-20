import { Controller, Get, Param, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';

@Controller('messages')
@UseGuards(AuthGuard)
export class MessagesController {
  @Get()
  list() {
    return {
      ok: false,
      domain: 'messages',
      reason: 'not_ready',
      message: 'Messages API not ready; to be finished in frontend integration.',
      data: []
    };
  }

  @Get('transcripts')
  transcripts() {
    return {
      ok: false,
      domain: 'messages',
      reason: 'not_ready',
      message: 'Transcripts API not ready; to be finished in frontend integration.',
      data: []
    };
  }

  @Get(':id')
  detail(@Param('id') id: string) {
    return {
      ok: false,
      domain: 'messages',
      reason: 'not_ready',
      message: 'Message detail API not ready; to be finished in frontend integration.',
      id
    };
  }
}
