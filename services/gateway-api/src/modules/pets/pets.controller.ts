import { Body, Controller, Delete, Get, HttpException, Param, Patch, Post, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';

@Controller('pets')
@UseGuards(AuthGuard)
export class PetsController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

  @Get()
  async list() {
    if (this.db.isStub) return { items: [] } as any;
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `select id::text as id, name, species, breed, color, sex, birthdate, archived_at
           from pets
          where archived_at is null
          order by created_at desc
          limit 100`
      );
      return r;
    });
    return { items: rows };
  }

  @Get(':id')
  async detail(@Param('id') id: string) {
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `select id::text as id, name, species, breed, color, sex, birthdate, archived_at
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
  async create(@Body() body: any) {
    if (!body?.name) throw new HttpException('name required', 400);
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `insert into pets (name, species, breed, color, sex, birthdate)
         values ($1, $2, $3, $4, $5, $6)
         returning id::text as id, name, species, breed, color, sex, birthdate`,
        [body.name, body.species || null, body.breed || null, body.color || null, body.sex || null, body.birthdate || null]
      );
      return r;
    });
    return rows[0];
  }

  @Patch(':id')
  async patch(@Param('id') id: string, @Body() body: any) {
    const fields = ['name', 'species', 'breed', 'color', 'sex', 'birthdate'];
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
         returning id::text as id, name, species, breed, color, sex, birthdate, archived_at`,
        args
      );
      return r;
    });
    if (!rows.length) throw new HttpException('Not Found', 404);
    return rows[0];
  }

  @Delete(':id')
  async remove(@Param('id') id: string) {
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `update pets set archived_at = now() where id = $1::uuid
         returning id::text as id`,
        [id]
      );
      return r;
    });
    if (!rows.length) throw new HttpException('Not Found', 404);
    return { ok: true };
  }
}
