import { Global, Module, forwardRef } from '@nestjs/common';
import { APP_INTERCEPTOR, APP_GUARD } from '@nestjs/core';
import { AuthGuard } from './auth.guard';
import { RequestContext } from './request-context.service';
import { AuthClaimsInterceptor } from './auth.interceptor';
import { DbModule } from '../db/db.module';
import { ConfigModule } from '../config/config.module';
import { OtpController } from './otp.controller';

@Global()
@Module({
	imports: [forwardRef(() => DbModule), ConfigModule],
	controllers: [OtpController],
	providers: [
		AuthGuard,
		RequestContext,
		{ provide: APP_INTERCEPTOR, useClass: AuthClaimsInterceptor },
		{ provide: APP_GUARD, useClass: AuthGuard },
	],
	exports: [AuthGuard, RequestContext],
})
export class AuthModule {}
