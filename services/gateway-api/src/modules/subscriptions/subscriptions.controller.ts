import { Body, Controller, Get, HttpException, HttpStatus, Post, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';

@Controller('subscriptions')
@UseGuards(AuthGuard)
export class SubscriptionsController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

  @Post('reserve-chat')
  async reserveChat(@Body() body: { userId: string; sessionId: string }) {
    try {
      if (this.db.isStub) {
        return { ok: true, mode: 'stub', reserved: true, type: 'chat', ...body };
      }
      const result = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `select * from fn_reserve_chat(auth.uid(), trim($1)::uuid)`,
          [body.sessionId]
        );
        return rows[0];
      });
      return { ok: true, result };
    } catch (e: any) {
      throw new HttpException(e?.message || 'reserve_chat_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('reserve-video')
  async reserveVideo(@Body() body: { userId: string; sessionId: string }) {
    try {
      if (this.db.isStub) {
        return { ok: true, mode: 'stub', reserved: true, type: 'video', ...body };
      }
      const result = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `select * from fn_reserve_video(auth.uid(), trim($1)::uuid)`,
          [body.sessionId]
        );
        return rows[0];
      });
      return { ok: true, result };
    } catch (e: any) {
      throw new HttpException(e?.message || 'reserve_video_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('commit')
  async commit(@Body() body: { consumptionId: string }) {
    try {
      if (this.db.isStub) return { ok: true, mode: 'stub', committed: true, ...body };
      const ok = await this.db.runInTx(async (q) => {
        const { rows } = await q(`select fn_commit_consumption(trim($1)::uuid) as ok`, [body.consumptionId]);
        return !!rows[0]?.ok;
      });
      return { ok };
    } catch (e: any) {
      throw new HttpException(e?.message || 'commit_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('release')
  async release(@Body() body: { consumptionId: string }) {
    try {
      if (this.db.isStub) return { ok: true, mode: 'stub', released: true, ...body };
      const ok = await this.db.runInTx(async (q) => {
        const { rows } = await q(`select fn_release_consumption(trim($1)::uuid) as ok`, [body.consumptionId]);
        return !!rows[0]?.ok;
      });
      return { ok };
    } catch (e: any) {
      throw new HttpException(e?.message || 'release_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get('usage')
  async getUsage() {
    try {
      if (this.db.isStub) {
        return { ok: true, mode: 'stub', usage: { included_chats: 2, consumed_chats: 0, included_videos: 1, consumed_videos: 0, overage_chats: 0, overage_videos: 0 } };
      }
      const usage = await this.db.runInTx(async (q) => {
        const { rows: subs } = await q<{ id: string }>(
          `select id from v_active_user_subscriptions where user_id = auth.uid() order by current_period_end desc limit 1`
        );
        if (!subs[0]) {
          return null;
        }
        const subId = subs[0].id;
        const { rows } = await q<any>(`select * from fn_current_usage(trim($1)::uuid)`, [subId]);
        return rows[0] || null;
      });
      return { ok: true, usage, msg: usage ? 'ok' : 'no_active_subscription' };
    } catch (e: any) {
      throw new HttpException(e?.message || 'usage_failed', HttpStatus.BAD_REQUEST);
    }
  }

  // Dev-only: introspect auth.uid() and subscription visibility
  // Note: debug endpoint removed (dev-only)
}
