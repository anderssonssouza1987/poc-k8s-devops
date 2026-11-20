#!/usr/bin/env bash
set -euo pipefail

NEXUS_URL="${NEXUS_URL:-http://localhost:8081}"
NEXUS_USER="${NEXUS_USER:-admin}"
NEXUS_PASS="${NEXUS_PASS:?defina NEXUS_PASS com a senha do admin}"

echo "==> criando repositorio docker-hosted na porta 5001"
curl -sS -u "$NEXUS_USER:$NEXUS_PASS" \
  -X POST "$NEXUS_URL/service/rest/v1/repositories/docker/hosted" \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "docker-hosted",
    "online": true,
    "storage": {
      "blobStoreName": "default",
      "strictContentTypeValidation": true,
      "writePolicy": "allow"
    },
    "docker": {
      "httpPort": 5001,
      "httpsPort": null,
      "forceBasicAuth": true,
      "v1Enabled": false
    }
  }' -w '\nHTTP %{http_code}\n'

echo "==> mantendo realms de autenticacao e autorizacao"
curl -sS -u "$NEXUS_USER:$NEXUS_PASS" \
  -X PUT "$NEXUS_URL/service/rest/v1/security/realms/active" \
  -H 'Content-Type: application/json' \
  -d '["NexusAuthenticatingRealm","NexusAuthorizingRealm","DockerToken"]' \
  -w '\nHTTP %{http_code}\n'

echo "==> repositorios registrados"
curl -sS -u "$NEXUS_USER:$NEXUS_PASS" \
  "$NEXUS_URL/service/rest/v1/repositories" \
  | grep -o '"name" : "[^"]*"' || true
