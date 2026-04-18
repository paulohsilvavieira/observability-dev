#!/usr/bin/env bash
set -euo pipefail

SERVICES=(otel-jaeger otel-prometheus otel-loki otel-collector otel-nginx)
CREDENTIALS_FILE="/opt/observability/configs/.credentials"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Load per-service credentials if running on a production VM
get_cred() {
  local section="$1" field="$2"
  if [[ -f "$CREDENTIALS_FILE" ]]; then
    awk "/^\[${section}\]/{f=1} f && /^${field}=/{sub(/^${field}=/,\"\"); print; exit}" "$CREDENTIALS_FILE"
  fi
}

check_http() {
  local url="$1" user="${2:-}" pass="${3:-}"
  local args=(-sf --max-time 3)
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
echo "  Health checks:"
printf "  %-22s %s\n" "Jaeger UI"       "$(check_http http://localhost:16686/         "$(get_cred jaeger     USER)" "$(get_cred jaeger     PASSWORD)")"
printf "  %-22s %s\n" "Prometheus"      "$(check_http http://localhost:9090/-/healthy  "$(get_cred prometheus USER)" "$(get_cred prometheus PASSWORD)")"
printf "  %-22s %s\n" "Loki"            "$(check_http http://localhost:3100/ready      "$(get_cred loki       USER)" "$(get_cred loki       PASSWORD)")"
printf "  %-22s %s\n" "OTEL Collector"  "$(check_http http://localhost:13133/)"

if [[ -f "$CREDENTIALS_FILE" ]]; then
  echo ""
  echo "  Auth: per-service credentials active"
  echo "  See:  $CREDENTIALS_FILE"
else
  echo ""
  echo -e "  ${YELLOW}Credentials file not found — running in dev mode or setup.sh not run yet${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
