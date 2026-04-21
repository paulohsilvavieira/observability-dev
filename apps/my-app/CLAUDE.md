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

| Variable                           | Default                      | Purpose                                      |
|------------------------------------|------------------------------|----------------------------------------------|
| `NODE_ENV`                         | `development`                | Switches log format + verbosity              |
| `OTEL_EXPORTER_OTLP_ENDPOINT`      | `http://localhost:14317`     | gRPC endpoint (traces, metrics)              |
| `OTEL_EXPORTER_OTLP_HTTP_ENDPOINT` | `http://localhost:14318`     | HTTP endpoint (logs via OTel)                |
| `OTEL_EXPORTER_OTLP_HEADERS`       | —                            | Auth header — ver nota abaixo                |
| `OTEL_SERVICE_NAME`                | `my-nestjs-app`              | Resource label on all signals                |
| `PORT`                             | `3000`                       | HTTP listen port                             |

### Auth com OTEL Collector (Basic Auth)

O SDK Node.js **não propaga `OTEL_EXPORTER_OTLP_HEADERS` automaticamente para exporters gRPC**. O `src/otel.ts` faz a leitura manual e aplica:

- gRPC (traces, metrics): via `Metadata` do `@grpc/grpc-js`
- HTTP (logs): via `headers` no construtor do exporter

Formato do env:
```env
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64(user:pass)>
```

```bash
# Gerar o valor base64:
echo -n "otel:minha-senha" | base64
```

Para produção (VPS), use os endpoints com HTTPS:
```env
OTEL_EXPORTER_OTLP_ENDPOINT=https://grpc.ptechsistemas.com
OTEL_EXPORTER_OTLP_HTTP_ENDPOINT=https://otel.ptechsistemas.com
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64(user:pass)>
```

## Key source files

### `src/otel.ts` — SDK bootstrap
- Must be the **first import** in `main.ts` (via `initializeTracing()` call before `NestFactory`).
- Configures `NodeSDK` with: OTLP gRPC trace exporter, OTLP gRPC metric reader (15s interval), OTLP HTTP log exporter, `HttpInstrumentation`, `NestInstrumentation`.
- Resource attributes: `service.name`, `deployment.environment`, `host.name`, `service.version`.

### `src/logger.config.ts` — Winston logger (`LoggerConfig`)
- Extends `ConsoleLogger` so NestJS uses it as the app logger.
- Transports: `Console` (sempre ativo). Sem push direto ao Loki — logs chegam ao Loki via OTel Collector.
- Injects `traceId` / `spanId` from the active OTel span into every log entry.
- Emits each log to the OTel log SDK via `logs.getLogger('my-nestjs-app')` → Collector → Loki.
- In production, suppresses noisy NestJS bootstrap contexts (`InstanceLoader`, `RoutesResolver`, etc.).
- Log format: `nestLike` (local) / JSON with `severity` field (remote).
- `src/logger.config.direct-loki.ts` — versão antiga com push direto ao Loki, mantida como referência.

### `src/telemetry.service.ts` — injectable metrics/tracer service
- Exposes `tracer` (OTel `trace.getTracer`) and `meter` (OTel `metrics.getMeter`).
- Creates two counters on `onModuleInit`: `custom_requests_total`, `custom_errors_total`.
- Inject into any module that needs to record custom spans or metrics.

### `src/main.ts`
- Calls `initializeTracing()` before anything else.
- Passes `LoggerConfig` instance to `NestFactory.create`.
