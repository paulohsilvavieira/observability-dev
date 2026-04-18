# NestJS App (`apps/my-app/`)

Service name: `my-nestjs-app`. Sends traces + metrics via OTLP gRPC, logs via OTLP HTTP and directly to Loki.

## Commands

```bash
pnpm install
pnpm run start:dev      # watch mode
pnpm run build
pnpm run start:prod     # requires build first
pnpm run lint           # ESLint with auto-fix
pnpm run format         # Prettier
pnpm run test
pnpm run test:watch
pnpm run test:cov
pnpm run test:e2e
```

## Environment variables (`.env` / `.env.example`)

| Variable                          | Default                      | Purpose                         |
|-----------------------------------|------------------------------|---------------------------------|
| `NODE_ENV`                        | `development`                | Switches log format + verbosity |
| `OTEL_EXPORTER_OTLP_ENDPOINT`     | `http://localhost:14317`     | gRPC endpoint (traces, metrics) |
| `OTEL_EXPORTER_OTLP_HTTP_ENDPOINT`| `http://localhost:14318`     | HTTP endpoint (logs via OTel)   |
| `LOKI_HOST`                       | `http://127.0.0.1:3100`      | Direct Loki push (Winston)      |
| `OTEL_SERVICE_NAME`               | `my-nestjs-app`              | Resource label on all signals   |
| `PORT`                            | `3000`                       | HTTP listen port                |

## Key source files

### `src/otel.ts` — SDK bootstrap
- Must be the **first import** in `main.ts` (via `initializeTracing()` call before `NestFactory`).
- Configures `NodeSDK` with: OTLP gRPC trace exporter, OTLP gRPC metric reader (15s interval), OTLP HTTP log exporter, `HttpInstrumentation`, `NestInstrumentation`.
- Resource attributes: `service.name`, `deployment.environment`, `host.name`, `service.version`.

### `src/logger.config.ts` — Winston logger (`LoggerConfig`)
- Extends `ConsoleLogger` so NestJS uses it as the app logger.
- Two transports: `Console` (always on) + `LokiTransport` (starts `silent: true`).
- `enableLoki()` must be called after `app.listen()` in `main.ts` to activate Loki push.
- Injects `traceId` / `spanId` from the active OTel span into every log entry.
- Also emits each log to the OTel log SDK via `logs.getLogger('my-nestjs-app')`.
- In production, suppresses noisy NestJS bootstrap contexts (`InstanceLoader`, `RoutesResolver`, etc.).
- Log format: `nestLike` (local) / JSON with `severity` field (remote).

### `src/telemetry.service.ts` — injectable metrics/tracer service
- Exposes `tracer` (OTel `trace.getTracer`) and `meter` (OTel `metrics.getMeter`).
- Creates two counters on `onModuleInit`: `custom_requests_total`, `custom_errors_total`.
- Inject into any module that needs to record custom spans or metrics.

### `src/main.ts`
- Calls `initializeTracing()` before anything else.
- Passes `LoggerConfig` instance to `NestFactory.create`.
- Calls `logger.enableLoki()` after `app.listen()`.
