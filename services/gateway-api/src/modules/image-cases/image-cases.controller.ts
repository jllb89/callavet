import { Controller, Get, Post, Param, UseGuards, Body, BadRequestException } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';

@UseGuards(AuthGuard)
@Controller()
export class ImageCasesController {
  constructor(private readonly db: DbService) {}

  @Get('pets/:petId/image-cases')
  async list(@Param('petId') petId: string) {
    if (!petId) throw new BadRequestException('petId is required');
    const { rows } = await (this.db as any).query(
      `select id, pet_id, session_id, image_url, labels, findings, diagnosis_label, created_at
         from image_cases where pet_id = $1 order by created_at desc`,
      [petId]
    );
    return { data: rows };
  }

  @Post('pets/:petId/image-cases')
  async create(
    @Param('petId') petId: string,
    @Body()
    body: {
      image_url?: string;
      labels?: string[];
      findings?: string;
      diagnosis_label?: string;
      session_id?: string;
    }
  ) {
    if (!petId) throw new BadRequestException('petId is required');
    if (!body?.image_url) throw new BadRequestException('image_url is required');
    const idSql = `select gen_random_uuid() as id`;
    const idRes = await (this.db as any).query(idSql);
    const id = idRes.rows[0].id;
    const { rows } = await (this.db as any).query(
      `insert into image_cases (id, pet_id, session_id, image_url, labels, findings, diagnosis_label, created_at)
       values ($1, $2, $3, $4, $5, $6, $7, now())
       returning id, pet_id, session_id, image_url, labels, findings, diagnosis_label, created_at`,
      [id, petId, body.session_id || null, body.image_url, body.labels || null, body.findings || null, body.diagnosis_label || null]
    );
    return rows[0];
  }

  @Get('image-cases/:id')
  async detail(@Param('id') id: string) {
    if (!id) throw new BadRequestException('id is required');
    const { rows } = await (this.db as any).query(
      `select id, pet_id, session_id, image_url, labels, findings, diagnosis_label, created_at
         from image_cases where id = $1`,
      [id]
    );
    if (!rows.length) throw new BadRequestException('not_found');
    return rows[0];
  }
}
