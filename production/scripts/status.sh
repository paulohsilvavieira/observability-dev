#!/usr/bin/env bash
set -euo pipefail

SERVICES=(otel-jaeger otel-prometheus otel-loki otel-collector otel-nginx)
CREDENTIALS_FILE="/opt/observability/configs/.credentials"

DOMAIN_JAEGER="jaeger.ptechsistemas.com"
DOMAIN_PROMETHEUS="prometheus.ptechsistemas.com"
DOMAIN_LOKI="loki.ptechsistemas.com"
DOMAIN_OTEL="otel.ptechsistemas.com"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

get_cred() {
  local section="$1" field="$2"
  if [[ -f "$CREDENTIALS_FILE" ]]; then
    awk "/^\[${section}\]/{f=1} f && /^${field}=/{sub(/^${field}=/,\"\"); print; exit}" "$CREDENTIALS_FILE"
  fi
}

check_docker() {
  local container="$1" cmd="$2"
  if docker exec "$container" sh -c "$cmd" &>/dev/null 2>&1; then
    echo -e "${GREEN}healthy${NC}"
  else
    echo -e "${RED}unreachable${NC}"
  fi
}

check_https() {
  local url="$1" user="${2:-}" pass="${3:-}"
  local args=(-sf -k --max-time 3)
  [[ -n "$user" ]] && args+=(-u "${user}:${pass}")

  if curl "${args[@]}" "$url" &>/dev/null; then
    echo -e "${GREEN}healthy${NC}"
  else
    echo -e "${RED}unreachable${NC}"
  fi
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Observability Stack — Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for service in "${SERVICES[@]}"; do
  state=$(systemctl is-active "$service" 2>/dev/null || echo "inactive")
  if   [[ "$state" == "active" ]];     then color="$GREEN"
  elif [[ "$state" == "activating" ]]; then color="$YELLOW"
  else color="$RED"; fi
  printf "  %-22s %b%s%b\n" "$service" "$color" "$state" "$NC"
done

echo ""
echo "  Health checks (internal):"
printf "  %-22s %s\n" "OTEL Collector"  "$(check_https http://localhost:13133/)"
printf "  %-22s %s\n" "Jaeger"          "$(check_docker otel-jaeger     'wget -q --spider http://localhost:16686/')"
printf "  %-22s %s\n" "Prometheus"      "$(check_docker otel-prometheus "wget -q --spider --user=$(get_cred prometheus USER) --password=$(get_cred prometheus PASSWORD) http://localhost:9090/-/healthy")"
printf "  %-22s %s\n" "Loki"            "$(check_docker otel-loki       'wget -q --spider http://localhost:3100/ready')"

echo ""
echo "  Health checks (HTTPS):"
printf "  %-22s %s\n" "jaeger.ptechsis"    "$(check_https "https://${DOMAIN_JAEGER}/"           "$(get_cred jaeger     USER)" "$(get_cred jaeger     PASSWORD)")"
printf "  %-22s %s\n" "prometheus.ptechsis" "$(check_https "https://${DOMAIN_PROMETHEUS}/-/healthy" "$(get_cred prometheus USER)" "$(get_cred prometheus PASSWORD)")"
printf "  %-22s %s\n" "loki.ptechsis"      "$(check_https "https://${DOMAIN_LOKI}/ready"         "$(get_cred loki       USER)" "$(get_cred loki       PASSWORD)")"

if [[ -f "$CREDENTIALS_FILE" ]]; then
  echo ""
  echo "  Auth: per-service credentials active"
  echo "  See:  $CREDENTIALS_FILE"
else
  echo ""
  echo -e "  ${YELLOW}Credentials file not found — setup.sh not run yet${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
