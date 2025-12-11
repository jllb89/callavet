import { Controller, Get, Post, Query, UseGuards, Body, BadRequestException } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { DbService } from '../db/db.service';

@UseGuards(AuthGuard)
@Controller('files')
export class FilesController {
  constructor(private readonly db: DbService) {}
  private supabase?: SupabaseClient;
  private getClient(): SupabaseClient {
    if (this.supabase) return this.supabase;
    const url = process.env.SUPABASE_URL;
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) {
      throw new BadRequestException('Supabase env missing: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY');
    }
    this.supabase = createClient(url, key);
    return this.supabase;
  }

  private bucket() {
    const name = process.env.SUPABASE_STORAGE_BUCKET;
    if (!name) throw new BadRequestException('SUPABASE_STORAGE_BUCKET not set');
    return name;
  }

  // Server-side upload: accepts JSON with base64 content
  // Body: { path: string, content: string, contentType?: string, petId?: string, sessionId?: string, labels?: string[], findings?: string, diagnosis_label?: string }
  @Post('upload')
  async upload(@Body() body: { path?: string; content?: string; contentType?: string; petId?: string; sessionId?: string; labels?: string[]; findings?: string; diagnosis_label?: string }) {
    if (!body?.path || !body?.content) {
      throw new BadRequestException('path and content are required');
    }
    const bucket = this.bucket();
    const contentType = body.contentType || 'application/octet-stream';
    // Basic validation for images: require proper mime and file extension alignment
    const allowed = new Map<string, string[]>([
      ['image/jpeg', ['.jpg', '.jpeg']],
      ['image/png', ['.png']],
      ['image/webp', ['.webp']],
      ['image/gif', ['.gif']],
      ['image/bmp', ['.bmp']],
      ['image/tiff', ['.tif', '.tiff']],
      ['image/svg+xml', ['.svg']],
    ]);
    const lowerPath = body.path.toLowerCase();
    if (allowed.has(contentType)) {
      const exts = allowed.get(contentType)!;
      if (!exts.some(ext => lowerPath.endsWith(ext))) {
        throw new BadRequestException(`path extension must match contentType (${contentType})`);
      }
    }

    // Expect base64 string
    let b64 = body.content;
    // Support data URLs: data:<mime>;base64,<data>
    const comma = b64.indexOf(',');
    if (b64.startsWith('data:') && comma !== -1) {
      b64 = b64.slice(comma + 1);
    }
    let buffer: Buffer;
    try {
      buffer = Buffer.from(b64, 'base64');
    } catch {
      throw new BadRequestException('content must be base64');
    }

    const supa = this.getClient();
    const { error } = await supa.storage.from(bucket).upload(body.path, buffer, {
      contentType,
      upsert: true,
    });
    if (error) {
      throw new BadRequestException(`upload failed: ${error.message}`);
    }
    // Optional: auto-create image_cases entry if petId provided
    if (body.petId) {
      const idSql = `select gen_random_uuid() as id`;
      const idRes = await (this.db as any).query(idSql);
      const id = idRes.rows[0].id;
      await (this.db as any).query(
        `insert into image_cases (id, pet_id, session_id, image_url, labels, findings, diagnosis_label, created_at)
         values ($1, $2, $3, $4, $5, $6, $7, now())`,
        [
          id,
          body.petId,
          body.sessionId || null,
          body.path,
          body.labels || null,
          body.findings || null,
          body.diagnosis_label || null,
        ]
      );
    }
    return { ok: true, path: body.path, contentType };
  }

  // Signed download URL for private buckets
  @Get('download-url')
  async downloadUrl(@Query('path') path?: string) {
    if (!path) throw new BadRequestException('path is required');
    const bucket = this.bucket();
    const supa = this.getClient();
    const { data, error } = await supa.storage.from(bucket).createSignedUrl(path, 3600);
    if (error) {
      throw new BadRequestException(`sign failed: ${error.message}`);
    }
    return { url: data?.signedUrl, expiresIn: 3600 };
  }
}
