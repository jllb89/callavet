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
    if (this.db.isStub) {
      return { ok: true, mode: 'stub', centers: [ { id: 'center_1', name: 'Centro Vet MX', lat, lng, distanceKm: 1.2 } ] };
    }
    // minimal stub query; replace with geo filtering as needed
    const { rows } = await this.db.query('select id, name from vet_care_centers limit 10');
    return { ok: true, centers: rows };
  }
}
