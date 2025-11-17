import { Body, Controller, Get, HttpException, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { AuthGuard } from '../auth/auth.guard';

type CreateKbDto = {
  title: string;
  content: string;
  species?: string[];
  tags?: string[];
  language?: string;
};

@Controller()
export class KbController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

  // GET /kb - list articles (published for public; authors/admin see drafts)
  @UseGuards(AuthGuard)
  @Get('/kb')
  async listKb(
    @Query('q') q?: string,
    @Query('species') speciesCsv?: string,
    @Query('tags') tagsCsv?: string,
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string,
  ) {
    const limit = Math.min(Math.max(parseInt(limitStr || '20', 10) || 20, 1), 100);
    const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
    const species = (speciesCsv || '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    const tags = (tagsCsv || '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);

    const hasQ = !!q && q.trim().length > 0;
    const where: string[] = [];
    const args: any[] = [];

    // RLS handles visibility: published for public; author/admin can see drafts
    if (species.length) {
      args.push(species);
      where.push(`species && $${args.length}::text[]`);
    }
    if (tags.length) {
      args.push(tags);
      where.push(`tags && $${args.length}::text[]`);
    }
    if (hasQ) {
      args.push(q);
      where.push(`search_tsv @@ websearch_to_tsquery('simple', $${args.length})`);
    }

    args.push(limit, offset);
    const sql = `
      SELECT id, slug, title, language, status, published_at, tags, species, updated_at
      FROM kb_articles
      ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
      ORDER BY coalesce(published_at, updated_at) DESC
      LIMIT $${args.length - 1} OFFSET $${args.length}
    `;
    // Surface stub mode explicitly so callers know DB is not connected
    if (this.db.isStub) {
      return { items: [], mode: 'stub', reason: 'db_unavailable' } as any;
    }
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(sql, args);
      return r;
    });
    return { items: rows };
  }

  // GET /kb/:id - resolve by UUID or slug
  @UseGuards(AuthGuard)
  @Get('/kb/:id')
  async getKb(@Param('id') idOrSlug: string) {
    const isUuid = /^[0-9a-fA-F-]{36}$/.test(idOrSlug);
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
      `SELECT id, slug, title, content, language, status, tags, species, author_user_id, published_at, updated_at
       FROM kb_articles
       WHERE ${isUuid ? 'id = $1' : 'slug = $1'}
       LIMIT 1`,
      [idOrSlug]
    );
      return r;
    });
    if (!rows.length) throw new HttpException('Not Found', 404);
    return rows[0];
  }

  // POST /kb - create draft
  @UseGuards(AuthGuard)
  @Post('/kb')
  async createKb(@Body() body: CreateKbDto) {
    if (this.db.isStub) {
      // Explicit stub response to avoid silent undefined body
      return { ok: false, mode: 'stub', reason: 'db_unavailable' } as any;
    }
    const claims = this.rc.claims;
    const authorId = claims?.sub;
    if (!authorId) throw new HttpException('Unauthorized', 401);
    if (!body?.title || !body?.content) throw new HttpException('title and content are required', 400);

    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
      `INSERT INTO kb_articles (title, content, species, tags, language, author_user_id)
       VALUES ($1, $2, coalesce($3,'{}')::text[], coalesce($4,'{}')::text[], coalesce($5, 'es'), $6)
       RETURNING id, slug, status, title, language, created_at`,
      [body.title, body.content, body.species || [], body.tags || [], body.language || 'es', authorId]
    );
      return r;
    });
    return rows[0];
  }

  // PATCH /kb/:id/publish - admin only publish
  @UseGuards(AuthGuard)
  @Patch('/kb/:id/publish')
  async publish(@Param('id') id: string) {
    const claims = this.rc.claims || {};
    const isAdmin = !!(claims as any).admin || (claims as any).role === 'admin';
    if (!isAdmin) throw new HttpException('Forbidden', 403);
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
      `UPDATE kb_articles SET status = 'published', published_at = now()
       WHERE id = $1
       RETURNING id, status, published_at`,
      [id]
    );
      return r;
    });
    if (!rows.length) throw new HttpException('Not Found', 404);
    return rows[0];
  }
}
