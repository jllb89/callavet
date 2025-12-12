import { Injectable } from '@nestjs/common';
import sgMail, { MailDataRequired } from '@sendgrid/mail';

type SendEmailInput = {
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
};

@Injectable()
export class NotificationsService {
  private initialized = false;

  private ensureInit() {
    if (this.initialized) return;
    const apiKey = process.env.SENDGRID_API_KEY;
    if (!apiKey) {
      throw new Error('SENDGRID_API_KEY is not set');
    }
    sgMail.setApiKey(apiKey);
    this.initialized = true;
  }

  async sendEmail(input: SendEmailInput) {
    this.ensureInit();

    const from = process.env.SENDGRID_FROM;
    const defaultReply = process.env.SENDGRID_REPLY_TO;
    if (!from) throw new Error('SENDGRID_FROM is not set');

    if (!input.templateId) {
      if (!input.subject) throw new Error('subject is required when not using a template');
      if (!input.text && !input.html) throw new Error('text or html is required when not using a template');
    }

    const mail: MailDataRequired = {
      to: input.to,
      from,
      replyTo: input.replyTo || defaultReply,
      subject: input.subject,
      text: input.text,
      html: input.html,
      templateId: input.templateId,
      dynamicTemplateData: input.dynamicTemplateData,
      categories: input.categories,
      asm: input.asmGroupId ? { groupId: input.asmGroupId } as any : undefined,
      mailSettings: input.sandbox ? { sandboxMode: { enable: true } } : undefined,
    } as MailDataRequired;

    const [res] = await sgMail.send(mail, false);
    const messageId = res?.headers?.['x-message-id'] || res?.headers?.['X-Message-Id'] || undefined;
    return {
      ok: true,
      id: messageId,
      statusCode: res?.statusCode,
      sandbox: !!input.sandbox,
    };
  }
}
