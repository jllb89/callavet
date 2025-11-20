import { Controller, Get, Param, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';

@Controller('pets')
@UseGuards(AuthGuard)
export class PetsController {
  @Get()
  list() {
    return {
      ok: false,
      domain: 'pets',
      reason: 'not_ready',
      message: 'Pets API not ready; to be finished in frontend integration.',
      data: []
    };
  }

  @Get(':id')
  detail(@Param('id') id: string) {
    return {
      ok: false,
      domain: 'pets',
      reason: 'not_ready',
      message: 'Pets detail API not ready; to be finished in frontend integration.',
      id
    };
  }
}
