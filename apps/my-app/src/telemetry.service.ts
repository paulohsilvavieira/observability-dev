import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { metrics, trace } from '@opentelemetry/api';

@Injectable()
export class TelemetryService implements OnModuleInit {
  public logger = new Logger(TelemetryService.name);
  public meter = metrics.getMeter('my-nestjs-app');
  public tracer = trace.getTracer('my-nestjs-app');
  public requestCounter;
  public errorCounter;

  onModuleInit() {
    this.requestCounter = this.meter.createCounter('custom_requests_total', {
      description: 'Contador de requisições HTTP',
    });
    this.errorCounter = this.meter.createCounter('custom_errors_total', {
      description: 'Contador de erros da aplicação',
    });

    this.logger.log('✅ Contadores criados');
  }
}
