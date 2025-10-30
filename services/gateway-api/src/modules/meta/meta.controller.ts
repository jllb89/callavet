import { Controller, Get } from '@nestjs/common';

@Controller()
export class MetaController {
  @Get('version')
  version() {
    return {
      ok: true,
      service: 'gateway',
      version: process.env.APP_VERSION || 'dev',
      commit: process.env.GIT_SHA || null,
      buildTime: process.env.BUILD_TIME || null,
    };
  }

  @Get('time')
  time() {
    const now = new Date();
    return { ok: true, service: 'gateway', time: now.toISOString(), epoch_ms: now.getTime() };
  }
}
