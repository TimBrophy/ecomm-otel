#!/bin/bash
exec > /var/log/elastic-agent-install.log 2>&1
set -euo pipefail

echo "=== Starting Elastic Agent install $(date -u) ==="
echo "Fleet URL: ${fleet_url}"

curl -L -O "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-${agent_version}-linux-x86_64.tar.gz"
tar xzf "elastic-agent-${agent_version}-linux-x86_64.tar.gz"
cd "elastic-agent-${agent_version}-linux-x86_64"

./elastic-agent install \
  --non-interactive \
  --url="${fleet_url}" \
  --enrollment-token="${enrollment_token}"

echo "=== Install complete $(date -u) ==="
