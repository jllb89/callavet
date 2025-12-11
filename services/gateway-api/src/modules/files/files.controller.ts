import { Controller, Get, Post, Query, UseGuards, Body, BadRequestException } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { createClient } from '@supabase/supabase-js';
import { DbService } from '../db/db.service';

@UseGuards(AuthGuard)
@Controller('files')
export class FilesController {
  constructor(private readonly db: DbService) {}
  private supabase = createClient(
    process.env.SUPABASE_URL as string,
    process.env.SUPABASE_SERVICE_ROLE_KEY as string
  );

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

    const { error } = await this.supabase.storage.from(bucket).upload(body.path, buffer, {
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
    return { ok: true, path: body.path };
  }

  // Signed download URL for private buckets
  @Get('download-url')
  async downloadUrl(@Query('path') path?: string) {
    if (!path) throw new BadRequestException('path is required');
    const bucket = this.bucket();
    const { data, error } = await this.supabase.storage.from(bucket).createSignedUrl(path, 3600);
    if (error) {
      throw new BadRequestException(`sign failed: ${error.message}`);
    }
    return { url: data?.signedUrl, expiresIn: 3600 };
  }
}
