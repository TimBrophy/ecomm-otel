#!/bin/bash
# Bootstraps the ecomm-otel stack in "prod" mode on a fresh Amazon Linux 2023 host.
# Output: /var/log/ecomm-prod-deploy.log  (tail -f to watch, or via SSM)
exec > /var/log/ecomm-prod-deploy.log 2>&1
set -euo pipefail

echo "=== ecomm-otel prod bootstrap $(date -u) ==="

# ── Docker + git ──────────────────────────────────────────────────────────────
dnf update -y
dnf install -y docker git
systemctl enable --now docker

# Docker Compose v2 plugin (AL2023 repos don't ship it).
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
docker compose version

# ── Source ────────────────────────────────────────────────────────────────────
# Builds from a pinned git ref — the prod host is itself reproducible from Git.
git clone "${prod_repo_url}" /opt/ecomm-otel
cd /opt/ecomm-otel
git checkout "${prod_repo_ref}"

# ── Runtime config ──────────────────────────────────────────────────────────────
# Only what the collector + compose interpolation need. Docker Compose auto-loads
# ./.env for variable substitution, so AWS_REGION flows into OTEL_RESOURCE_ATTRIBUTES.
cat > /opt/ecomm-otel/.env <<'ENVEOF'
ELASTIC_INGEST_ENDPOINT=${ingest_endpoint}
ELASTIC_INGEST_API_KEY=${ingest_api_key}
AWS_REGION=${aws_region}
ENVEOF
chmod 600 /opt/ecomm-otel/.env

# ── Bring up the prod stack (with load-generator for traffic) ───────────────────
docker compose -f docker-compose.yml -f docker-compose.prod.yml --profile load up -d --build

echo "=== bootstrap complete $(date -u) ==="
docker compose -f docker-compose.yml -f docker-compose.prod.yml --profile load ps
