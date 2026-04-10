/* eslint-disable @typescript-eslint/no-misused-promises */
import * as dotenv from 'dotenv';
import { diag, DiagConsoleLogger, DiagLogLevel } from '@opentelemetry/api';
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-grpc';

import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { NestInstrumentation } from '@opentelemetry/instrumentation-nestjs-core';
import { PeriodicExportingMetricReader } from '@opentelemetry/sdk-metrics';
import { resourceFromAttributes } from '@opentelemetry/resources';
import {
  ATTR_SERVICE_NAME,
  SemanticResourceAttributes,
} from '@opentelemetry/semantic-conventions';

dotenv.config();
diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.ERROR);
const OTEL_ENDPOINT = 'http://127.0.0.1:14317';

const resource = resourceFromAttributes({
  [ATTR_SERVICE_NAME]: 'my-nestjs-app',
  [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: 'development', // ou 'production'
});
const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter({
    url: OTEL_ENDPOINT,
  }),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter({
      url: OTEL_ENDPOINT,
    }),
    exportIntervalMillis: 100, // exporta a cada 1s
  }),
  resource,
  instrumentations: [new HttpInstrumentation(), new NestInstrumentation()],
});

process.on('beforeExit', async () => {
  await sdk.shutdown();
});

export const initalizeTracing = () => {
  sdk.start();
};
