/* eslint-disable @typescript-eslint/no-misused-promises */
import * as dotenv from 'dotenv';
import * as os from 'os';
import { Metadata } from '@grpc/grpc-js';
import { diag, DiagConsoleLogger, DiagLogLevel } from '@opentelemetry/api';
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-grpc';
import { OTLPMetricExporter } from '@opentelemetry/exporter-metrics-otlp-grpc';
import { OTLPLogExporter } from '@opentelemetry/exporter-logs-otlp-http';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { NestInstrumentation } from '@opentelemetry/instrumentation-nestjs-core';
import { PeriodicExportingMetricReader } from '@opentelemetry/sdk-metrics';
import { BatchLogRecordProcessor } from '@opentelemetry/sdk-logs';
import { resourceFromAttributes } from '@opentelemetry/resources';
import {
  ATTR_SERVICE_NAME,
  SemanticResourceAttributes,
} from '@opentelemetry/semantic-conventions';

dotenv.config();

const isDev = process.env.NODE_ENV !== 'production';
diag.setLogger(new DiagConsoleLogger(), isDev ? DiagLogLevel.INFO : DiagLogLevel.ERROR);

const OTEL_GRPC_ENDPOINT = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://localhost:14317';
const OTEL_HTTP_ENDPOINT = process.env.OTEL_EXPORTER_OTLP_HTTP_ENDPOINT || 'http://localhost:14318';

// O SDK Node.js não propaga OTEL_EXPORTER_OTLP_HEADERS para exporters gRPC automaticamente.
// Lemos o env manualmente e aplicamos: gRPC → Metadata (@grpc/grpc-js), HTTP → headers object.
const rawHeaders = process.env.OTEL_EXPORTER_OTLP_HEADERS || '';

const grpcMetadata = new Metadata();
const httpHeaders: Record<string, string> = {};

if (rawHeaders) {
  rawHeaders.split(',').forEach((pair) => {
    const idx = pair.indexOf('=');
    if (idx === -1) return;
    const key = pair.slice(0, idx).trim();
    const value = pair.slice(idx + 1).trim();
    grpcMetadata.set(key.toLowerCase(), value);
    httpHeaders[key] = value;
  });
}

const resource = resourceFromAttributes({
  [ATTR_SERVICE_NAME]: process.env.OTEL_SERVICE_NAME || 'my-nestjs-app',
  [SemanticResourceAttributes.DEPLOYMENT_ENVIRONMENT]: process.env.NODE_ENV || 'development',
  'host.name': os.hostname(),
  'service.version': process.env.npm_package_version || '0.0.1',
});

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter({
    url: OTEL_GRPC_ENDPOINT,
    metadata: grpcMetadata,
  }),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter({
      url: OTEL_GRPC_ENDPOINT,
      metadata: grpcMetadata,
    }),
    exportIntervalMillis: 15_000,
  }),
  logRecordProcessor: new BatchLogRecordProcessor(
    new OTLPLogExporter({
      url: `${OTEL_HTTP_ENDPOINT}/v1/logs`,
      headers: httpHeaders,
    }),
  ),
  resource,
  instrumentations: [new HttpInstrumentation(), new NestInstrumentation()],
});

process.on('beforeExit', async () => {
  await sdk.shutdown();
});

export const initializeTracing = () => {
  sdk.start();
};
