import { Body, Controller, Post, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';

@UseGuards(AuthGuard)
@Controller('notifications')
export class NotificationsController {
  @Post('test')
  async sendTest(@Body() body: { channel: 'email'|'sms'|'whatsapp'; to: string; message: string }) {
    return { ok: true, echo: { channel: body?.channel, to: body?.to, message: body?.message } } as any;
  }
}
