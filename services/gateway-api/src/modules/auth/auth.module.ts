import { Global, Module } from '@nestjs/common';
import { APP_INTERCEPTOR, APP_GUARD } from '@nestjs/core';
import { AuthGuard } from './auth.guard';
import { RequestContext } from './request-context.service';
import { AuthClaimsInterceptor } from './auth.interceptor';

@Global()
@Module({
	providers: [
		AuthGuard,
		RequestContext,
		{ provide: APP_INTERCEPTOR, useClass: AuthClaimsInterceptor },
		{ provide: APP_GUARD, useClass: AuthGuard },
	],
	exports: [AuthGuard, RequestContext],
})
export class AuthModule {}
