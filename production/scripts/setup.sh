#!/usr/bin/env bash
set -euo pipefail

# ─── constants ────────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/observability"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCTION_DIR="$(dirname "$SCRIPT_DIR")"
DOCKER_NETWORK="observability-net"

SERVICES=(otel-jaeger otel-prometheus otel-loki otel-collector otel-nginx)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ROTATE_CREDENTIALS=false

# Per-service credentials
declare -A SVC_USER SVC_PASS SVC_BCRYPT SVC_APR1

# ─── args ─────────────────────────────────────────────────────────────────────

for arg in "$@"; do
  case $arg in
    --rotate-credentials) ROTATE_CREDENTIALS=true ;;
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

  for cmd in docker curl systemctl openssl; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command not found: $cmd"
      exit 1
    fi
  done

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

  # Pull httpd image once for bcrypt generation
  docker pull httpd:2.4-alpine -q &>/dev/null || true

  for key in collector prometheus jaeger loki; do
    local user="${SVC_USER[$key]}"
    local pass="${SVC_PASS[$key]}"

    # bcrypt (for OTEL Collector and Prometheus)
    local bcrypt_entry
    bcrypt_entry=$(docker run --rm httpd:2.4-alpine htpasswd -nbB "$user" "$pass" 2>/dev/null)
    SVC_BCRYPT[$key]=$(echo "$bcrypt_entry" | cut -d: -f2)

    # APR1 (for Nginx htpasswd)
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

  prompt_credential "OTEL Collector  (apps send telemetry here)"  "collector"  "otel-collector"
  prompt_credential "Prometheus       (metrics query)"             "prometheus" "otel-prometheus"
  prompt_credential "Loki             (log query)"                 "loki"       "otel-loki"
  prompt_credential "Jaeger           (trace UI)"                  "jaeger"     "otel-jaeger"

  generate_hashes
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
    "$INSTALL_DIR/data/jaeger/data" \
    "$INSTALL_DIR/data/jaeger/key" \
    "$INSTALL_DIR/data/prometheus" \
    "$INSTALL_DIR/data/loki/chunks" \
    "$INSTALL_DIR/data/loki/rules" \
    "$INSTALL_DIR/data/loki/compactor"

  chown -R 10001:10001 "$INSTALL_DIR/data/loki"
  log_info "Directories ready at $INSTALL_DIR"
}

# ─── configs ──────────────────────────────────────────────────────────────────

install_configs() {
  log_step "Installing production configs"

  # Static configs
  cp "$PRODUCTION_DIR/configs/prometheus.yaml" "$INSTALL_DIR/configs/prometheus.yaml"
  cp "$PRODUCTION_DIR/configs/loki.yaml"       "$INSTALL_DIR/configs/loki.yaml"
  cp "$PRODUCTION_DIR/configs/nginx.conf"      "$INSTALL_DIR/configs/nginx.conf"
  chmod 644 "$INSTALL_DIR/configs/prometheus.yaml" \
            "$INSTALL_DIR/configs/loki.yaml" \
            "$INSTALL_DIR/configs/nginx.conf"

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

  # Nginx htpasswd — APR1, separate file per service
  echo "${SVC_APR1[loki]}"   > "$INSTALL_DIR/configs/loki.htpasswd"
  echo "${SVC_APR1[jaeger]}" > "$INSTALL_DIR/configs/jaeger.htpasswd"
  chmod 600 "$INSTALL_DIR/configs/loki.htpasswd" \
            "$INSTALL_DIR/configs/jaeger.htpasswd"

  # Credentials reference (root-only)
  local vm_ip
  vm_ip=$(hostname -I | awk '{print $1}')
  cat > "$INSTALL_DIR/configs/.credentials" << CREDEOF
# Observability Stack Credentials
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# WARNING: Keep this file secure — do not share or commit to version control.

[collector]
OTEL_AUTH_USER=${SVC_USER[collector]}
OTEL_AUTH_PASSWORD=${SVC_PASS[collector]}
OTEL_EXPORTER_OTLP_ENDPOINT=http://${vm_ip}:14317
OTEL_EXPORTER_OTLP_HTTP_ENDPOINT=http://${vm_ip}:14318
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic $(echo -n "${SVC_USER[collector]}:${SVC_PASS[collector]}" | base64)

[prometheus]
USER=${SVC_USER[prometheus]}
PASSWORD=${SVC_PASS[prometheus]}
URL=http://${vm_ip}:9090

[loki]
USER=${SVC_USER[loki]}
PASSWORD=${SVC_PASS[loki]}
URL=http://${vm_ip}:3100

[jaeger]
USER=${SVC_USER[jaeger]}
PASSWORD=${SVC_PASS[jaeger]}
URL=http://${vm_ip}:16686
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
    systemctl restart otel-collector otel-prometheus otel-nginx
    log_info "Services restarted"
    return
  fi

  for service in otel-jaeger otel-prometheus otel-loki; do
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

  wait_healthy "Jaeger"         "http://localhost:16686/"         "${SVC_USER[jaeger]}"     "${SVC_PASS[jaeger]}"
  wait_healthy "Prometheus"     "http://localhost:9090/-/healthy" "${SVC_USER[prometheus]}" "${SVC_PASS[prometheus]}"
  wait_healthy "Loki"           "http://localhost:3100/ready"     "${SVC_USER[loki]}"       "${SVC_PASS[loki]}"
  wait_healthy "OTEL Collector" "http://localhost:13133/"
}

# ─── summary ──────────────────────────────────────────────────────────────────

print_summary() {
  local vm_ip
  vm_ip=$(hostname -I | awk '{print $1}')
  local b64_collector
  b64_collector=$(echo -n "${SVC_USER[collector]}:${SVC_PASS[collector]}" | base64)

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Observability Stack — Production Ready"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %-14s %-32s %s\n" "Service" "URL" "Credentials"
  echo "  ─────────────────────────────────────────────────────────────"
  printf "  %-14s %-32s %s / %s\n" "Jaeger"     "http://${vm_ip}:16686" "${SVC_USER[jaeger]}"     "${SVC_PASS[jaeger]}"
  printf "  %-14s %-32s %s / %s\n" "Prometheus" "http://${vm_ip}:9090"  "${SVC_USER[prometheus]}" "${SVC_PASS[prometheus]}"
  printf "  %-14s %-32s %s / %s\n" "Loki"       "http://${vm_ip}:3100"  "${SVC_USER[loki]}"       "${SVC_PASS[loki]}"
  printf "  %-14s %-32s %s / %s\n" "OTEL gRPC"  "${vm_ip}:14317"        "${SVC_USER[collector]}"  "${SVC_PASS[collector]}"
  printf "  %-14s %-32s %s / %s\n" "OTEL HTTP"  "http://${vm_ip}:14318" "${SVC_USER[collector]}"  "${SVC_PASS[collector]}"
  echo ""
  echo "  App environment variables (.env):"
  echo "    OTEL_EXPORTER_OTLP_ENDPOINT=http://${vm_ip}:14317"
  echo "    OTEL_EXPORTER_OTLP_HTTP_ENDPOINT=http://${vm_ip}:14318"
  echo "    OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic ${b64_collector}"
  echo ""
  echo "  All credentials saved to: $INSTALL_DIR/configs/.credentials"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Rotate credentials:  sudo ./scripts/setup.sh --rotate-credentials"
  echo "  Service status:      ./scripts/status.sh"
  echo "  Logs:                journalctl -u otel-collector -f"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${GREEN}  Observability Stack — Production Setup${NC}"
  echo ""

  check_prerequisites
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
  start_services
  check_health
  print_summary

  log_info "Setup complete."
}

main "$@"
