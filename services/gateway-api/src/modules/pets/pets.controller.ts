import { Body, Controller, Delete, Get, HttpCode, HttpException, HttpStatus, Param, Patch, Post, UseGuards } from '@nestjs/common';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';

@Controller('pets')
@UseGuards(AuthGuard)
export class PetsController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}
  private supabase?: SupabaseClient;

  private getClient(): SupabaseClient {
    if (this.supabase) return this.supabase;
    const url = process.env.SUPABASE_URL;
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) {
      throw new HttpException('Supabase env missing: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY', HttpStatus.BAD_REQUEST);
    }
    this.supabase = createClient(url, key);
    return this.supabase;
  }

  private bucket(): string {
    const name = process.env.SUPABASE_STORAGE_BUCKET;
    if (!name) throw new HttpException('SUPABASE_STORAGE_BUCKET not set', HttpStatus.BAD_REQUEST);
    return name;
  }

  @Get()
  async list() {
    if (this.db.isStub) return { data: [] } as any;
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `select id::text as id, user_id::text as user_id, name, species, breed, birthdate, sex, weight_kg, medical_notes
           from pets
          order by created_at desc
          limit 100`
      );
      return r;
    });
    return { data: rows };
  }

  @Get(':id')
  async detail(@Param('id') id: string) {
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `select id::text as id, user_id::text as user_id, name, species, breed, birthdate, sex, weight_kg, medical_notes
           from pets
          where id = $1::uuid
          limit 1`,
        [id]
      );
      return r;
    });
    if (!rows.length) throw new HttpException('Not Found', 404);
    return rows[0];
  }

  @Post()
  @HttpCode(HttpStatus.CREATED)
  async create(@Body() body: any) {
    if (!body?.name || !body?.species) throw new HttpException('name and species required', 400);
    const userId = this.rc.requireUuidUserId();
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `insert into pets (id, user_id, name, species, breed, birthdate, sex, weight_kg, medical_notes)
         values (gen_random_uuid(), $1::uuid, $2, $3, $4, $5::date, $6, $7::float, $8)
         returning id::text as id, user_id::text as user_id, name, species, breed, birthdate, sex, weight_kg, medical_notes`,
        [
          userId,
          body.name,
          body.species,
          body.breed || null,
          body.birthdate || null,
          body.sex || null,
          body.weight_kg ?? null,
          body.medical_notes || null,
        ]
      );
      return r;
    });
    return rows[0];
  }

  @Patch(':id')
  async patch(@Param('id') id: string, @Body() body: any) {
    const fields = ['name', 'species', 'breed', 'birthdate', 'sex', 'weight_kg', 'medical_notes'];
    const sets: string[] = [];
    const args: any[] = [];
    for (const f of fields) {
      if (body?.[f] !== undefined) {
        args.push(body[f]);
        sets.push(`${f} = $${args.length}`);
      }
    }
    if (!sets.length) throw new HttpException('no fields', 400);
    args.push(id);
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `update pets set ${sets.join(', ')} where id = $${args.length}::uuid
         returning id::text as id, user_id::text as user_id, name, species, breed, birthdate, sex, weight_kg, medical_notes`,
        args
      );
      return r;
    });
    if (!rows.length) throw new HttpException('Not Found', 404);
    return rows[0];
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  async remove(@Param('id') id: string) {
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `delete from pets where id = $1::uuid returning id::text as id`,
        [id]
      );
      return r;
    });
    if (!rows.length) throw new HttpException('Not Found', 404);
    return;
  }

  @Post(':id/files/signed-url')
  async petSignedUrl(@Param('id') id: string, @Body() body: any) {
    const path = (body?.path || `pets/${id}/${Date.now()}-${Math.random().toString(36).slice(2)}.bin`).toString().trim();
    if (!path.startsWith(`pets/${id}/`)) {
      throw new HttpException('path must stay within the pet prefix', HttpStatus.BAD_REQUEST);
    }

    const bucket = this.bucket();
    const storage = this.getClient().storage.from(bucket) as any;
    if (typeof storage.createSignedUploadUrl !== 'function') {
      throw new HttpException('signed_upload_unsupported', HttpStatus.NOT_IMPLEMENTED);
    }

    const { data, error } = await storage.createSignedUploadUrl(path);
    if (error) {
      throw new HttpException(`signed_upload_failed: ${error.message}`, HttpStatus.BAD_REQUEST);
    }

    return {
      path,
      url: data?.signedUrl,
      token: data?.token,
      expires_in: 7200,
      method: 'PUT',
    };
  }
}
