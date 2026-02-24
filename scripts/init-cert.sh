#!/usr/bin/env bash
# init-cert.sh — One-time Let's Encrypt certificate bootstrap.
#
# Run this ONCE before starting the full stack.
# After completion, HTTPS will be available on subsequent `docker compose up`.
#
# Usage:
#   cp .env.example .env && vi .env   # fill in DOMAIN and CERTBOT_EMAIL
#   bash scripts/init-cert.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(dirname "$SCRIPT_DIR")"

cd "$COMPOSE_DIR"

# Load variables from .env so DOMAIN and CERTBOT_EMAIL are available.
if [[ ! -f .env ]]; then
  echo "ERROR: .env file not found. Copy .env.example and fill in values." >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

: "${DOMAIN:?DOMAIN must be set in .env}"
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL must be set in .env}"

echo "==> Step 1: Start nginx in HTTP-only mode (needed for ACME challenge)"
ENABLE_HTTPS=false docker compose up -d nginx

echo "==> Waiting 3 s for nginx to be ready..."
sleep 3

echo "==> Step 2: Issue certificate for ${DOMAIN}"
docker compose run --rm certbot certonly \
  --webroot \
  --webroot-path /var/www/certbot \
  --email "${CERTBOT_EMAIL}" \
  --agree-tos \
  --no-eff-email \
  -d "${DOMAIN}"

echo "==> Step 3: Bring everything down, then start the full stack with HTTPS"
docker compose down

echo ""
echo "Certificate issued successfully."
echo "Run 'docker compose up -d' to start the full HTTPS stack."
echo ""
echo "Add this cron job on the host for automatic renewal:"
echo "  0 3 1,15 * * cd ${COMPOSE_DIR} && docker compose run --rm certbot renew --quiet && docker compose exec nginx nginx -s reload"
