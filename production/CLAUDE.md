# Production Stack (`production/`)

Runs Jaeger, Prometheus, Loki, Alertmanager, OTEL Collector, and Nginx as systemd units via Docker CLI — no docker-compose on the server. Grafana runs em servidor separado.

Nginx handles TLS termination for all external traffic. Each service is accessible via a subdomain of `ptechsistemas.com`. Services do **not** expose ports directly to the host — only Nginx and OTEL Collector health do.

## Local simulation

```bash
cd production
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml logs -f
docker compose -f docker-compose.prod.yml down
docker compose -f docker-compose.prod.yml down -v   # full reset, removes volumes
```

Default credentials for local sim: user `otel` / password `observability123`. Never use on a real server.
Note: docker-compose.prod.yml does not have TLS — it is for local testing only.

## VM deployment — prerequisites

`setup.sh` installs missing packages (`docker.io`, `certbot`, `curl`, `openssl`) automatically via `apt-get`. Requires Ubuntu/Debian.

DNS A records required before running setup (all pointing to the VPS IP):

| Subdomain                            | Purpose                        |
|--------------------------------------|--------------------------------|
| `jaeger.ptechsistemas.com`           | Jaeger UI                      |
| `prometheus.ptechsistemas.com`       | Prometheus                     |
| `loki.ptechsistemas.com`             | Loki                           |
| `otel.ptechsistemas.com`             | OTEL Collector HTTP (OTLP/HTTP)|
| `grpc.ptechsistemas.com`             | OTEL Collector gRPC (OTLP/gRPC)|
| `alertmanager.ptechsistemas.com`     | Alertmanager UI                |

## VM deployment

```bash
# One-time setup — prompts for credentials + email for Let's Encrypt
sudo ./production/scripts/setup.sh

# Adicionar Alertmanager a uma instalação existente (sem reinstalar tudo)
sudo ./production/scripts/setup.sh --add-alertmanager

# Migrar portas para apenas 80/443 (move gRPC 14317→443, remove 9093)
# Requer DNS A record: grpc.ptechsistemas.com → IP do VPS
sudo ./production/scripts/setup.sh --migrate-ports

# Health check
./production/scripts/status.sh

# Rotate all credentials and restart affected services
sudo ./production/scripts/setup.sh --rotate-credentials

# Uninstall (data at /opt/observability/data/ is preserved)
sudo ./production/scripts/uninstall.sh
```

`setup.sh` does: checks prereqs → prompts credentials → generates bcrypt/APR1 hashes → creates Docker network + data dirs → pulls images → writes configs → installs + enables systemd units → runs certbot (Let's Encrypt) → starts services → health checks.

`--add-alertmanager`: detecta instalação existente, coleta só credenciais do Alertmanager, expande o certificado Let's Encrypt com `--expand`, instala o novo systemd unit e reinicia apenas o Nginx.

`--migrate-ports`: remove portas 14317 e 9093 do host, move gRPC para `grpc.ptechsistemas.com:443`, expande o certificado e reinicia Nginx + Alertmanager.

## Systemd service management

```bash
systemctl status  otel-jaeger | otel-prometheus | otel-loki | otel-alertmanager | otel-collector | otel-nginx
systemctl restart otel-collector
journalctl -u otel-jaeger -f

# Reload Prometheus config without restart
curl -u user:pass -X POST https://prometheus.ptechsistemas.com/-/reload

# Reload Alertmanager config without restart
curl -X POST https://alertmanager.ptechsistemas.com/-/reload
```

## Security model

All external access goes through Nginx with TLS. Internal collector → backend communication is plain HTTP on the private Docker network.

| Service        | TLS        | Auth mechanism                     | Hash    |
|----------------|------------|------------------------------------|---------|
| OTEL Collector | Nginx      | `basicauthextension` (receiver)    | bcrypt  |
| Prometheus     | Nginx      | `web.config.file` (native)         | bcrypt  |
| Jaeger UI      | Nginx      | Nginx `auth_basic` reverse proxy   | APR1    |
| Loki           | Nginx      | Nginx `auth_basic` reverse proxy   | APR1    |
| Alertmanager   | Nginx      | Nginx `auth_basic` reverse proxy   | APR1    |

Portas expostas no host: `13133` (OTEL Collector health) e `9093` (Alertmanager — acessível em `localhost:9093` para o Grafana no servidor externo configurar como datasource).

## TLS certificate management

Certificates are issued by Let's Encrypt via certbot (standalone mode) and stored at `/opt/observability/certs/`.

```bash
# Manual renewal (normally handled by cron)
systemctl stop otel-nginx
certbot renew
cp /etc/letsencrypt/live/jaeger.ptechsistemas.com/fullchain.pem /opt/observability/certs/
cp /etc/letsencrypt/live/jaeger.ptechsistemas.com/privkey.pem   /opt/observability/certs/
chmod 600 /opt/observability/certs/privkey.pem
systemctl start otel-nginx
```

Automatic renewal cron: `/etc/cron.d/observability-cert-renewal` (runs every Monday at 03:00).

## Credential files (VM — `/opt/observability/configs/`)

| File                      | Used by              | Format              |
|---------------------------|----------------------|---------------------|
| `otel-collector.yaml`     | OTEL Collector       | bcrypt (inline)     |
| `prometheus-web.yaml`     | Prometheus           | bcrypt              |
| `loki.htpasswd`           | Nginx → Loki         | APR1                |
| `jaeger.htpasswd`         | Nginx → Jaeger       | APR1                |
| `alertmanager.htpasswd`   | Nginx → Alertmanager | APR1                |
| `alertmanager.yaml`       | Alertmanager         | plain (sem hash)    |
| `.credentials`            | Human reference only | plain, mode 600     |

## Connecting apps to the production stack

```env
# gRPC (preferencial)
OTEL_EXPORTER_OTLP_ENDPOINT=https://grpc.ptechsistemas.com
# HTTP (alternativa)
OTEL_EXPORTER_OTLP_HTTP_ENDPOINT=https://otel.ptechsistemas.com
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64(user:pass)>
```

```bash
echo -n "your-user:your-password" | base64
```

## Ports

| Service        | Port  | Protocol     | Auth required          |
|----------------|-------|--------------|------------------------|
| Nginx HTTPS    | 443   | HTTPS        | per subdomain          |
| Nginx HTTP     | 80    | HTTP         | redirect to HTTPS      |
| OTEL Health    | 13133 | HTTP         | localhost only         |

Todas as UIs e endpoints (Jaeger, Prometheus, Loki, Alertmanager, OTEL HTTP, OTEL gRPC) estão na porta 443 via subdomínio.

## Key differences from dev

| Aspect              | Dev                       | Production                          |
|---------------------|---------------------------|-------------------------------------|
| Orchestration       | docker-compose            | systemd + Docker CLI                |
| TLS                 | None                      | Let's Encrypt via Nginx             |
| Subdomains          | None (IP:port)            | `*.ptechsistemas.com`               |
| Auth                | None                      | Basic Auth on all services          |
| Jaeger storage      | In-memory                 | Badger (persistent)                 |
| Loki/Prometheus data| /tmp or unnamed volumes   | `/opt/observability/data/` (named)  |
| Retention           | Unlimited                 | 30 days / 10 GB (Prometheus)        |
| OTEL batch          | 1 msg / 100ms             | 1000 msgs / 10s                     |
| Debug exporter      | Enabled                   | Removed                             |
| Image versions      | latest                    | Pinned                              |
