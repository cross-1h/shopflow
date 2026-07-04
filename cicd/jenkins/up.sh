#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v sysctl >/dev/null 2>&1; then
  # Required by SonarQube on Linux. Harmless no-op on macOS if unsupported.
  sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true
fi

docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d --build

echo "CI/CD stack is starting."
echo "Jenkins:   http://localhost:8080"
echo "SonarQube: http://localhost:9000"
echo "Nexus:     http://localhost:8081"
