import { Body, Controller, Post, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { NotificationsService } from './notifications.service';

@UseGuards(AuthGuard)
@Controller('notifications')
export class NotificationsController {
  constructor(private readonly notifications: NotificationsService) {}

  @Post('test')
  async sendTest(@Body() body: { channel: 'email'|'sms'|'whatsapp'; to: string; message: string }) {
    return { ok: true, echo: { channel: body?.channel, to: body?.to, message: body?.message } } as any;
  }

  @Post('send')
  async sendEmail(@Body() body: {
    to: string;
    subject?: string;
    text?: string;
    html?: string;
    replyTo?: string;
    templateId?: string;
    dynamicTemplateData?: Record<string, any>;
    categories?: string[];
    asmGroupId?: number;
    sandbox?: boolean;
  }) {
    const res = await this.notifications.sendEmail(body);
    return res;
  }
}
