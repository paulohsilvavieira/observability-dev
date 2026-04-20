# CLAUDE.md

Observability learning environment: two instrumented apps (NestJS + Rails) backed by OTel Collector, Jaeger, Prometheus, Loki, Tempo, and Grafana.

## Start the dev stack

```bash
# From repo root — starts all backend services
docker-compose up -d
```

NestJS app → see `apps/my-app/CLAUDE.md`  
Rails app → see `apps/rails-application/CLAUDE.md`  
Production setup → see `production/CLAUDE.md`

## Data flow

```
NestJS (OTLP gRPC → :14317)  ─┐
                               ├─→  OTEL Collector ─→ Jaeger        (traces)
Rails  (OTLP HTTP → :14318)  ─┘                    ─→ Loki          (logs)
                                                    ─→ Prometheus    (metrics)
                                                    ─→ Tempo         (traces, alt)
                                                    ↓
                                                 Grafana (visualizes all)

Prometheus ─→ Alertmanager (alert routing → email/Slack/webhook)
```

## Key ports

| Service         | Port        | Purpose                    |
|-----------------|-------------|----------------------------|
| Grafana         | 3400        | Dashboards                 |
| Jaeger UI       | 16686       | Trace viewer               |
| Prometheus      | 9090        | Metrics explorer           |
| OTEL Collector  | 14317/14318 | App telemetry ingestion    |
| Loki            | 3100        | Log ingestion              |
| Rails app       | 3000        | HTTP                       |
| Rails PostgreSQL| 45432       | External DB port           |

## OTEL Collector pipeline (`otel/config.yaml`)

Three independent pipelines on a shared OTLP receiver (`:4317` gRPC, `:4318` HTTP):
- **traces** → batch → Jaeger + debug
- **logs** → Loki + debug
- **metrics** → Prometheus scrape endpoint on `:9464` + debug
