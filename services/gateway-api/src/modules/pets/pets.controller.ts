import { Body, Controller, Delete, Get, HttpCode, HttpException, HttpStatus, Param, Patch, Post, Put, UseGuards } from '@nestjs/common';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { SchemaService } from './schema.service';

@Controller('pets')
@UseGuards(AuthGuard)
export class PetsController {
  constructor(
    private readonly db: DbService,
    private readonly rc: RequestContext,
    private readonly schema: SchemaService,
  ) {}
  private supabase?: SupabaseClient;

  private sanitizeStringArray(input: unknown): string[] {
    if (!Array.isArray(input)) return [];
    return [...new Set(input.map((v) => this.normalizeString(v)).filter((v) => !!v))];
  }

  private ensureJsonObject(input: unknown, fieldName: string): Record<string, any> {
    if (input == null) return {};
    if (typeof input !== 'object' || Array.isArray(input)) {
      throw new HttpException(`${fieldName} must be an object`, HttpStatus.BAD_REQUEST);
    }
    return input as Record<string, any>;
  }

  private ensureJsonArray(input: unknown, fieldName: string): any[] {
    if (input == null) return [];
    if (!Array.isArray(input)) {
      throw new HttpException(`${fieldName} must be an array`, HttpStatus.BAD_REQUEST);
    }
    return input;
  }

  private async assertPetAccessible(petId: string): Promise<void> {
    const userId = this.rc.requireUuidUserId();
    const { rows } = await this.db.runInTx(async (q) => {
      return q(
        `select p.id
           from pets p
          where p.id = $1::uuid
            and (p.user_id = $2::uuid or is_admin())
          limit 1`,
        [petId, userId],
      );
    });
    if (!rows.length) throw new HttpException('Not Found', HttpStatus.NOT_FOUND);
  }

  private normalizeString(input: unknown): string {
    return typeof input === 'string' ? input.trim() : '';
  }

  private parseValue(input: unknown, fieldName: string, mode: 'create' | 'patch'): any {
    const schema = this.schema.getPetSchema();
    const field = schema.fields.get(fieldName);
    if (!field) throw new HttpException(`unknown field: ${fieldName}`, HttpStatus.BAD_REQUEST);

    const isRequired = mode === 'create' && field.required;

    // Handle undefined/null
    if (input === undefined || input === null) {
      if (isRequired) throw new HttpException(`${fieldName} required`, HttpStatus.BAD_REQUEST);
      return undefined;
    }

    // Handle special location fields from nested object
    if (fieldName === 'location_country' || fieldName === 'location_state_region') {
      // These are handled specially in parsePayload
      return undefined;
    }

    // String fields
    if (field.type === 'string') {
      const value = this.normalizeString(input);
      if (!value) {
        if (isRequired) throw new HttpException(`${fieldName} required`, HttpStatus.BAD_REQUEST);
        return undefined;
      }
      if (field.maxLength && value.length > field.maxLength) {
        throw new HttpException(`${fieldName} too long`, HttpStatus.BAD_REQUEST);
      }
      return value;
    }

    // Enum fields
    if (field.type === 'enum') {
      const value = this.normalizeString(input);
      if (!value) {
        if (isRequired) throw new HttpException(`${fieldName} required`, HttpStatus.BAD_REQUEST);
        return undefined;
      }
      if (!field.enumValues?.has(value)) {
        throw new HttpException(`${fieldName} invalid value`, HttpStatus.BAD_REQUEST);
      }
      return value;
    }

    // Array fields
    if (field.type === 'array') {
      if (!Array.isArray(input)) {
        throw new HttpException(`${fieldName} must be an array`, HttpStatus.BAD_REQUEST);
      }
      const dedup = [...new Set(input.map((v) => this.normalizeString(v)).filter((v) => !!v))];
      if (dedup.length === 0) {
        if (isRequired) throw new HttpException(`${fieldName} requires at least one item`, HttpStatus.BAD_REQUEST);
        return undefined;
      }
      if (field.arrayEnumValues) {
        for (const v of dedup) {
          if (!field.arrayEnumValues.has(v)) {
            throw new HttpException(`${fieldName} contains invalid value: ${v}`, HttpStatus.BAD_REQUEST);
          }
        }
      }
      if (dedup.includes('none') && dedup.length > 1) {
        throw new HttpException(`${fieldName} cannot combine 'none' with other values`, HttpStatus.BAD_REQUEST);
      }
      return dedup;
    }

    return input;
  }

  private normalizeSpecies(input: unknown, required: boolean): string | undefined {
    if (input === undefined || input === null) {
      if (required) throw new HttpException('species required', HttpStatus.BAD_REQUEST);
      return undefined;
    }
    const value = this.normalizeString(input).toLowerCase();
    if (!value) {
      if (required) throw new HttpException('species required', HttpStatus.BAD_REQUEST);
      return undefined;
    }
    if (value === 'equine') return 'horse';
    if (value !== 'horse') {
      throw new HttpException('species must be horse', HttpStatus.BAD_REQUEST);
    }
    return 'horse';
  }

  private parsePayload(body: any, mode: 'create' | 'patch'): Record<string, any> {
    const schema = this.schema.getPetSchema();
    const payload: Record<string, any> = {};
    const allowedFields = new Set(Array.from(schema.fields.keys()).concat(['location']));

    for (const key of Object.keys(body || {})) {
      if (!allowedFields.has(key)) {
        throw new HttpException(`unsupported field: ${key}`, HttpStatus.BAD_REQUEST);
      }
    }

    // Handle name separately (always required on create)
    if (mode === 'create' || body?.name !== undefined) {
      const field = schema.fields.get('name');
      const value = this.normalizeString(body?.name);
      if (!value) {
        if (mode === 'create') throw new HttpException('name required', HttpStatus.BAD_REQUEST);
      } else {
        if (field?.maxLength && value.length > field.maxLength) {
          throw new HttpException('name too long', HttpStatus.BAD_REQUEST);
        }
        payload.name = value;
      }
    }

    // Handle species separately
    const species = this.normalizeSpecies(body?.species, mode === 'create');
    if (species !== undefined) payload.species = species;

    // Handle location fields from nested object or flat fields
    const locationCountry = body?.location?.country ?? body?.location_country;
    const locationState = body?.location?.state_region ?? body?.location_state_region;
    if (mode === 'create' || locationCountry !== undefined) {
      const value = this.normalizeString(locationCountry);
      if (!value) {
        if (mode === 'create') throw new HttpException('location.country required', HttpStatus.BAD_REQUEST);
      } else {
        const field = schema.fields.get('location_country');
        if (field?.maxLength && value.length > field.maxLength) {
          throw new HttpException('location.country too long', HttpStatus.BAD_REQUEST);
        }
        payload.location_country = value;
      }
    }
    if (mode === 'create' || locationState !== undefined) {
      const value = this.normalizeString(locationState);
      if (!value) {
        if (mode === 'create') throw new HttpException('location.state_region required', HttpStatus.BAD_REQUEST);
      } else {
        const field = schema.fields.get('location_state_region');
        if (field?.maxLength && value.length > field.maxLength) {
          throw new HttpException('location.state_region too long', HttpStatus.BAD_REQUEST);
        }
        payload.location_state_region = value;
      }
    }

    // Parse all other fields dynamically from schema
    for (const [fieldName, field] of schema.fields) {
      // Skip already-processed fields
      if (['name', 'species', 'location_country', 'location_state_region', 'id', 'user_id', 'created_at'].includes(fieldName)) {
        continue;
      }

      if (body?.[fieldName] !== undefined) {
        const value = this.parseValue(body[fieldName], fieldName, mode);
        if (value !== undefined) {
          payload[fieldName] = value;
        }
      } else if (mode === 'create' && field.required) {
        throw new HttpException(`${fieldName} required`, HttpStatus.BAD_REQUEST);
      }
    }

    // Check conditional dependencies
    if (payload.breed === 'warmblood' && !payload.warmblood_subbreed) {
      throw new HttpException('warmblood_subbreed required when breed=warmblood', HttpStatus.BAD_REQUEST);
    }
    if (payload.breed === 'other' && !payload.other_breed_text) {
      throw new HttpException('other_breed_text required when breed=other', HttpStatus.BAD_REQUEST);
    }
    if (payload.discipline === 'other' && !payload.other_discipline_text) {
      throw new HttpException('other_discipline_text required when discipline=other', HttpStatus.BAD_REQUEST);
    }
    if (payload.terrain === 'other' && !payload.other_terrain_text) {
      throw new HttpException('other_terrain_text required when terrain=other', HttpStatus.BAD_REQUEST);
    }

    return payload;
  }

  private normalizeOutput(row: any) {
    return {
      ...row,
      location: {
        country: row.location_country,
        state_region: row.location_state_region,
      },
    };
  }

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
    const userId = this.rc.requireUuidUserId();
    const schema = this.schema.getPetSchema();
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `select ${schema.selectSql}
           from pets
          where user_id = $1::uuid
          order by created_at desc
          limit 100`,
        [userId],
      );
      return r;
    });
    return { data: rows.map((row) => this.normalizeOutput(row)) };
  }

  @Get(':id')
  async detail(@Param('id') id: string) {
    const userId = this.rc.requireUuidUserId();
    const schema = this.schema.getPetSchema();
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `select ${schema.selectSql}
           from pets
          where id = $1::uuid and user_id = $2::uuid
          limit 1`,
        [id, userId],
      );
      return r;
    });
    if (!rows.length) throw new HttpException('Not Found', 404);
    return this.normalizeOutput(rows[0]);
  }

  @Post()
  @HttpCode(HttpStatus.CREATED)
  async create(@Body() body: any) {
    const payload = this.parsePayload(body, 'create');
    const userId = this.rc.requireUuidUserId();
    const schema = this.schema.getPetSchema();

    // Build INSERT dynamically from payload
    const fields = ['id', 'user_id', ...Object.keys(payload)];
    const values = ['gen_random_uuid()', '$1::uuid', ...Object.keys(payload).map((_, i) => `$${i + 2}`)];
    const castMap: Record<string, string> = {
      observed_last_6_months: '::text[]',
      known_conditions: '::text[]',
    };
    const castedValues = values.map((v, i) => {
      if (i < 2) return v; // id and user_id
      const fieldName = fields[i];
      const cast = castMap[fieldName] || '';
      return `${v}${cast}`;
    });

    const args = [userId, ...Object.keys(payload).map((k) => payload[k])];

    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `insert into pets (${fields.join(', ')})
         values (${castedValues.join(', ')})
         returning ${schema.selectSql}`,
        args
      );
      return r;
    });
    return this.normalizeOutput(rows[0]);
  }

  @Patch(':id')
  async patch(@Param('id') id: string, @Body() body: any) {
    const userId = this.rc.requireUuidUserId();
    const payload = this.parsePayload(body, 'patch');
    const schema = this.schema.getPetSchema();

    // Build UPDATE dynamically from payload
    const castMap: Record<string, string> = {
      observed_last_6_months: '::text[]',
      known_conditions: '::text[]',
    };
    const sets: string[] = [];
    const args: any[] = [];
    for (const [key, value] of Object.entries(payload)) {
      args.push(value);
      const cast = castMap[key] || '';
      sets.push(`${key} = $${args.length}${cast}`);
    }
    if (!sets.length) throw new HttpException('no fields', 400);
    args.push(id, userId);

    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `update pets set ${sets.join(', ')} where id = $${args.length - 1}::uuid and user_id = $${args.length}::uuid
         returning ${schema.selectSql}`,
        args
      );
      return r;
    });
    if (!rows.length) throw new HttpException('Not Found', 404);
    return this.normalizeOutput(rows[0]);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  async remove(@Param('id') id: string) {
    const userId = this.rc.requireUuidUserId();
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `delete from pets where id = $1::uuid and user_id = $2::uuid returning id::text as id`,
        [id, userId]
      );
      return r;
    });
    if (!rows.length) throw new HttpException('Not Found', 404);
    return;
  }

  @Get(':id/health-profile')
  async getHealthProfile(@Param('id') id: string) {
    await this.assertPetAccessible(id);
    const { rows } = await this.db.runInTx(async (q) => {
      return q(
        `select pet_id, allergies, chronic_conditions, current_medications, vaccine_history,
                injury_history, procedure_history, feed_profile, insurance, emergency_contacts,
                created_at, updated_at
           from pet_health_profiles
          where pet_id = $1::uuid
          limit 1`,
        [id],
      );
    });

    if (rows.length) return rows[0];

    const created = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `insert into pet_health_profiles (pet_id)
         values ($1::uuid)
         on conflict (pet_id) do update set pet_id = excluded.pet_id
         returning pet_id, allergies, chronic_conditions, current_medications, vaccine_history,
                   injury_history, procedure_history, feed_profile, insurance, emergency_contacts,
                   created_at, updated_at`,
        [id],
      );
      return rows[0];
    });

    return created;
  }

  @Put(':id/health-profile')
  async upsertHealthProfile(
    @Param('id') id: string,
    @Body()
    body: {
      allergies?: string[];
      chronic_conditions?: string[];
      current_medications?: any[];
      vaccine_history?: any[];
      injury_history?: any[];
      procedure_history?: any[];
      feed_profile?: Record<string, any>;
      insurance?: Record<string, any>;
      emergency_contacts?: any[];
    },
  ) {
    await this.assertPetAccessible(id);

    const payload = {
      allergies: this.sanitizeStringArray(body?.allergies),
      chronic_conditions: this.sanitizeStringArray(body?.chronic_conditions),
      current_medications: this.ensureJsonArray(body?.current_medications, 'current_medications'),
      vaccine_history: this.ensureJsonArray(body?.vaccine_history, 'vaccine_history'),
      injury_history: this.ensureJsonArray(body?.injury_history, 'injury_history'),
      procedure_history: this.ensureJsonArray(body?.procedure_history, 'procedure_history'),
      feed_profile: this.ensureJsonObject(body?.feed_profile, 'feed_profile'),
      insurance: this.ensureJsonObject(body?.insurance, 'insurance'),
      emergency_contacts: this.ensureJsonArray(body?.emergency_contacts, 'emergency_contacts'),
    };

    const { rows } = await this.db.runInTx(async (q) => {
      return q(
        `insert into pet_health_profiles (
           pet_id,
           allergies,
           chronic_conditions,
           current_medications,
           vaccine_history,
           injury_history,
           procedure_history,
           feed_profile,
           insurance,
           emergency_contacts
         )
         values (
           $1::uuid,
           $2::text[],
           $3::text[],
           $4::jsonb,
           $5::jsonb,
           $6::jsonb,
           $7::jsonb,
           $8::jsonb,
           $9::jsonb,
           $10::jsonb
         )
         on conflict (pet_id) do update set
           allergies = excluded.allergies,
           chronic_conditions = excluded.chronic_conditions,
           current_medications = excluded.current_medications,
           vaccine_history = excluded.vaccine_history,
           injury_history = excluded.injury_history,
           procedure_history = excluded.procedure_history,
           feed_profile = excluded.feed_profile,
           insurance = excluded.insurance,
           emergency_contacts = excluded.emergency_contacts,
           updated_at = now()
         returning pet_id, allergies, chronic_conditions, current_medications, vaccine_history,
                   injury_history, procedure_history, feed_profile, insurance, emergency_contacts,
                   created_at, updated_at`,
        [
          id,
          payload.allergies,
          payload.chronic_conditions,
          JSON.stringify(payload.current_medications),
          JSON.stringify(payload.vaccine_history),
          JSON.stringify(payload.injury_history),
          JSON.stringify(payload.procedure_history),
          JSON.stringify(payload.feed_profile),
          JSON.stringify(payload.insurance),
          JSON.stringify(payload.emergency_contacts),
        ],
      );
    });

    return rows[0];
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
