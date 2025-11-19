import { Body, Controller, Post, UseGuards, HttpException, HttpStatus } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';

interface ReserveBody { type: 'chat' | 'video'; sessionId: string }
interface ConsumptionBody { consumptionId: string }

@Controller('entitlements')
@UseGuards(AuthGuard)
export class EntitlementsController {
  constructor(private readonly db: DbService) {}

  @Post('reserve')
  async reserve(@Body() body: ReserveBody) {
    const { type, sessionId } = body || ({} as any);
    if (!type || !sessionId) throw new HttpException({ ok: false, reason: 'validation_error', details: 'type and sessionId required' }, HttpStatus.BAD_REQUEST);
    if (this.db.isStub) {
      return { ok: true, type, reserved: true, sessionId, mode: 'stub' } as any;
    }
    try {
      const result = await this.db.runInTx(async (q) => {
        const fn = type === 'chat' ? 'fn_reserve_chat' : type === 'video' ? 'fn_reserve_video' : null;
        if (!fn) throw new Error('unsupported_type');
        const { rows } = await q(`select * from ${fn}(auth.uid(), trim($1)::uuid)`, [sessionId]);
        return rows[0] || null;
      });
      if (!result) {
        return { ok: false, type, reserved: false, reason: 'no_row_returned' };
      }
      const msg = (result as any).msg;
      if (msg && msg !== 'ok') {
        // Map function message directly into structured reason (e.g. no_active_subscription, no_chat_entitlement_left)
        return { ok: false, type, reserved: false, reason: msg };
      }
      const consumptionId = (result as any).consumption_id || (result as any).consumptionId || null;
      return { ok: true, type, reserved: true, consumptionId };
    } catch (e: any) {
      const raw = e?.message || '';
      let reason = 'reserve_failed';
      if (/entitlement_consumptions_session_id_fkey/i.test(raw) || /foreign key.*session_id/i.test(raw)) reason = 'invalid_session';
      if (/no_active_subscription/i.test(raw)) reason = 'no_active_subscription';
      if (/no_chat_entitlement_left/i.test(raw)) reason = 'no_chat_entitlement_left';
      if (/no_video_entitlement_left/i.test(raw)) reason = 'no_video_entitlement_left';
      throw new HttpException({ ok: false, reason, error: raw }, HttpStatus.BAD_REQUEST);
    }
  }

  @Post('commit')
  async commit(@Body() body: ConsumptionBody) {
    if (!body?.consumptionId) throw new HttpException({ ok: false, reason: 'validation_error', details: 'consumptionId required' }, HttpStatus.BAD_REQUEST);
    if (this.db.isStub) return { ok: true, committed: true, consumptionId: body.consumptionId, mode: 'stub' } as any;
    try {
      const ok = await this.db.runInTx(async (q) => {
        const { rows } = await q(`select fn_commit_consumption(trim($1)::uuid) as ok`, [body.consumptionId]);
        return !!rows[0]?.ok;
      });
      if (!ok) return { ok: false, committed: false, consumptionId: body.consumptionId, reason: 'not_found_or_finalized' };
      return { ok: true, committed: true, consumptionId: body.consumptionId };
    } catch (e: any) {
      const raw = e?.message || '';
      let reason = 'commit_failed';
      if (/foreign key/i.test(raw)) reason = 'invalid_consumption';
      throw new HttpException({ ok: false, reason, error: raw }, HttpStatus.BAD_REQUEST);
    }
  }

  @Post('release')
  async release(@Body() body: ConsumptionBody) {
    if (!body?.consumptionId) throw new HttpException({ ok: false, reason: 'validation_error', details: 'consumptionId required' }, HttpStatus.BAD_REQUEST);
    if (this.db.isStub) return { ok: true, released: true, consumptionId: body.consumptionId, mode: 'stub' } as any;
    try {
      const ok = await this.db.runInTx(async (q) => {
        const { rows } = await q(`select fn_release_consumption(trim($1)::uuid) as ok`, [body.consumptionId]);
        return !!rows[0]?.ok;
      });
      if (!ok) return { ok: false, released: false, consumptionId: body.consumptionId, reason: 'not_found_or_finalized' };
      return { ok: true, released: true, consumptionId: body.consumptionId };
    } catch (e: any) {
      const raw = e?.message || '';
      let reason = 'release_failed';
      if (/foreign key/i.test(raw)) reason = 'invalid_consumption';
      throw new HttpException({ ok: false, reason, error: raw }, HttpStatus.BAD_REQUEST);
    }
  }
}
