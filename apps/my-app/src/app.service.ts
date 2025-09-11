/* eslint-disable @typescript-eslint/no-unsafe-assignment */
/* eslint-disable @typescript-eslint/no-unsafe-call */
/* eslint-disable @typescript-eslint/no-unsafe-member-access */
import { Injectable, Logger } from '@nestjs/common';
import { TelemetryService } from './telemetry.service';

@Injectable()
export class AppService {
  private readonly logger = new Logger(AppService.name);

  constructor(private readonly telemetry: TelemetryService) {}
  getHello(): string {
    const msg = 'Hello World!';
    const span = this.telemetry.tracer.startSpan('custom_operation_2');
    span.setAttribute('user.id', 123);
    span.end();
    this.telemetry.requestCounter.add(190, { route: '/hello' });
    this.logger.log('getHello called');
    return msg;
  }
}
