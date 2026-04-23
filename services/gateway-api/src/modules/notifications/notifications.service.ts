import { Injectable } from '@nestjs/common';
import sgMail, { MailDataRequired } from '@sendgrid/mail';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';

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
  constructor(
    private readonly db: DbService,
    private readonly rc: RequestContext,
  ) {}

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

  private renderDefaultTemplate(eventType: string, variables?: Record<string, any>) {
    const v = variables || {};
    switch ((eventType || '').trim()) {
      case 'appointment.reminder':
        return {
          subject: `Appointment reminder: ${v.petName || 'your pet'}`,
          text: `Your appointment is scheduled for ${v.startsAt || 'soon'}.`,
        };
      case 'consult.start':
        return {
          subject: 'Your consult has started',
          text: `Consult session ${v.sessionId || ''} is now active.`,
        };
      case 'consult.end':
        return {
          subject: 'Your consult has ended',
          text: `Consult session ${v.sessionId || ''} has been closed.`,
        };
      case 'payment.failed':
        return {
          subject: 'Payment failed',
          text: 'We could not process your latest payment method. Please update billing details.',
        };
      case 'note.ready':
        return {
          subject: 'Consultation notes are ready',
          text: `Your clinician has published notes for ${v.petName || 'your pet'}.`,
        };
      default:
        return {
          subject: 'Call A Vet notification',
          text: 'You have a new account notification.',
        };
    }
  }

  async sendEvent(input: {
    eventType: string;
    userId?: string;
    channel?: 'email' | 'sms' | 'whatsapp' | 'push' | 'system';
    to?: string;
    templateId?: string;
    variables?: Record<string, any>;
    subject?: string;
    message?: string;
    sandbox?: boolean;
  }) {
    const eventType = (input?.eventType || '').trim();
    if (!eventType) throw new Error('eventType is required');

    const actorUserId = this.rc.userId || null;
    const userId = (input?.userId || actorUserId || '').trim() || null;
    const channel = (input?.channel || 'email') as 'email' | 'sms' | 'whatsapp' | 'push' | 'system';

    const defaults = this.renderDefaultTemplate(eventType, input?.variables);
    const subject = (input?.subject || defaults.subject || '').trim() || null;
    const message = (input?.message || defaults.text || '').trim() || null;
    const to = (input?.to || '').trim() || null;

    const { rows: insertedRows } = await this.db.query<{ id: string }>(
      `insert into notification_events (
         id,
         user_id,
         event_type,
         channel,
         destination,
         subject,
         body_text,
         template_id,
         payload,
         status,
         created_at,
         updated_at
       ) values (
         gen_random_uuid(),
         $1::uuid,
         $2,
         $3,
         $4,
         $5,
         $6,
         $7,
         coalesce($8::jsonb, '{}'::jsonb),
         'queued',
         now(),
         now()
       )
       returning id`,
      [
        userId,
        eventType,
        channel,
        to,
        subject,
        message,
        input?.templateId || null,
        JSON.stringify(input?.variables || {}),
      ]
    );

    const eventId = insertedRows[0]?.id;
    if (!eventId) throw new Error('notification_event_insert_failed');

    // For now, only email channel is actively delivered; others are queued for provider integration.
    if (channel !== 'email') {
      await this.db.query(
        `update notification_events
            set status = 'queued',
                updated_at = now()
          where id = $1::uuid`,
        [eventId]
      );
      return { ok: true, id: eventId, status: 'queued', channel };
    }

    if (!to) {
      await this.db.query(
        `update notification_events
            set status = 'failed',
                error_text = 'missing_destination',
                updated_at = now()
          where id = $1::uuid`,
        [eventId]
      );
      return { ok: false, id: eventId, status: 'failed', reason: 'missing_destination' };
    }

    try {
      const emailResult = await this.sendEmail({
        to,
        subject: subject || undefined,
        text: message || undefined,
        templateId: input?.templateId || undefined,
        dynamicTemplateData: input?.variables,
        sandbox: input?.sandbox,
      });

      await this.db.query(
        `update notification_events
            set status = 'sent',
                provider = 'sendgrid',
                provider_message_id = $2,
                sent_at = now(),
                updated_at = now()
          where id = $1::uuid`,
        [eventId, emailResult?.id || null]
      );

      return { ok: true, id: eventId, status: 'sent', provider: 'sendgrid', providerId: emailResult?.id || null };
    } catch (e: any) {
      await this.db.query(
        `update notification_events
            set status = 'failed',
                provider = 'sendgrid',
                error_text = $2,
                updated_at = now()
          where id = $1::uuid`,
        [eventId, (e?.message || 'send_failed').slice(0, 1000)]
      );
      return { ok: false, id: eventId, status: 'failed', reason: e?.message || 'send_failed' };
    }
  }
}
