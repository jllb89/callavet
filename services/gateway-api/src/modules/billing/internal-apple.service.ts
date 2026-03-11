import { Injectable } from '@nestjs/common';
import { DbService } from '../db/db.service';

interface IncomingAppleEvent {
  event_id?: string;
  event_type?: string;
  environment?: string;
  signed_payload?: string;
  payload?: any;
  original_transaction_id?: string;
  transaction_id?: string;
  product_id?: string;
  app_account_token?: string;
}

@Injectable()
export class InternalAppleService {
  constructor(private readonly db: DbService) {}

  async processEvent(evt: IncomingAppleEvent) {
    const eventId =
      (evt.event_id || '').trim() ||
      `apple:${(evt.original_transaction_id || evt.transaction_id || '').trim()}:${(evt.event_type || 'unknown').trim()}`;

    if (!eventId || eventId === 'apple::unknown') {
      return { ok: false, reason: 'invalid_payload' };
    }

    const eventType = (evt.event_type || 'unknown').trim();
    const environment = (evt.environment || 'sandbox').trim().toLowerCase();
    const originalTransactionId = (evt.original_transaction_id || '').trim() || null;
    const transactionId = (evt.transaction_id || '').trim() || null;
    const productId = (evt.product_id || '').trim() || null;
    const appAccountToken = (evt.app_account_token || '').trim() || null;
    const signedPayload = (evt.signed_payload || '').trim() || null;

    const payload = evt.payload && typeof evt.payload === 'object' ? evt.payload : null;

    const inserted = await this.db.query<{ id: string }>(
      `insert into apple_subscription_events (
         id,
         event_id,
         event_type,
         environment,
         original_transaction_id,
         transaction_id,
         app_account_token,
         product_id,
         signed_payload,
         payload,
         processed_at,
         created_at
       ) values (
         gen_random_uuid(),
         $1,
         $2,
         $3,
         $4,
         $5,
         nullif($6,'')::uuid,
         $7,
         $8,
         $9::jsonb,
         now(),
         now()
       )
       on conflict (event_id) do nothing
       returning id`,
      [
        eventId,
        eventType,
        environment,
        originalTransactionId,
        transactionId,
        appAccountToken,
        productId,
        signedPayload,
        payload ? JSON.stringify(payload) : null,
      ]
    );

    return {
      ok: true,
      inserted: inserted.rows.length,
      duplicate: inserted.rows.length === 0,
      event_id: eventId,
      event_type: eventType,
    };
  }
}
