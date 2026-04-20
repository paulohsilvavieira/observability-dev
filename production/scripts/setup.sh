#!/usr/bin/env bash
set -euo pipefail

# ─── constants ────────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/observability"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_NETWORK="observability-net"

DOMAIN_BASE="ptechsistemas.com"
DOMAIN_JAEGER="jaeger.${DOMAIN_BASE}"
DOMAIN_PROMETHEUS="prometheus.${DOMAIN_BASE}"
DOMAIN_LOKI="loki.${DOMAIN_BASE}"
DOMAIN_OTEL="otel.${DOMAIN_BASE}"
DOMAIN_ALERTMANAGER="alertmanager.${DOMAIN_BASE}"
DOMAIN_GRPC="grpc.${DOMAIN_BASE}"

SERVICES=(otel-jaeger otel-prometheus otel-loki otel-alertmanager otel-collector otel-nginx)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ROTATE_CREDENTIALS=false
ADD_ALERTMANAGER=false

# Per-service credentials
declare -A SVC_USER SVC_PASS SVC_BCRYPT SVC_APR1

# ─── args ─────────────────────────────────────────────────────────────────────

for arg in "$@"; do
  case $arg in
    --rotate-credentials) ROTATE_CREDENTIALS=true ;;
    --add-alertmanager)   ADD_ALERTMANAGER=true ;;
    *) echo -e "${RED}[ERROR]${NC} Unknown argument: $arg"; exit 1 ;;
  esac
done

# ─── logging ──────────────────────────────────────────────────────────────────

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" >&2; }
log_step()  { echo -e "\n${CYAN}──────────────────────────────────────────────────${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}──────────────────────────────────────────────────${NC}"; }

# ─── prerequisites ────────────────────────────────────────────────────────────

check_prerequisites() {
  log_step "Checking prerequisites"

  if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
  fi

  if ! command -v apt-get &>/dev/null; then
    log_error "This script requires a Debian/Ubuntu system (apt-get not found)"
    exit 1
  fi

  local missing=()
  command -v docker   &>/dev/null || missing+=(docker.io)
  command -v certbot  &>/dev/null || missing+=(certbot)
  command -v curl     &>/dev/null || missing+=(curl)
  command -v openssl  &>/dev/null || missing+=(openssl)

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "Installing missing packages: ${missing[*]}"
    apt-get update -qq
    apt-get install -y "${missing[@]}"
  fi

  if ! systemctl is-active --quiet docker; then
    log_info "Enabling and starting Docker..."
    systemctl enable --now docker
  fi

  if ! docker info &>/dev/null; then
    log_error "Docker daemon is not running"
    exit 1
  fi

  log_info "All prerequisites satisfied"
}

# ─── credential helpers ───────────────────────────────────────────────────────

prompt_credential() {
  local service_label="$1"
  local service_key="$2"
  local default_user="$3"

  echo ""
  echo -e "  ${CYAN}${service_label}${NC}"

  read -rp "    Username [${default_user}]: " user
  user="${user:-$default_user}"

  if [[ ! "$user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Username must contain only letters, numbers, hyphens, or underscores"
    exit 1
  fi

  local pass pass2
  while true; do
    read -rsp "    Password (min 8 chars): " pass
    echo ""

    if [[ ${#pass} -lt 8 ]]; then
      log_warn "Password must be at least 8 characters."
      continue
    fi

    read -rsp "    Confirm password: " pass2
    echo ""

    [[ "$pass" == "$pass2" ]] && break
    log_warn "Passwords do not match. Try again."
  done

  SVC_USER[$service_key]="$user"
  SVC_PASS[$service_key]="$pass"
}

generate_hashes() {
  log_info "Generating password hashes (this may take a moment)..."

  docker pull httpd:2.4-alpine -q &>/dev/null || true

  for key in collector prometheus jaeger loki alertmanager; do
    local user="${SVC_USER[$key]}"
    local pass="${SVC_PASS[$key]}"

    local bcrypt_entry
    bcrypt_entry=$(docker run --rm httpd:2.4-alpine htpasswd -nbB "$user" "$pass" 2>/dev/null)
    SVC_BCRYPT[$key]=$(echo "$bcrypt_entry" | cut -d: -f2)

    local apr1_hash
    apr1_hash=$(openssl passwd -apr1 "$pass")
    SVC_APR1[$key]="${user}:${apr1_hash}"

    log_info "  Hashes generated for: $key ($user)"
  done
}

# ─── credentials setup ────────────────────────────────────────────────────────

setup_credentials() {
  log_step "Setting up per-service credentials"

  if [[ "$ROTATE_CREDENTIALS" == "true" ]] && [[ -f "$INSTALL_DIR/configs/.credentials" ]]; then
    log_warn "Rotating credentials — current ones will be replaced after confirmation"
  fi

  echo ""
  echo "  Configure a username and password for each service."
  echo "  Press ENTER to accept the default username."
  echo ""

  prompt_credential "OTEL Collector  (apps send telemetry here)"  "collector"    "otel-collector"
  prompt_credential "Prometheus       (metrics query)"             "prometheus"   "otel-prometheus"
  prompt_credential "Loki             (log query)"                 "loki"         "otel-loki"
  prompt_credential "Jaeger           (trace UI)"                  "jaeger"       "otel-jaeger"
  prompt_credential "Alertmanager     (alert routing UI)"          "alertmanager" "otel-alertmanager"

  generate_hashes
}

# ─── TLS — Let's Encrypt ──────────────────────────────────────────────────────

setup_tls() {
  log_step "Obtaining TLS certificates (Let's Encrypt)"

  mkdir -p "$INSTALL_DIR/certs"

  local email="admin@${DOMAIN_BASE}"
  read -rp "  Email for Let's Encrypt notifications [${email}]: " input_email
  email="${input_email:-$email}"

  log_info "Running certbot for: $DOMAIN_JAEGER $DOMAIN_PROMETHEUS $DOMAIN_LOKI $DOMAIN_OTEL $DOMAIN_ALERTMANAGER $DOMAIN_GRPC"
  log_warn "DNS A records for all six subdomains must point to this server's IP before continuing."
  read -rp "  DNS is configured — proceed? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { log_error "Aborted. Set up DNS and re-run."; exit 1; }

  certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    -m "$email" \
    -d "$DOMAIN_JAEGER" \
    -d "$DOMAIN_PROMETHEUS" \
    -d "$DOMAIN_LOKI" \
    -d "$DOMAIN_OTEL" \
    -d "$DOMAIN_ALERTMANAGER" \
    -d "$DOMAIN_GRPC"

  local cert_live="/etc/letsencrypt/live/${DOMAIN_JAEGER}"
  cp "${cert_live}/fullchain.pem" "$INSTALL_DIR/certs/fullchain.pem"
  cp "${cert_live}/privkey.pem"   "$INSTALL_DIR/certs/privkey.pem"
  chmod 644 "$INSTALL_DIR/certs/fullchain.pem"
  chmod 600 "$INSTALL_DIR/certs/privkey.pem"

  setup_cert_renewal "$cert_live"

  log_info "TLS certificates installed at $INSTALL_DIR/certs/"
}

setup_cert_renewal() {
  local cert_live="$1"

  cat > /etc/cron.d/observability-cert-renewal << EOF
# Weekly Let's Encrypt renewal — stops Nginx, renews, copies certs, restarts Nginx
0 3 * * 1 root systemctl stop otel-nginx && certbot renew --quiet && cp ${cert_live}/fullchain.pem ${INSTALL_DIR}/certs/fullchain.pem && cp ${cert_live}/privkey.pem ${INSTALL_DIR}/certs/privkey.pem && chmod 600 ${INSTALL_DIR}/certs/privkey.pem && systemctl start otel-nginx
EOF
  chmod 644 /etc/cron.d/observability-cert-renewal
  log_info "Cert renewal cron installed (/etc/cron.d/observability-cert-renewal)"
}

# ─── docker network ───────────────────────────────────────────────────────────

setup_network() {
  log_step "Setting up Docker network"

  if docker network inspect "$DOCKER_NETWORK" &>/dev/null; then
    log_warn "Docker network '$DOCKER_NETWORK' already exists — skipping"
  else
    docker network create "$DOCKER_NETWORK"
    log_info "Docker network '$DOCKER_NETWORK' created"
  fi
}

# ─── directories ──────────────────────────────────────────────────────────────

setup_directories() {
  log_step "Creating data directories"

  mkdir -p \
    "$INSTALL_DIR/configs" \
    "$INSTALL_DIR/certs" \
    "$INSTALL_DIR/data/jaeger/data" \
    "$INSTALL_DIR/data/jaeger/key" \
    "$INSTALL_DIR/data/prometheus" \
    "$INSTALL_DIR/data/loki/chunks" \
    "$INSTALL_DIR/data/loki/rules" \
    "$INSTALL_DIR/data/loki/compactor" \
    "$INSTALL_DIR/data/alertmanager"

  chown -R 65534:65534 "$INSTALL_DIR/data/prometheus"
  chown -R 65534:65534 "$INSTALL_DIR/data/alertmanager"
  chown -R 10001:10001 "$INSTALL_DIR/data/loki"
  chown -R 10001:10001 "$INSTALL_DIR/data/jaeger"
  log_info "Directories ready at $INSTALL_DIR"
}

# ─── configs ──────────────────────────────────────────────────────────────────

install_configs() {
  log_step "Installing production configs"

  cp "$PRODUCTION_DIR/configs/prometheus.yaml"    "$INSTALL_DIR/configs/prometheus.yaml"
  cp "$PRODUCTION_DIR/configs/loki.yaml"          "$INSTALL_DIR/configs/loki.yaml"
  cp "$PRODUCTION_DIR/configs/nginx.conf"         "$INSTALL_DIR/configs/nginx.conf"
  cp "$PRODUCTION_DIR/configs/alertmanager.yaml"  "$INSTALL_DIR/configs/alertmanager.yaml"
  chmod 644 "$INSTALL_DIR/configs/prometheus.yaml" \
            "$INSTALL_DIR/configs/loki.yaml" \
            "$INSTALL_DIR/configs/nginx.conf" \
            "$INSTALL_DIR/configs/alertmanager.yaml"

  # OTEL Collector — bcrypt inline
  cat > "$INSTALL_DIR/configs/otel-collector.yaml" << OTELEOF
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  zpages:
    endpoint: 0.0.0.0:55679
  basicauth/otlp:
    htpasswd:
      inline: |
        ${SVC_USER[collector]}:${SVC_BCRYPT[collector]}

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
        auth:
          authenticator: basicauth/otlp
      http:
        endpoint: "0.0.0.0:4318"
        auth:
          authenticator: basicauth/otlp

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
  batch:
    send_batch_size: 1000
    send_batch_max_size: 2000
    timeout: 10s
  resource:
    attributes:
      - key: deployment.environment
        value: production
        action: upsert

exporters:
  otlp/jaeger:
    endpoint: otel-jaeger:4317
    tls:
      insecure: true
  otlphttp/loki:
    endpoint: http://otel-loki:3100/otlp
  prometheus:
    endpoint: "0.0.0.0:9464"
    namespace: otel
    resource_to_telemetry_conversion:
      enabled: true

service:
  extensions: [health_check, zpages, basicauth/otlp]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/jaeger]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/loki]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
  telemetry:
    logs:
      level: warn
    metrics:
      level: basic
OTELEOF

  # Prometheus web config — bcrypt
  cat > "$INSTALL_DIR/configs/prometheus-web.yaml" << PROMEOF
basic_auth_users:
  ${SVC_USER[prometheus]}: ${SVC_BCRYPT[prometheus]}
PROMEOF

  # Nginx htpasswd — APR1
  echo "${SVC_APR1[loki]}"         > "$INSTALL_DIR/configs/loki.htpasswd"
  echo "${SVC_APR1[jaeger]}"       > "$INSTALL_DIR/configs/jaeger.htpasswd"
  echo "${SVC_APR1[alertmanager]}" > "$INSTALL_DIR/configs/alertmanager.htpasswd"
  chmod 644 "$INSTALL_DIR/configs/loki.htpasswd" \
            "$INSTALL_DIR/configs/jaeger.htpasswd" \
            "$INSTALL_DIR/configs/alertmanager.htpasswd"

  # Credentials reference (root-only)
  local b64_collector
  b64_collector=$(echo -n "${SVC_USER[collector]}:${SVC_PASS[collector]}" | base64)

  cat > "$INSTALL_DIR/configs/.credentials" << CREDEOF
# Observability Stack Credentials
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# WARNING: Keep this file secure — do not share or commit to version control.

[collector]
OTEL_AUTH_USER=${SVC_USER[collector]}
OTEL_AUTH_PASSWORD=${SVC_PASS[collector]}
OTEL_EXPORTER_OTLP_ENDPOINT=https://${DOMAIN_GRPC}
OTEL_EXPORTER_OTLP_HTTP_ENDPOINT=https://${DOMAIN_OTEL}
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic ${b64_collector}

[prometheus]
USER=${SVC_USER[prometheus]}
PASSWORD=${SVC_PASS[prometheus]}
URL=https://${DOMAIN_PROMETHEUS}

[loki]
USER=${SVC_USER[loki]}
PASSWORD=${SVC_PASS[loki]}
URL=https://${DOMAIN_LOKI}

[jaeger]
USER=${SVC_USER[jaeger]}
PASSWORD=${SVC_PASS[jaeger]}
URL=https://${DOMAIN_JAEGER}

[alertmanager]
USER=${SVC_USER[alertmanager]}
PASSWORD=${SVC_PASS[alertmanager]}
URL=https://${DOMAIN_ALERTMANAGER}
CREDEOF
  chmod 600 "$INSTALL_DIR/configs/.credentials"

  log_info "Configs installed at $INSTALL_DIR/configs"
}

# ─── systemd units ────────────────────────────────────────────────────────────

install_systemd_units() {
  log_step "Installing systemd service units"

  for service in "${SERVICES[@]}"; do
    cp "$PRODUCTION_DIR/systemd/${service}.service" "$SYSTEMD_DIR/${service}.service"
    chmod 644 "$SYSTEMD_DIR/${service}.service"
    log_info "  Installed: ${service}.service"
  done

  systemctl daemon-reload
  log_info "systemd daemon reloaded"
}

# ─── pull images ──────────────────────────────────────────────────────────────

pull_images() {
  log_step "Pulling Docker images"

  docker pull jaegertracing/all-in-one:1.57
  docker pull prom/prometheus:v2.51.2
  docker pull prom/alertmanager:v0.27.0
  docker pull grafana/loki:3.4.2
  docker pull otel/opentelemetry-collector-contrib:0.99.0
  docker pull nginx:1.27-alpine

  log_info "All images pulled"
}

# ─── enable & start services ──────────────────────────────────────────────────

start_services() {
  log_step "Starting services"

  if [[ "$ROTATE_CREDENTIALS" == "true" ]]; then
    log_info "Restarting services to apply new credentials..."
    systemctl restart otel-collector otel-prometheus otel-alertmanager otel-nginx
    log_info "Services restarted"
    return
  fi

  for service in otel-jaeger otel-prometheus otel-loki otel-alertmanager; do
    systemctl enable --now "$service"
    log_info "  Started: $service"
  done

  systemctl enable --now otel-nginx
  log_info "  Started: otel-nginx"

  systemctl enable --now otel-collector
  log_info "  Started: otel-collector"
}

# ─── health checks ────────────────────────────────────────────────────────────

wait_healthy() {
  local name="$1" url="$2" user="${3:-}" pass="${4:-}"
  local retries=20

  log_info "Waiting for $name..."
  for _ in $(seq 1 $retries); do
    if [[ -n "$user" ]]; then
      curl -sf -u "${user}:${pass}" "$url" &>/dev/null && { log_info "  $name is healthy"; return 0; }
    else
      curl -sf "$url" &>/dev/null && { log_info "  $name is healthy"; return 0; }
    fi
    sleep 3
  done

  log_error "$name did not become healthy in time"
  return 1
}

check_health() {
  log_step "Running health checks"

  wait_healthy "OTEL Collector" "http://localhost:13133/"
  wait_healthy "Jaeger"         "http://localhost:14269/"
  wait_healthy "Prometheus"     "http://localhost:9090/-/healthy" "${SVC_USER[prometheus]}" "${SVC_PASS[prometheus]}"
  wait_healthy "Loki"           "http://localhost:3100/ready"
  wait_healthy "Alertmanager"   "http://localhost:9093/-/healthy"
}

# ─── summary ──────────────────────────────────────────────────────────────────

print_summary() {
  local b64_collector
  b64_collector=$(echo -n "${SVC_USER[collector]}:${SVC_PASS[collector]}" | base64)

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Observability Stack — Production Ready (TLS)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-14s %-44s %s\n" "Service" "URL" "Credentials"
  echo "  ─────────────────────────────────────────────────────────────"
  printf "  %-14s %-44s %s / %s\n" "Jaeger"     "https://${DOMAIN_JAEGER}"         "${SVC_USER[jaeger]}"     "${SVC_PASS[jaeger]}"
  printf "  %-14s %-44s %s / %s\n" "Prometheus" "https://${DOMAIN_PROMETHEUS}"     "${SVC_USER[prometheus]}" "${SVC_PASS[prometheus]}"
  printf "  %-14s %-44s %s / %s\n" "Loki"       "https://${DOMAIN_LOKI}"           "${SVC_USER[loki]}"       "${SVC_PASS[loki]}"
  printf "  %-14s %-44s %s / %s\n" "Alertmanager" "https://${DOMAIN_ALERTMANAGER}"   "${SVC_USER[alertmanager]}" "${SVC_PASS[alertmanager]}"
  printf "  %-14s %-44s %s / %s\n" "OTEL HTTP"  "https://${DOMAIN_OTEL}"           "${SVC_USER[collector]}"  "${SVC_PASS[collector]}"
  printf "  %-14s %-44s %s / %s\n" "OTEL gRPC"  "https://${DOMAIN_GRPC}"       "${SVC_USER[collector]}"  "${SVC_PASS[collector]}"
  echo ""
  echo "  App environment variables (.env):"
  echo "    OTEL_EXPORTER_OTLP_ENDPOINT=https://${DOMAIN_GRPC}"
  echo "    OTEL_EXPORTER_OTLP_HTTP_ENDPOINT=https://${DOMAIN_OTEL}"
  echo "    OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic ${b64_collector}"
  echo ""
  echo "  All credentials saved to: $INSTALL_DIR/configs/.credentials"
  echo "  Cert renewal cron:        /etc/cron.d/observability-cert-renewal"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Add alertmanager:    sudo ./scripts/setup.sh --add-alertmanager"
  echo "  Rotate credentials:  sudo ./scripts/setup.sh --rotate-credentials"
  echo "  Service status:      ./scripts/status.sh"
  echo "  Logs:                journalctl -u otel-collector -f"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── add alertmanager to existing installation ────────────────────────────────

add_alertmanager_to_existing() {
  log_step "Adding Alertmanager to existing installation"

  # Valida que a instalação base existe
  if [[ ! -f "$INSTALL_DIR/configs/.credentials" ]]; then
    log_error "No existing installation found at $INSTALL_DIR. Run setup.sh without --add-alertmanager first."
    exit 1
  fi

  if systemctl is-active --quiet otel-alertmanager; then
    log_warn "otel-alertmanager is already running. Use --rotate-credentials to update credentials."
    exit 0
  fi

  # Lê credenciais existentes para não reprompt de outros serviços
  log_info "Existing installation detected at $INSTALL_DIR"

  # Coleta apenas credenciais do alertmanager
  echo ""
  echo "  Configure credentials for Alertmanager."
  echo ""
  prompt_credential "Alertmanager (alert routing UI)" "alertmanager" "otel-alertmanager"

  # Gera hashes apenas para o alertmanager
  log_info "Generating password hashes..."
  docker pull httpd:2.4-alpine -q &>/dev/null || true
  local bcrypt_entry
  bcrypt_entry=$(docker run --rm httpd:2.4-alpine htpasswd -nbB "${SVC_USER[alertmanager]}" "${SVC_PASS[alertmanager]}" 2>/dev/null)
  SVC_BCRYPT[alertmanager]=$(echo "$bcrypt_entry" | cut -d: -f2)
  local apr1_hash
  apr1_hash=$(openssl passwd -apr1 "${SVC_PASS[alertmanager]}")
  SVC_APR1[alertmanager]="${SVC_USER[alertmanager]}:${apr1_hash}"

  # Cria diretório de dados
  mkdir -p "$INSTALL_DIR/data/alertmanager"
  chown -R 65534:65534 "$INSTALL_DIR/data/alertmanager"

  # Instala configs
  cp "$PRODUCTION_DIR/configs/alertmanager.yaml" "$INSTALL_DIR/configs/alertmanager.yaml"
  chmod 644 "$INSTALL_DIR/configs/alertmanager.yaml"
  echo "${SVC_APR1[alertmanager]}" > "$INSTALL_DIR/configs/alertmanager.htpasswd"
  chmod 644 "$INSTALL_DIR/configs/alertmanager.htpasswd"

  # Adiciona credenciais ao arquivo existente (se ainda não estiver lá)
  if ! grep -q '^\[alertmanager\]' "$INSTALL_DIR/configs/.credentials" 2>/dev/null; then
    cat >> "$INSTALL_DIR/configs/.credentials" << CREDEOF

[alertmanager]
USER=${SVC_USER[alertmanager]}
PASSWORD=${SVC_PASS[alertmanager]}
URL=https://${DOMAIN_ALERTMANAGER}
CREDEOF
    log_info "Credentials appended to $INSTALL_DIR/configs/.credentials"
  fi

  # Expande o certificado Let's Encrypt para incluir o novo subdomínio
  log_info "Expanding TLS certificate to include $DOMAIN_ALERTMANAGER..."
  local cert_live="/etc/letsencrypt/live/${DOMAIN_JAEGER}"
  if [[ -d "$cert_live" ]]; then
    systemctl stop otel-nginx 2>/dev/null || true
    certbot certonly \
      --standalone \
      --non-interactive \
      --agree-tos \
      --expand \
      -d "$DOMAIN_JAEGER" \
      -d "$DOMAIN_PROMETHEUS" \
      -d "$DOMAIN_LOKI" \
      -d "$DOMAIN_OTEL" \
      -d "$DOMAIN_ALERTMANAGER" \
      -d "$DOMAIN_GRPC"
    cp "${cert_live}/fullchain.pem" "$INSTALL_DIR/certs/fullchain.pem"
    cp "${cert_live}/privkey.pem"   "$INSTALL_DIR/certs/privkey.pem"
    chmod 644 "$INSTALL_DIR/certs/fullchain.pem"
    chmod 600 "$INSTALL_DIR/certs/privkey.pem"
  else
    log_warn "Let's Encrypt cert not found — skipping cert expansion. Add $DOMAIN_ALERTMANAGER manually if needed."
  fi

  # Atualiza nginx.conf e htpasswd no lugar
  cp "$PRODUCTION_DIR/configs/nginx.conf" "$INSTALL_DIR/configs/nginx.conf"

  # Pull e instala systemd unit
  docker pull prom/alertmanager:v0.27.0
  cp "$PRODUCTION_DIR/systemd/otel-alertmanager.service" "$SYSTEMD_DIR/otel-alertmanager.service"
  chmod 644 "$SYSTEMD_DIR/otel-alertmanager.service"
  systemctl daemon-reload

  # Inicia serviços
  systemctl enable --now otel-alertmanager
  log_info "  Started: otel-alertmanager"

  systemctl restart otel-nginx
  log_info "  Restarted: otel-nginx (new alertmanager server block active)"

  # Health check
  wait_healthy "Alertmanager" "http://localhost:9093/-/healthy"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Alertmanager added successfully"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-14s %-44s %s / %s\n" "Alertmanager" "https://${DOMAIN_ALERTMANAGER}" "${SVC_USER[alertmanager]}" "${SVC_PASS[alertmanager]}"
  echo ""
  echo "  Grafana datasource URL (Grafana no host): http://localhost:9093"
  echo "  Grafana datasource URL (Grafana em Docker na mesma rede): http://otel-alertmanager:9093"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${GREEN}  Observability Stack — Production Setup${NC}"
  echo ""

  check_prerequisites

  if [[ "$ADD_ALERTMANAGER" == "true" ]]; then
    add_alertmanager_to_existing
    return
  fi

  setup_credentials

  if [[ "$ROTATE_CREDENTIALS" == "true" ]]; then
    install_configs
    start_services
    print_summary
    log_info "Credentials rotated successfully."
    return
  fi

  setup_network
  setup_directories
  pull_images
  install_configs
  install_systemd_units
  setup_tls
  start_services
  check_health
  print_summary

  log_info "Setup complete."
}

main "$@"
