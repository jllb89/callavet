import { Controller, Get, Query } from '@nestjs/common';
import { DbService } from '../db/db.service';

@Controller('centers')
export class CentersController {
  constructor(private readonly db: DbService) {}

  @Get('near')
  async near(@Query('lat') latStr?: string, @Query('lng') lngStr?: string, @Query('radiusKm') radiusStr?: string){
    const lat = Number(latStr ?? '0');
    const lng = Number(lngStr ?? '0');
    const radius = Number(radiusStr ?? '50');
    // If coordinates provided, attempt simple radius filter using stored geo_location as "lat,lng" (text)
    let rows: any[] = [];
    let mode = 'none';
    if (!Number.isNaN(lat) && !Number.isNaN(lng) && radius > 0) {
      const sql = `
        with centers as (
          select
            id,
            name,
            address,
            phone,
            website,
            is_partner,
            geo_location
          from vet_care_centers
        )
        select
          id,
          name,
          address,
          phone,
          website,
          is_partner
        from centers
        where geo_location is not null
          and geo_location like '%,%'
          and (
            -- Haversine (approx) distance in km
            6371 * acos(
              cos(radians($1)) * cos(radians(split_part(geo_location, ',', 1)::float)) *
              cos(radians(split_part(geo_location, ',', 2)::float) - radians($2)) +
              sin(radians($1)) * sin(radians(split_part(geo_location, ',', 1)::float))
            )
          ) <= $3
        order by name asc
        limit 100
      `;
      const res = await this.db.query(sql, [lat, lng, radius]);
      rows = res.rows;
      mode = 'geo';
    }
    // Fallback: return top centers without geo filter
    if (!rows.length) {
      const res = await this.db.query(
        'select id, name, address, phone, website, is_partner from vet_care_centers order by created_at desc limit 50'
      );
      rows = res.rows;
      mode = mode === 'geo' ? 'geo_fallback' : 'fallback';
    }
    if (process.env.DEV_DB_DEBUG === '1') {
      // eslint-disable-next-line no-console
      console.log('[centers/near]', {
        lat,
        lng,
        radiusKm: radius,
        mode,
        count: rows.length,
        sample: rows[0] ? { id: rows[0].id, name: rows[0].name } : null
      });
    }
    return { data: rows };
  }
}
