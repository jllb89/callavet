import { Controller, Get, HttpException, Query, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';

@Controller()
export class SearchController {
  constructor(private readonly db: DbService) {}

  // GET /search?type=kb&q=... -- Phase 1 limited to KB lexical search
  @UseGuards(AuthGuard)
  @Get('/search')
  async search(
    @Query('type') type: string = 'kb',
    @Query('q') q?: string,
    @Query('limit') limitStr?: string,
  ) {
    if (type !== 'kb') {
      throw new HttpException('type not supported (kb only for now)', 400);
    }
    if (!q || !q.trim()) {
      return { items: [], took_ms: 0 };
    }
    const limit = Math.min(Math.max(parseInt(limitStr || '10', 10) || 10, 1), 50);
    const start = Date.now();
    // Combine Spanish + English websearch queries for bilingual matching
    const { rows } = await this.db.runInTx(async (q) => {
      // First attempt: vector search_tsv match
      const vectorRes = await q(
        `WITH term AS (
           SELECT (plainto_tsquery('english', $1) || plainto_tsquery('spanish', $1)) AS ts
         )
         SELECT id, slug, title,
                ts_headline('english', content, (SELECT ts FROM term), 'MaxFragments=1, MaxWords=20, MinWords=10') AS snippet,
                status,
                published_at,
                ts_rank_cd(search_tsv, (SELECT ts FROM term)) AS score
         FROM kb_articles, term
         WHERE search_tsv @@ (SELECT ts FROM term)
         ORDER BY score DESC
         LIMIT $2`,
        [q, limit]
      );
      if (vectorRes.rows.length) return vectorRes;
      // Second attempt: direct term presence using plainto_tsquery fallback
      const directRes = await q(
        `WITH term AS (
           SELECT plainto_tsquery('simple', $1) AS ts
         )
         SELECT id, slug, title, null AS snippet, status, published_at, 0 AS score
         FROM kb_articles, term
         WHERE search_tsv @@ (SELECT ts FROM term)
         ORDER BY published_at DESC NULLS LAST
         LIMIT $2`,
        [q, limit]
      );
      if (directRes.rows.length) return directRes;
      // Final fallback: ILIKE pattern
      return await q(
        `SELECT id, slug, title, null AS snippet, status, published_at, 0 AS score
         FROM kb_articles
         WHERE (title ILIKE '%'||$1||'%' OR content ILIKE '%'||$1||'%')
         ORDER BY published_at DESC NULLS LAST
         LIMIT $2`,
        [q, limit]
      );
    });
    const took_ms = Date.now() - start;
    return { items: rows.map(r => ({ kind: 'kb', ...r })), took_ms, lexical: true };
  }
}
