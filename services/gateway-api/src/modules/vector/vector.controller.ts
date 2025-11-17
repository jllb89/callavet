import { Body, Controller, Get, HttpCode, HttpException, HttpStatus, Post, Query, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';

type VectorTarget = 'kb' | 'messages' | 'notes' | 'products' | 'services' | 'pets' | 'vets';

@Controller('vector')
export class VectorController {
  constructor(private readonly db: DbService) {}

  private targetDim: Record<VectorTarget, number> = {
    kb: 1536,
    messages: 1536,
    notes: 1536,
    products: 1536,
    services: 1536,
    pets: 1536,
    vets: 1536,
  };

  private normalizeEmbedding(arr: any, dim: number): number[] {
    const src = Array.isArray(arr) ? arr : [];
    const out = new Array<number>(dim);
    const n = Math.min(src.length, dim);
    for (let i = 0; i < n; i++) {
      const v = Number(src[i]);
      out[i] = Number.isFinite(v) ? v : 0;
    }
    for (let i = n; i < dim; i++) out[i] = 0;
    return out;
  }

  @UseGuards(AuthGuard)
  @Post('search')
  @HttpCode(HttpStatus.OK)
  async search(@Body() body: { target: VectorTarget; query_embedding: number[]; topK?: number; filter_ids?: string[] }) {
    try {
      // Ensure pool initialization completed before checking stub mode
      await this.db.ensureReady();
      const { target, query_embedding, filter_ids } = body || ({} as any);
      let topK = Math.min(Math.max(body?.topK || 8, 1), 50);
      if (!target || !Array.isArray(query_embedding) || query_embedding.length < 2) {
        throw new Error('invalid_request');
      }

      // Map target -> table, embedding column, snippet expression
      const map: Record<VectorTarget, { table: string; embCol: string; snippet: string }> = {
        kb: { table: 'kb_articles', embCol: 'embedding', snippet: `left(coalesce(title,'') || ' ' || coalesce(content,''), 240)` },
        messages: { table: 'messages', embCol: 'embedding', snippet: `left(coalesce(content,''), 240)` },
        notes: { table: 'consultation_notes', embCol: 'embedding', snippet: `left(coalesce(summary_text,'') || ' ' || coalesce(plan_summary,''), 240)` },
        products: { table: 'products', embCol: 'embedding', snippet: `left(coalesce(name,'') || ' ' || coalesce(description,''), 240)` },
        services: { table: 'services', embCol: 'embedding', snippet: `left(coalesce(name,'') || ' ' || coalesce(description,''), 240)` },
        pets: { table: 'pets', embCol: 'embedding', snippet: `left(coalesce(name,'') || ' ' || coalesce(medical_notes,''), 240)` },
        vets: { table: 'vets', embCol: 'embedding', snippet: `left(coalesce(bio,''), 240)` },
      };
      const cfg = map[target as VectorTarget];
      if (!cfg) throw new Error('unsupported_target');

  // Ensure embedding dimension matches table definition (pad/trim)
  const dim = this.targetDim[target as VectorTarget] ?? 1536;
  const norm = this.normalizeEmbedding(query_embedding, dim);
  // pgvector text literal for the embedding (e.g., '[0.1, 0.2, ...]')
  const vecLiteral = `[${norm.join(',')}]`;

      const params: any[] = [vecLiteral, topK];
      let where = `${cfg.embCol} IS NOT NULL`;
      if (Array.isArray(filter_ids) && filter_ids.length > 0) {
        params.push(filter_ids);
        where += ` AND id = ANY($${params.length}::uuid[])`;
      }

      const sql = `
        SELECT id,
               (1.0 - (${cfg.embCol} <=> $1::vector)) AS score,
               ${cfg.snippet} AS snippet
          FROM ${cfg.table}
         WHERE ${where}
         ORDER BY ${cfg.embCol} <=> $1::vector ASC
         LIMIT $2::int
      `;

      if (this.db.isStub) {
        return { results: [], mode: 'stub', reason: 'db_unavailable' } as any;
      }
      const rows = await this.db.runInTx(async (q) => {
        const { rows } = await q(sql, params);
        return rows as any[];
      });
      return { results: rows.map((r: any) => ({ id: r.id, score: Number(r.score), snippet: r.snippet, metadata: {} })) };
    } catch (e: any) {
      throw new HttpException(e?.message || 'search_failed', HttpStatus.BAD_REQUEST);
    }
  }

  // GET variant for vector search to support simple query testing from browsers/observability
  // Accepts query params:
  // - target: string (required)
  // - topK: number (optional)
  // - embedding|e|query_embedding|vec: JSON array string ("[0,0.1]") or comma-separated list
  // - filter_ids: JSON array string or comma-separated list; also supports repeated filter_id params
  @UseGuards(AuthGuard)
  @Get('search')
  @HttpCode(HttpStatus.OK)
  async searchGet(@Query() q: any) {
    await this.db.ensureReady();
    const target = (q?.target || '').toString();
    const topK = q?.topK != null ? Number(q.topK) : undefined;
    const parseEmbedding = (v: any): number[] => {
      if (Array.isArray(v)) return v.map((x) => Number(x)).filter((x) => Number.isFinite(x));
      const raw = (v ?? '').toString().trim();
      if (!raw) return [];
      try {
        const arr = JSON.parse(raw);
        if (Array.isArray(arr)) return arr.map((x) => Number(x)).filter((x) => Number.isFinite(x));
      } catch {}
      // comma-separated fallback
  return raw.split(',').map((x: string) => Number(x.trim())).filter((x: number) => Number.isFinite(x));
    };
    const emb = parseEmbedding(q?.embedding ?? q?.e ?? q?.query_embedding ?? q?.vec);

    const parseIds = (val: any): string[] => {
      if (Array.isArray(val)) return val.map((s) => s.toString());
      const s = (val ?? '').toString().trim();
      if (!s) return [];
      try {
        const arr = JSON.parse(s);
        if (Array.isArray(arr)) return arr.map((x) => x.toString());
      } catch {}
  return s.split(',').map((x: string) => x.trim()).filter((v: string) => !!v);
    };
    // Support filter_ids or repeated filter_id
    let filter_ids: string[] | undefined = undefined;
    if (q?.filter_id) filter_ids = parseIds(q.filter_id);
    if (q?.filter_ids) filter_ids = parseIds(q.filter_ids);

    if (!target || emb.length < 2) {
      throw new HttpException('invalid_request', HttpStatus.BAD_REQUEST);
    }

    return this.search({ target: target as VectorTarget, query_embedding: emb, topK, filter_ids });
  }

  @UseGuards(AuthGuard)
  @Post('upsert')
  async upsert(@Body() body: { target: VectorTarget; items: Array<{ id: string; embedding: number[]; payload?: Record<string, any> }> }) {
    try {
      await this.db.ensureReady();
      const { target, items } = body || ({} as any);
      if (!target || !Array.isArray(items) || items.length === 0) throw new Error('invalid_request');

      const map: Record<VectorTarget, { table: string; embCol: string }> = {
        kb: { table: 'kb_articles', embCol: 'embedding' },
        messages: { table: 'messages', embCol: 'embedding' },
        notes: { table: 'consultation_notes', embCol: 'embedding' },
        products: { table: 'products', embCol: 'embedding' },
        services: { table: 'services', embCol: 'embedding' },
        pets: { table: 'pets', embCol: 'embedding' },
        vets: { table: 'vets', embCol: 'embedding' },
      };
      const cfg = map[target as VectorTarget];
      if (!cfg) throw new Error('unsupported_target');

  if (this.db.isStub) return { ok: true, updated: items.length, mode: 'stub', reason: 'db_unavailable' };

      const result = await this.db.runInTx(async (q) => {
        const updatedIds: string[] = [];
        const skipped: string[] = [];
        for (const it of items) {
          if (!it?.id || !Array.isArray(it?.embedding) || it.embedding.length < 1) {
            if (it?.id) skipped.push(it.id);
            continue;
          }
          const dim = this.targetDim[target as VectorTarget] ?? 1536;
          const norm = this.normalizeEmbedding(it.embedding, dim);
          const vecLiteral = `[${norm.join(',')}]`;
          const { rows } = await q<{ id: string }>(
            `UPDATE ${cfg.table} SET ${cfg.embCol} = $2::vector WHERE id = $1::uuid RETURNING id`,
            [it.id, vecLiteral]
          );
          if (rows.length > 0) updatedIds.push(rows[0].id);
          else skipped.push(it.id);
        }
        return { count: updatedIds.length, updatedIds, skipped };
      });

      return { ok: true, updated: result.count, updatedIds: result.updatedIds, skipped: result.skipped };
    } catch (e: any) {
      throw new HttpException(e?.message || 'upsert_failed', HttpStatus.BAD_REQUEST);
    }
  }

  // Simple debug utility to verify RLS visibility and embeddings presence
  @UseGuards(AuthGuard)
  @Get('debug')
  @HttpCode(HttpStatus.OK)
  async debug() {
    await this.db.ensureReady();
    if (this.db.isStub) return { pets: 0, pets_with_emb: 0, sample: [] };
    const out = await this.db.runInTx(async (q) => {
      const all = await q<{ c: number }>('select count(*)::int as c from pets');
      const withEmb = await q<{ c: number }>('select count(*)::int as c from pets where embedding is not null');
      const sample = await q<{ id: string; has_embedding: boolean }>(
        `select id::text as id, (embedding is not null) as has_embedding
           from pets
          order by created_at desc
          limit 10`
      );
      return { pets: all.rows[0].c, pets_with_emb: withEmb.rows[0].c, sample: sample.rows };
    });
    return out;
  }

  // Helper: list accessible pets (IDs and names) with embedding flag
  @UseGuards(AuthGuard)
  @Get('pets')
  @HttpCode(HttpStatus.OK)
  async listPets(@Query('limit') limitQ?: string) {
    if (this.db.isStub) return { items: [] };
    const limit = Math.min(Math.max(parseInt(limitQ || '50', 10) || 50, 1), 200);
    const rows = await this.db.runInTx(async (q) => {
      const res = await q<{ id: string; name: string; has_embedding: boolean }>(
        `select id::text as id, coalesce(name,'') as name, (embedding is not null) as has_embedding
           from pets
          order by created_at desc
          limit $1::int`,
        [limit]
      );
      return res.rows;
    });
    return { items: rows };
  }
}
