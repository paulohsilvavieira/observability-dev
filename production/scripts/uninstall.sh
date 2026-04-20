#!/usr/bin/env bash
set -euo pipefail

SYSTEMD_DIR="/etc/systemd/system"
INSTALL_DIR="/opt/observability"
DOCKER_NETWORK="observability-net"

SERVICES=(otel-collector otel-alertmanager otel-loki otel-prometheus otel-jaeger)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  log_error "Run as root (sudo)"
  exit 1
fi

echo -e "${YELLOW}This will stop all services, remove systemd units, and delete /opt/observability/configs.${NC}"
echo -e "${YELLOW}Data in /opt/observability/data/ will be preserved.${NC}"
read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { log_info "Aborted."; exit 0; }

log_info "Stopping and disabling services..."
for service in "${SERVICES[@]}"; do
  systemctl disable --now "$service" 2>/dev/null || true
  rm -f "$SYSTEMD_DIR/${service}.service"
  log_info "  Removed: ${service}.service"
done

systemctl daemon-reload

log_info "Removing Docker containers (if still running)..."
for container in otel-collector otel-alertmanager otel-loki otel-prometheus otel-jaeger; do
  docker rm -f "$container" 2>/dev/null || true
done

log_info "Removing Docker network..."
docker network rm "$DOCKER_NETWORK" 2>/dev/null || log_warn "Network already removed"

log_info "Removing configs and certs..."
rm -rf "$INSTALL_DIR/configs"
rm -rf "$INSTALL_DIR/certs"

log_info "Removing cert renewal cron..."
rm -f /etc/cron.d/observability-cert-renewal

log_info "Uninstall complete. Data preserved at $INSTALL_DIR/data/"
