import { CallHandler, ExecutionContext, Injectable, NestInterceptor } from '@nestjs/common';
import { Observable } from 'rxjs';
import { RequestContext, JwtClaims } from './request-context.service';

@Injectable()
export class AuthClaimsInterceptor implements NestInterceptor {
  constructor(private readonly rc: RequestContext) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<any> {
    const req = context.switchToHttp().getRequest<{ authClaims?: JwtClaims }>();
    const claims = req?.authClaims;
    let stream!: Observable<any>;
    this.rc.runWithClaims(claims, () => {
      stream = next.handle();
    });
    return stream;
  }
}
