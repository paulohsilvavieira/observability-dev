/* eslint-disable @typescript-eslint/no-unsafe-assignment */
/* eslint-disable @typescript-eslint/no-unsafe-call */
import { ConsoleLogger } from '@nestjs/common';
// eslint-disable-next-line @typescript-eslint/no-require-imports
const LokiTransport = require('winston-loki');
import * as winston from 'winston';
import * as dotenv from 'dotenv';
import { utilities as nestWinstonUtils } from 'nest-winston';
import { logs, SeverityNumber } from '@opentelemetry/api-logs';
import { trace } from '@opentelemetry/api';
dotenv.config();

const otelLogger = logs.getLogger('my-nestjs-app');

const { combine, timestamp, json } = winston.format;
const { nestLike } = nestWinstonUtils.format;

const levels: object = {
  default: 'DEFAULT',
  debug: 'DEBUG',
  info: 'INFO',
  warn: 'WARNING',
  error: 'ERROR',
};

const severity = winston.format((info) => {
  const { level } = info;
  return Object.assign({}, info, { severity: levels[level] });
});
const remoteFormat = () => combine(severity(), json());
const localFormat = () => combine(timestamp(), severity(), nestLike());
const isLocal = process.env.NODE_ENV === 'development';

export class LoggerConfig extends ConsoleLogger {
  private logger = winston.createLogger({
    level: process.env.NODE_ENV === 'development' ? 'debug' : 'info',
    format: isLocal ? localFormat() : remoteFormat(),
    transports: [
      new winston.transports.Console(),

      new LokiTransport({
        host: process.env.LOKI_HOST || 'http://127.0.0.1:3100',
        labels: {
          app: 'my-nest-log',
          environment: process.env.NODE_ENV || 'development',
        },
        json: true,
        format: winston.format.json(),
        silent: true,
      }),
    ],
  });

  constructor() {
    super();
  }
  private getTraceInfo() {
    const activeSpan = trace.getActiveSpan();
    if (activeSpan) {
      const spanContext = activeSpan.spanContext();
      return {
        traceId: spanContext.traceId,
        spanId: spanContext.spanId,
      };
    }
    return {};
  }
  enableLoki() {
    // ativa o Loki depois do bootstrap
    const lokiTransport = this.logger.transports.find(
      (t) => t instanceof LokiTransport,
    );
    if (lokiTransport) lokiTransport.silent = false;
  }

  log(message: any, context?: string) {
    if (this.shouldLog(context)) {
      const meta = { ...this.getTraceInfo(), context };
      this.logger.info(message, meta);
      otelLogger.emit({ severityNumber: SeverityNumber.INFO, body: String(message), attributes: meta });
    }
  }

  error(message: any, context?: string) {
    if (this.shouldLog(context)) {
      const meta = { ...this.getTraceInfo(), context };
      this.logger.error(message, meta);
      otelLogger.emit({ severityNumber: SeverityNumber.ERROR, body: String(message), attributes: meta });
    }
  }

  warn(message: any, context?: string) {
    if (this.shouldLog(context)) {
      const meta = { ...this.getTraceInfo(), context };
      this.logger.warn(message, meta);
      otelLogger.emit({ severityNumber: SeverityNumber.WARN, body: String(message), attributes: meta });
    }
  }

  debug(message: any, context?: string) {
    if (this.shouldLog(context)) {
      const meta = { ...this.getTraceInfo(), context };
      this.logger.debug(message, meta);
      otelLogger.emit({ severityNumber: SeverityNumber.DEBUG, body: String(message), attributes: meta });
    }
  }

  verbose(message: any, context?: string) {
    if (this.shouldLog(context)) {
      const meta = { ...this.getTraceInfo(), context };
      this.logger.verbose(message, meta);
      otelLogger.emit({ severityNumber: SeverityNumber.TRACE, body: String(message), attributes: meta });
    }
  }

  private shouldLog(context?: string): boolean {
    const isDev = process.env.NODE_ENV === 'development';

    if (isDev) {
      return true; // loga tudo em desenvolvimento
    }

    const ignoredContexts = [
      'InstanceLoader',
      'RoutesResolver',
      'RouterExplorer',
      'NestFactory',
      'NestApplication',
      'RabbitMQModule',
      'AmqpConnection',
      'ApplicationStartup',
    ];

    return !context || !ignoredContexts.includes(context);
  }
}
