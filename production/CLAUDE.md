# Production Stack (`production/`)

Runs Jaeger, Prometheus, Loki, OTEL Collector, and Nginx as systemd units via Docker CLI — no docker-compose on the server. Grafana is external (managed/cloud).

## Local simulation

```bash
cd production
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml logs -f
docker compose -f docker-compose.prod.yml down
docker compose -f docker-compose.prod.yml down -v   # full reset, removes volumes
```

Default credentials for local sim: user `otel` / password `observability123`. Never use on a real server.

## VM deployment

```bash
# One-time setup (prompts for credentials per service)
sudo ./production/scripts/setup.sh

# Health check
./production/scripts/status.sh

# Rotate all credentials and restart affected services
sudo ./production/scripts/setup.sh --rotate-credentials

# Uninstall (data at /opt/observability/data/ is preserved)
sudo ./production/scripts/uninstall.sh
```

`setup.sh` does: checks prereqs → prompts credentials → generates bcrypt/APR1 hashes → creates Docker network + data dirs → pulls images → writes configs → installs + enables systemd units → starts services → health checks.

## Systemd service management

```bash
systemctl status  otel-jaeger | otel-prometheus | otel-loki | otel-collector | otel-nginx
systemctl restart otel-collector
journalctl -u otel-jaeger -f

# Reload Prometheus config without restart
curl -u user:pass -X POST http://localhost:9090/-/reload
```

## Security model

External access requires auth. Internal collector → backend is on the private Docker network (no auth).

| Service        | Auth mechanism                     | Hash    |
|----------------|------------------------------------|---------|
| OTEL Collector | `basicauthextension` (receiver)    | bcrypt  |
| Prometheus     | `web.config.file` (native)         | bcrypt  |
| Jaeger UI      | Nginx `auth_basic` reverse proxy   | APR1    |
| Loki           | Nginx `auth_basic` reverse proxy   | APR1    |

Jaeger and Loki have no native basic auth — Nginx fronts them. Their direct container ports are not exposed to the host.

## Credential files (VM — `/opt/observability/configs/`)

| File                  | Used by              | Format              |
|-----------------------|----------------------|---------------------|
| `otel-collector.yaml` | OTEL Collector       | bcrypt (inline)     |
| `prometheus-web.yaml` | Prometheus           | bcrypt              |
| `loki.htpasswd`       | Nginx → Loki         | APR1                |
| `jaeger.htpasswd`     | Nginx → Jaeger       | APR1                |
| `.credentials`        | Human reference only | plain, mode 600     |

## Connecting apps to the production stack

```env
OTEL_EXPORTER_OTLP_ENDPOINT=http://<vm-ip>:14317
OTEL_EXPORTER_OTLP_HTTP_ENDPOINT=http://<vm-ip>:14318
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64(user:pass)>
```

```bash
echo -n "your-user:your-password" | base64
```

## Ports

| Service        | Port  | Auth required          |
|----------------|-------|------------------------|
| OTEL gRPC      | 14317 | Basic Auth             |
| OTEL HTTP      | 14318 | Basic Auth             |
| Jaeger UI      | 16686 | Nginx Basic Auth       |
| Prometheus UI  | 9090  | Native Basic Auth      |
| Loki HTTP      | 3100  | Nginx Basic Auth       |
| OTEL Health    | 13133 | Internal only          |

## Key differences from dev

| Aspect              | Dev                       | Production                          |
|---------------------|---------------------------|-------------------------------------|
| Orchestration       | docker-compose            | systemd + Docker CLI                |
| Auth                | None                      | Basic Auth on all services          |
| Jaeger storage      | In-memory                 | Badger (persistent)                 |
| Loki/Prometheus data| /tmp or unnamed volumes   | `/opt/observability/data/` (named)  |
| Retention           | Unlimited                 | 30 days / 10 GB (Prometheus)        |
| OTEL batch          | 1 msg / 100ms             | 1000 msgs / 10s                     |
| Debug exporter      | Enabled                   | Removed                             |
| Image versions      | latest                    | Pinned                              |
