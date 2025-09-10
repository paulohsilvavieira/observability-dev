import { Injectable, OnModuleInit } from '@nestjs/common';
import { metrics, trace } from '@opentelemetry/api';

@Injectable()
export class TelemetryService implements OnModuleInit {
  public meter = metrics.getMeter('my-nestjs-app');
  public tracer = trace.getTracer('my-nestjs-app');
  public requestCounter;
  public errorCounter;

  onModuleInit() {
    // Criação dos contadores no início do módulo
    this.requestCounter = this.meter.createCounter('custom_requests_total', {
      description: 'Contador de requisições HTTP',
    });
    this.errorCounter = this.meter.createCounter('custom_errors_total', {
      description: 'Contador de erros da aplicação',
    });

    console.log('✅ Contadores criados');
  }
}
