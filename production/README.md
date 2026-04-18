# Production Observability Stack

This directory contains everything needed to run the observability backend in production.
Tempo and Grafana are excluded — Grafana runs separately as a managed/cloud service.

## Services

| Service | Image | Purpose |
|---|---|---|
| Jaeger | `jaegertracing/all-in-one:1.57` | Trace storage and UI |
| Prometheus | `prom/prometheus:v2.51.2` | Metrics storage |
| Loki | `grafana/loki:3.4.2` | Log storage |
| OTEL Collector | `otel/opentelemetry-collector-contrib:0.99.0` | Telemetry ingestion and routing |
| Nginx | `nginx:1.27-alpine` | Auth reverse proxy for Jaeger and Loki |

## Architecture

```
Apps (NestJS, Rails)
  └──[Basic Auth gRPC/HTTP]──► OTEL Collector :14317/:14318
                                    ├── traces  ──► Jaeger  (internal, no auth)
                                    ├── logs    ──► Loki    (internal, no auth)
                                    └── metrics ──► Prometheus scrape (internal)

Grafana / Browser
  ├──[Basic Auth]──► Nginx :16686 ──► Jaeger UI
  ├──[Basic Auth]──► Nginx :3100  ──► Loki query
  └──[Basic Auth]──► Prometheus :9090 (native auth)
```

## Directory Structure

```
production/
├── configs/
│   ├── otel-collector.yaml     # OTEL Collector pipeline + basicauth
│   ├── prometheus.yaml         # Prometheus scrape config
│   ├── prometheus-web.yaml     # Prometheus basic auth (bcrypt)
│   ├── loki.yaml               # Loki storage and retention config
│   ├── nginx.conf              # Nginx reverse proxy with basic auth
│   ├── jaeger.htpasswd         # Nginx credentials for Jaeger (APR1)
│   └── loki.htpasswd           # Nginx credentials for Loki (APR1)
├── systemd/
│   ├── otel-jaeger.service
│   ├── otel-prometheus.service
│   ├── otel-loki.service
│   ├── otel-collector.service
│   └── otel-nginx.service
├── scripts/
│   ├── setup.sh                # One-time VM setup — prompts for credentials
│   ├── status.sh               # Health check for all services
│   └── uninstall.sh            # Clean removal (preserves data)
├── docker-compose.prod.yml     # Local production simulation
└── README.md
```

---

## Prerequisites

### Hardware (minimum recommended)

| Resource | Minimum | Recommended |
|---|---|---|
| CPU | 2 vCPUs | 4 vCPUs |
| RAM | 4 GB | 8 GB |
| Disk | 40 GB | 100 GB+ |

> Prometheus and Loki are the most disk-intensive. Budget 10 GB/month for metrics and ~1–5 GB/day for logs depending on volume.

### Software

- Linux VM (Ubuntu 22.04+ or Fedora 38+)
- Docker Engine (not Docker Desktop) — installed and running
- `openssl` — for credential hashing
- `curl` — for health checks
- Root access (`sudo`)

Install Docker on Ubuntu:
```bash
curl -fsSL https://get.docker.com | sh
sudo systemctl enable --now docker
```

---

## Running Locally (Production Simulation)

Use `docker-compose.prod.yml` to test the full production setup before deploying to a VM.
Uses the same images, configs, startup order, and auth as production.

```bash
cd production

# Start all services
docker compose -f docker-compose.prod.yml up -d

# Follow all logs
docker compose -f docker-compose.prod.yml logs -f

# Follow logs for a specific service
docker compose -f docker-compose.prod.yml logs -f otel-collector

# Stop
docker compose -f docker-compose.prod.yml down

# Full reset (removes volumes and all stored data)
docker compose -f docker-compose.prod.yml down -v
```

Default credentials for local simulation:

| Field | Value |
|---|---|
| Username | `otel` |
| Password | `observability123` |

> **Never use these defaults on a real server.** `setup.sh` will prompt for new credentials during VM deployment.

### Validate local simulation

Once running, confirm all services are healthy:

```bash
# OTEL Collector health
curl -s http://localhost:13133/ | grep -i ok

# Prometheus
curl -s -u otel:observability123 http://localhost:9090/-/healthy

# Loki
curl -s -u otel:observability123 http://localhost:3100/ready

# Jaeger UI
curl -s -u otel:observability123 -o /dev/null -w "%{http_code}" http://localhost:16686/
# Expected: 200
```

---

## Deploying to a VM

Each service runs as a **systemd unit** via Docker CLI — no docker-compose on the server.
This gives independent service management, automatic restarts, and startup on boot.

### 1. Copy production files to the VM

```bash
scp -r production/ user@<vm-ip>:~/observability-production
```

Or clone the repo directly on the VM:
```bash
git clone <repo-url>
cd observability-dev
```

### 2. Run one-time setup

```bash
sudo ./production/scripts/setup.sh
```

The script will interactively:

1. Check prerequisites (`docker`, `openssl`, `curl`, `systemctl`)
2. Prompt for credentials per service (each gets an independent username/password):
   ```
   OTEL Collector  (apps send telemetry here)
     Username [otel-collector]: my-collector-user
     Password (min 8 chars): ••••••••

   Prometheus       (metrics query)
     Username [otel-prometheus]: my-prometheus-user
     ...

   Loki             (log query)
     Username [otel-loki]: my-loki-user
     ...

   Jaeger           (trace UI)
     Username [otel-jaeger]: my-jaeger-user
     ...
   ```
3. Generate **bcrypt** hashes → `otel-collector.yaml` and `prometheus-web.yaml`
4. Generate **APR1** hashes → `loki.htpasswd` and `jaeger.htpasswd` (used by Nginx)
5. Create Docker network `observability-net`
6. Create persistent data directories under `/opt/observability/data/`
7. Pull all Docker images (pinned versions)
8. Write config files to `/opt/observability/configs/` with credentials injected
9. Install and enable systemd unit files
10. Start all services in dependency order
11. Run authenticated health checks
12. Print a summary with all endpoints and credential references

### 3. Post-deployment validation

After setup, run the health check script:

```bash
./production/scripts/status.sh
```

Expected output (all green):
```
[OK] otel-jaeger     active
[OK] otel-prometheus active
[OK] otel-loki       active
[OK] otel-collector  active
[OK] otel-nginx      active

[OK] Jaeger UI        http://localhost:16686
[OK] Prometheus       http://localhost:9090
[OK] Loki             http://localhost:3100/ready
[OK] OTEL Collector   http://localhost:13133
```

---

## Managing Services

```bash
# Status of all observability services
./production/scripts/status.sh

# Systemctl (individual service control)
systemctl status  otel-jaeger
systemctl restart otel-collector
systemctl stop    otel-loki
systemctl start   otel-nginx

# Status of all at once
systemctl status otel-jaeger otel-prometheus otel-loki otel-collector otel-nginx

# Live logs via journald
journalctl -u otel-jaeger      -f
journalctl -u otel-prometheus  -f
journalctl -u otel-loki        -f
journalctl -u otel-collector   -f
journalctl -u otel-nginx       -f

# Last 100 lines + follow
journalctl -u otel-collector -n 100 -f

# Reload Prometheus config without restarting the container
curl -u <user>:<pass> -X POST http://localhost:9090/-/reload
```

### Rotating Credentials

```bash
sudo ./production/scripts/setup.sh --rotate-credentials
```

Re-prompts for all service credentials, regenerates hashes, and restarts `otel-collector`, `otel-prometheus`, and `otel-nginx` automatically. Jaeger and Loki do not need restarting (they have no native auth).

### Uninstall

```bash
sudo ./production/scripts/uninstall.sh
```

Stops and removes services, containers, configs, and the Docker network.
**Data at `/opt/observability/data/` is preserved** — remove it manually if needed:

```bash
sudo rm -rf /opt/observability/data/
```

---

## Security

### Per-Service Auth Mechanism

| Service | Mechanism | Hash Algorithm |
|---|---|---|
| OTEL Collector | `basicauthextension` (receiver-side) | bcrypt |
| Prometheus | `web.config.file` (native) | bcrypt |
| Jaeger UI | Nginx `auth_basic` reverse proxy | APR1/MD5 |
| Loki | Nginx `auth_basic` reverse proxy | APR1/MD5 |

> Jaeger and Loki have no native basic auth support, so Nginx acts as the authenticated entry point. Their direct container ports are **not exposed to the host**.

### Credential Files (VM — `/opt/observability/configs/`)

| File | Used by | Format |
|---|---|---|
| `otel-collector.yaml` | OTEL Collector (inline) | bcrypt |
| `prometheus-web.yaml` | Prometheus | bcrypt |
| `loki.htpasswd` | Nginx → Loki | APR1 |
| `jaeger.htpasswd` | Nginx → Jaeger | APR1 |
| `.credentials` | Reference (human readable) | plain, mode 600 |

---

## Connecting Apps to the Production Stack

Apps must include HTTP Basic Auth credentials in every OTLP request.

### Environment variables (recommended)

Generate the base64 token:
```bash
echo -n "your-collector-user:your-collector-password" | base64
```

Set in your app's environment:
```env
OTEL_EXPORTER_OTLP_ENDPOINT=http://<vm-ip>:14317
OTEL_EXPORTER_OTLP_HTTP_ENDPOINT=http://<vm-ip>:14318
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64-token>
```

### NestJS (`apps/my-app/.env`)

```env
NODE_ENV=production
OTEL_SERVICE_NAME=my-nestjs-app
OTEL_EXPORTER_OTLP_ENDPOINT=http://<vm-ip>:14317
OTEL_EXPORTER_OTLP_HTTP_ENDPOINT=http://<vm-ip>:14318
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64(collector-user:collector-pass)>
LOKI_HOST=http://<vm-ip>:3100
PORT=3000
```

> The NestJS app uses a direct Winston→Loki transport in addition to OTLP. If Loki is behind Nginx auth, the Loki transport must also pass credentials. Check `apps/my-app/src/logger.config.ts` for the Loki transport config.

### Rails (`apps/rails-application/.env`)

```env
OTEL_SERVICE_NAME=hike-tracker
OTEL_EXPORTER_OTLP_ENDPOINT=http://<vm-ip>:14318
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64(collector-user:collector-pass)>
LOKI_URL=http://<vm-ip>:3100
LOKI_USERNAME=<loki-user>
LOKI_PASSWORD=<loki-pass>
```

> Rails has a custom async Loki logger in `lib/loki/`. It reads `LOKI_USERNAME` and `LOKI_PASSWORD` separately — not as a base64 header.

---

## Grafana Data Source Configuration

When adding data sources in Grafana (cloud or self-hosted), use **Basic Auth** with the credentials defined during `setup.sh`:

| Data Source | Type | URL | Auth |
|---|---|---|---|
| Prometheus | Prometheus | `http://<vm-ip>:9090` | Basic Auth: prometheus-user / pass |
| Loki | Loki | `http://<vm-ip>:3100` | Basic Auth: loki-user / pass |
| Jaeger | Jaeger | `http://<vm-ip>:16686` | Basic Auth: jaeger-user / pass |

### Suggested Grafana dashboards

Import these from grafana.com (use the dashboard ID in Grafana → Dashboards → Import):

| Dashboard | ID | Purpose |
|---|---|---|
| Node Exporter Full | 1860 | Host metrics (if node_exporter added) |
| OTEL Collector | 15983 | Collector throughput and errors |
| Loki Logs | 13639 | Log volume and query patterns |

---

## Ports

| Service | Host Port | Auth | Notes |
|---|---|---|---|
| OTEL gRPC | 14317 | Basic Auth | Apps send traces and metrics here |
| OTEL HTTP | 14318 | Basic Auth | Apps send logs here |
| OTEL Health | 13133 | None | Internal health check only |
| Jaeger UI | 16686 | Nginx Basic Auth | Via Nginx proxy |
| Prometheus UI | 9090 | Native Basic Auth | Direct Prometheus auth |
| Loki HTTP | 3100 | Nginx Basic Auth | Via Nginx proxy |

---

## Data Persistence (VM)

All data survives container restarts and VM reboots:

```
/opt/observability/
├── configs/
│   ├── otel-collector.yaml     # Includes inline bcrypt credentials
│   ├── prometheus.yaml
│   ├── prometheus-web.yaml     # Includes bcrypt credentials
│   ├── loki.yaml
│   ├── nginx.conf
│   ├── loki.htpasswd           # Nginx APR1 credentials (mode 600)
│   ├── jaeger.htpasswd         # Nginx APR1 credentials (mode 600)
│   └── .credentials            # Plain-text credential reference (mode 600, root only)
└── data/
    ├── jaeger/                 # Trace data (Badger key-value store)
    ├── prometheus/             # Metrics TSDB
    └── loki/                   # Log chunks, index, and compactor state
        ├── chunks/
        ├── rules/
        └── compactor/
```

### Retention

| Backend | Retention |
|---|---|
| Prometheus | 30 days / 10 GB (whichever comes first) |
| Loki | 30 days |
| Jaeger | No limit (Badger grows indefinitely — monitor disk) |

---

## Troubleshooting

### OTEL Collector fails to start

Check if backends are up first — the collector depends on Jaeger, Loki, and Prometheus:
```bash
systemctl status otel-jaeger otel-loki otel-prometheus
journalctl -u otel-collector -n 50
```

### Apps can't connect to OTEL Collector

Test connectivity from the app host:
```bash
curl -v -u <collector-user>:<collector-pass> http://<vm-ip>:14318/
# Expected: HTTP 405 (Method Not Allowed — endpoint exists but rejects GET)
```

If you get `401 Unauthorized`, credentials are wrong.
If connection is refused, check firewall rules on the VM:
```bash
sudo ufw allow 14317/tcp
sudo ufw allow 14318/tcp
```

### Loki returns 401

The NestJS Winston transport or Rails async logger is hitting Loki directly on port 3100, which is behind Nginx. Make sure the app uses the correct username/password (not the collector credentials — Loki has its own).

### Prometheus scraping no metrics

Confirm the OTEL Collector is exposing the metrics endpoint:
```bash
curl http://localhost:9464/metrics | head -20
```

Then check the Prometheus targets page: `http://<vm-ip>:9090/targets`

### Disk running out

Jaeger has no automatic retention. Either:
- Restart the container with `docker restart otel-jaeger` (Badger will compact on restart)
- Or manually clear: `sudo rm -rf /opt/observability/data/jaeger/*` then restart

---

## Production vs Development Comparison

| Aspect | Development | Production |
|---|---|---|
| Orchestration | docker-compose | systemd + Docker CLI |
| Restart on crash | No | `Restart=always` |
| Starts with VM | No | `systemctl enable` |
| Authentication | None | Basic Auth on all services |
| Jaeger storage | In-memory (lost on restart) | Badger (persistent) |
| Loki storage | `/tmp/loki` (lost on restart) | `/opt/observability/data/loki` |
| Prometheus retention | Unlimited | 30 days / 10 GB |
| Loki retention | None | 30 days |
| Prometheus scrape interval | 1s | 15s |
| OTEL batch size | 1 message / 100ms | 1000 messages / 10s |
| OTEL debug exporter | Enabled | Removed |
| OTEL memory limiter | Disabled | 512 MiB limit |
| Image versions | `latest` | Pinned |
| Nginx proxy | Not used | Fronts Jaeger and Loki |
