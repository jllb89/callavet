import { Body, Controller, Delete, Get, HttpCode, HttpException, HttpStatus, Param, Patch, Post, UseGuards } from '@nestjs/common';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';

const PET_SELECT_SQL = `
  id::text as id,
  user_id::text as user_id,
  name,
  species,
  sex,
  age_range,
  weight_range,
  location_country,
  location_state_region,
  breed,
  warmblood_subbreed,
  other_breed_text,
  primary_activity,
  discipline,
  other_discipline_text,
  training_intensity,
  terrain,
  other_terrain_text,
  observed_last_6_months,
  known_conditions,
  current_treatments_or_supplements,
  last_vet_check,
  vaccines_up_to_date,
  deworming_status,
  additional_notes,
  created_at
`;

const SEX_VALUES = new Set(['male', 'female', 'gelding']);
const AGE_RANGE_VALUES = new Set(['foal_0_2', 'young_3_5', 'adult_6_15', 'senior_16_plus']);
const WEIGHT_RANGE_VALUES = new Set(['lt_400', '400_500', '500_600', 'gt_600']);
const BREED_VALUES = new Set(['quarter_horse', 'thoroughbred', 'pre', 'arabian', 'criollo', 'appaloosa', 'paint_horse', 'warmblood', 'mixed', 'other']);
const WARMBLOOD_SUBBREED_VALUES = new Set(['holsteiner', 'hanoverian', 'kwpn', 'oldenburg', 'selle_francais', 'westphalian', 'trakehner', 'other']);
const PRIMARY_ACTIVITY_VALUES = new Set(['competition', 'regular_training', 'rehabilitation_recovery', 'retired', 'recreational']);
const DISCIPLINE_VALUES = new Set(['jumping', 'dressage', 'polo', 'endurance', 'barrel_racing', 'reining', 'charreada', 'ranch_work', 'recreational', 'other']);
const TRAINING_INTENSITY_VALUES = new Set(['1_2_per_week', '3_4_per_week', '5_plus_per_week']);
const TERRAIN_VALUES = new Set(['sand', 'grass', 'dirt', 'mixed', 'other']);
const OBSERVED_VALUES = new Set(['mild_lameness', 'stiffness', 'performance_drop', 'appetite_changes', 'none']);
const KNOWN_CONDITIONS_VALUES = new Set(['digestive', 'locomotor', 'respiratory', 'skin', 'none']);
const LAST_VET_CHECK_VALUES = new Set(['lt_3_months', '3_6_months', 'gt_6_months', 'dont_remember']);
const VACCINE_VALUES = new Set(['yes', 'no', 'not_sure']);
const DEWORMING_VALUES = new Set(['regular', 'irregular', 'not_sure']);

type PetPayload = {
  name?: string;
  species?: string;
  sex?: string;
  age_range?: string;
  weight_range?: string;
  location_country?: string;
  location_state_region?: string;
  breed?: string;
  warmblood_subbreed?: string | null;
  other_breed_text?: string | null;
  primary_activity?: string;
  discipline?: string;
  other_discipline_text?: string | null;
  training_intensity?: string;
  terrain?: string;
  other_terrain_text?: string | null;
  observed_last_6_months?: string[];
  known_conditions?: string[];
  current_treatments_or_supplements?: string | null;
  last_vet_check?: string;
  vaccines_up_to_date?: string;
  deworming_status?: string;
  additional_notes?: string | null;
};

@Controller('pets')
@UseGuards(AuthGuard)
export class PetsController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}
  private supabase?: SupabaseClient;

  private normalizeString(input: unknown): string {
    return typeof input === 'string' ? input.trim() : '';
  }

  private parseOptionalString(input: unknown, field: string, maxLength: number): string | null {
    if (input === undefined || input === null) return null;
    const value = this.normalizeString(input);
    if (!value) return null;
    if (value.length > maxLength) {
      throw new HttpException(`${field} too long`, HttpStatus.BAD_REQUEST);
    }
    return value;
  }

  private parseRequiredString(input: unknown, field: string, maxLength = 100): string {
    const value = this.normalizeString(input);
    if (!value) {
      throw new HttpException(`${field} required`, HttpStatus.BAD_REQUEST);
    }
    if (value.length > maxLength) {
      throw new HttpException(`${field} too long`, HttpStatus.BAD_REQUEST);
    }
    return value;
  }

  private parseEnum(input: unknown, field: string, allowed: Set<string>, required: boolean): string | undefined {
    if (input === undefined || input === null) {
      if (required) throw new HttpException(`${field} required`, HttpStatus.BAD_REQUEST);
      return undefined;
    }
    const value = this.normalizeString(input);
    if (!value) {
      if (required) throw new HttpException(`${field} required`, HttpStatus.BAD_REQUEST);
      return undefined;
    }
    if (!allowed.has(value)) {
      throw new HttpException(`${field} invalid`, HttpStatus.BAD_REQUEST);
    }
    return value;
  }

  private parseEnumArray(input: unknown, field: string, allowed: Set<string>, required: boolean): string[] | undefined {
    if (input === undefined || input === null) {
      if (required) throw new HttpException(`${field} required`, HttpStatus.BAD_REQUEST);
      return undefined;
    }
    if (!Array.isArray(input)) {
      throw new HttpException(`${field} must be an array`, HttpStatus.BAD_REQUEST);
    }
    const dedup = [...new Set(input.map((value) => this.normalizeString(value)).filter((value) => !!value))];
    if (dedup.length === 0) {
      throw new HttpException(`${field} requires at least one item`, HttpStatus.BAD_REQUEST);
    }
    for (const value of dedup) {
      if (!allowed.has(value)) {
        throw new HttpException(`${field} contains invalid value`, HttpStatus.BAD_REQUEST);
      }
    }
    if (dedup.includes('none') && dedup.length > 1) {
      throw new HttpException(`${field} cannot combine 'none' with other values`, HttpStatus.BAD_REQUEST);
    }
    return dedup;
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

  private parsePayload(body: any, mode: 'create' | 'patch'): PetPayload {
    const required = mode === 'create';
    const payload: PetPayload = {};
    const allowed = new Set([
      'name', 'species', 'sex', 'age_range', 'weight_range', 'location_country', 'location_state_region', 'location', 'breed',
      'warmblood_subbreed', 'other_breed_text', 'primary_activity', 'discipline', 'other_discipline_text', 'training_intensity',
      'terrain', 'other_terrain_text', 'observed_last_6_months', 'known_conditions', 'current_treatments_or_supplements',
      'last_vet_check', 'vaccines_up_to_date', 'deworming_status', 'additional_notes',
    ]);

    for (const key of Object.keys(body || {})) {
      if (!allowed.has(key)) {
        throw new HttpException(`unsupported field: ${key}`, HttpStatus.BAD_REQUEST);
      }
    }

    if (required || body?.name !== undefined) payload.name = this.parseRequiredString(body?.name, 'name', 100);

    const species = this.normalizeSpecies(body?.species, required);
    if (species !== undefined) payload.species = species;

    const sex = this.parseEnum(body?.sex, 'sex', SEX_VALUES, required);
    if (sex !== undefined) payload.sex = sex;

    const ageRange = this.parseEnum(body?.age_range, 'age_range', AGE_RANGE_VALUES, required);
    if (ageRange !== undefined) payload.age_range = ageRange;

    const weightRange = this.parseEnum(body?.weight_range, 'weight_range', WEIGHT_RANGE_VALUES, required);
    if (weightRange !== undefined) payload.weight_range = weightRange;

    const locationCountry = body?.location?.country ?? body?.location_country;
    const locationState = body?.location?.state_region ?? body?.location_state_region;
    if (required || locationCountry !== undefined) payload.location_country = this.parseRequiredString(locationCountry, 'location.country', 100);
    if (required || locationState !== undefined) payload.location_state_region = this.parseRequiredString(locationState, 'location.state_region', 100);

    const breed = this.parseEnum(body?.breed, 'breed', BREED_VALUES, required);
    if (breed !== undefined) payload.breed = breed;

    if (required || body?.warmblood_subbreed !== undefined) {
      if (body?.warmblood_subbreed === null) {
        payload.warmblood_subbreed = null;
      } else {
        const value = this.parseEnum(body?.warmblood_subbreed, 'warmblood_subbreed', WARMBLOOD_SUBBREED_VALUES, false);
        payload.warmblood_subbreed = value ?? null;
      }
    }

    if (required || body?.other_breed_text !== undefined) {
      payload.other_breed_text = this.parseOptionalString(body?.other_breed_text, 'other_breed_text', 100);
    }

    const primaryActivity = this.parseEnum(body?.primary_activity, 'primary_activity', PRIMARY_ACTIVITY_VALUES, required);
    if (primaryActivity !== undefined) payload.primary_activity = primaryActivity;

    const discipline = this.parseEnum(body?.discipline, 'discipline', DISCIPLINE_VALUES, required);
    if (discipline !== undefined) payload.discipline = discipline;

    if (required || body?.other_discipline_text !== undefined) {
      payload.other_discipline_text = this.parseOptionalString(body?.other_discipline_text, 'other_discipline_text', 100);
    }

    const trainingIntensity = this.parseEnum(body?.training_intensity, 'training_intensity', TRAINING_INTENSITY_VALUES, required);
    if (trainingIntensity !== undefined) payload.training_intensity = trainingIntensity;

    const terrain = this.parseEnum(body?.terrain, 'terrain', TERRAIN_VALUES, required);
    if (terrain !== undefined) payload.terrain = terrain;

    if (required || body?.other_terrain_text !== undefined) {
      payload.other_terrain_text = this.parseOptionalString(body?.other_terrain_text, 'other_terrain_text', 100);
    }

    const observed = this.parseEnumArray(body?.observed_last_6_months, 'observed_last_6_months', OBSERVED_VALUES, required);
    if (observed !== undefined) payload.observed_last_6_months = observed;

    const known = this.parseEnumArray(body?.known_conditions, 'known_conditions', KNOWN_CONDITIONS_VALUES, required);
    if (known !== undefined) payload.known_conditions = known;

    if (required || body?.current_treatments_or_supplements !== undefined) {
      payload.current_treatments_or_supplements = this.parseOptionalString(body?.current_treatments_or_supplements, 'current_treatments_or_supplements', 500);
    }

    const lastVetCheck = this.parseEnum(body?.last_vet_check, 'last_vet_check', LAST_VET_CHECK_VALUES, required);
    if (lastVetCheck !== undefined) payload.last_vet_check = lastVetCheck;

    const vaccines = this.parseEnum(body?.vaccines_up_to_date, 'vaccines_up_to_date', VACCINE_VALUES, required);
    if (vaccines !== undefined) payload.vaccines_up_to_date = vaccines;

    const deworming = this.parseEnum(body?.deworming_status, 'deworming_status', DEWORMING_VALUES, required);
    if (deworming !== undefined) payload.deworming_status = deworming;

    if (required || body?.additional_notes !== undefined) {
      payload.additional_notes = this.parseOptionalString(body?.additional_notes, 'additional_notes', 1000);
    }

    // Conditional dependencies from KYC schema.
    const effectiveBreed = payload.breed;
    if (effectiveBreed === 'warmblood' && !payload.warmblood_subbreed) {
      throw new HttpException('warmblood_subbreed required when breed=warmblood', HttpStatus.BAD_REQUEST);
    }
    if (effectiveBreed === 'other' && !payload.other_breed_text) {
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
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `select ${PET_SELECT_SQL}
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
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `select ${PET_SELECT_SQL}
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
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `insert into pets (
            id, user_id, name, species, sex, age_range, weight_range, location_country, location_state_region,
            breed, warmblood_subbreed, other_breed_text, primary_activity, discipline, other_discipline_text,
            training_intensity, terrain, other_terrain_text, observed_last_6_months, known_conditions,
            current_treatments_or_supplements, last_vet_check, vaccines_up_to_date, deworming_status, additional_notes
          )
         values (
            gen_random_uuid(), $1::uuid, $2, $3, $4, $5, $6, $7, $8,
            $9, $10, $11, $12, $13, $14,
            $15, $16, $17, $18::text[], $19::text[],
            $20, $21, $22, $23, $24
         )
         returning ${PET_SELECT_SQL}`,
        [
          userId,
          payload.name,
          payload.species,
          payload.sex,
          payload.age_range,
          payload.weight_range,
          payload.location_country,
          payload.location_state_region,
          payload.breed,
          payload.warmblood_subbreed ?? null,
          payload.other_breed_text ?? null,
          payload.primary_activity,
          payload.discipline,
          payload.other_discipline_text ?? null,
          payload.training_intensity,
          payload.terrain,
          payload.other_terrain_text ?? null,
          payload.observed_last_6_months,
          payload.known_conditions,
          payload.current_treatments_or_supplements ?? null,
          payload.last_vet_check,
          payload.vaccines_up_to_date,
          payload.deworming_status,
          payload.additional_notes ?? null,
        ]
      );
      return r;
    });
    return this.normalizeOutput(rows[0]);
  }

  @Patch(':id')
  async patch(@Param('id') id: string, @Body() body: any) {
    const userId = this.rc.requireUuidUserId();
    const payload = this.parsePayload(body, 'patch');
    const fieldSpec: Array<{ key: keyof PetPayload; cast?: string }> = [
      { key: 'name' },
      { key: 'species' },
      { key: 'sex' },
      { key: 'age_range' },
      { key: 'weight_range' },
      { key: 'location_country' },
      { key: 'location_state_region' },
      { key: 'breed' },
      { key: 'warmblood_subbreed' },
      { key: 'other_breed_text' },
      { key: 'primary_activity' },
      { key: 'discipline' },
      { key: 'other_discipline_text' },
      { key: 'training_intensity' },
      { key: 'terrain' },
      { key: 'other_terrain_text' },
      { key: 'observed_last_6_months', cast: '::text[]' },
      { key: 'known_conditions', cast: '::text[]' },
      { key: 'current_treatments_or_supplements' },
      { key: 'last_vet_check' },
      { key: 'vaccines_up_to_date' },
      { key: 'deworming_status' },
      { key: 'additional_notes' },
    ];
    const sets: string[] = [];
    const args: any[] = [];
    for (const spec of fieldSpec) {
      if ((payload as any)[spec.key] !== undefined) {
        args.push((payload as any)[spec.key]);
        sets.push(`${spec.key} = $${args.length}${spec.cast || ''}`);
      }
    }
    if (!sets.length) throw new HttpException('no fields', 400);
    args.push(id, userId);
    const { rows } = await this.db.runInTx(async (q) => {
      const r = await q(
        `update pets set ${sets.join(', ')} where id = $${args.length - 1}::uuid and user_id = $${args.length}::uuid
         returning ${PET_SELECT_SQL}`,
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
