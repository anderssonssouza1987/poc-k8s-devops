#!/usr/bin/env python3
"""Bloco B: corrige a resolucao do NodePort no evidence-observability.sh."""
import pathlib
import sys

ALVO = pathlib.Path("scripts/evidence-observability.sh")

OLD = '''C1=$(curl -s -o "$DIR/ingress-healthz.json" -w '%{http_code}' \\
      --resolve "${HOST}:${NP}:127.0.0.1" "http://${HOST}:${NP}/healthz")
C2=$(curl -s -o "$DIR/ingress-root.json" -w '%{http_code}' \\
      --resolve "${HOST}:${NP}:127.0.0.1" "http://${HOST}:${NP}/")
C3=$(curl -s -o "$DIR/ingress-metrics.txt" -w '%{http_code}' \\
      --resolve "${HOST}:${NP}:127.0.0.1" "http://${HOST}:${NP}/metrics")
echo "  nodePort=${NP} host=${HOST} /healthz=${C1} /=${C2} /metrics=${C3}"
'''

NEW = '''NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | awk '{print $1}')
if [ -z "${NODE_IP:-}" ]; then
  NODE_IP=$(docker inspect poc-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
fi
[ -z "${NODE_IP:-}" ] && NODE_IP=127.0.0.1
BASE="http://${NODE_IP}:${NP}"
if ! curl -sS -m 3 -o /dev/null -H "Host: ${HOST}" "${BASE}/healthz" 2>/dev/null; then
  echo "  ${BASE} inacessivel; caindo para port-forward do controller"
  kubectl -n ingress-nginx port-forward --address 127.0.0.1 svc/ingress-nginx-controller 18080:80 >/dev/null 2>&1 &
  PIDS+=($!)
  for _ in $(seq 1 30); do
    curl -sf -o /dev/null -H "Host: ${HOST}" http://127.0.0.1:18080/healthz 2>/dev/null && break
    sleep 1
  done
  BASE="http://127.0.0.1:18080"
fi
C1=$(curl -s -o "$DIR/ingress-healthz.json" -w '%{http_code}' -H "Host: ${HOST}" "${BASE}/healthz")
C2=$(curl -s -o "$DIR/ingress-root.json" -w '%{http_code}' -H "Host: ${HOST}" "${BASE}/")
C3=$(curl -s -o "$DIR/ingress-metrics.txt" -w '%{http_code}' -H "Host: ${HOST}" "${BASE}/metrics")
echo "  base=${BASE} host=${HOST} /healthz=${C1} /=${C2} /metrics=${C3}"
'''

if not ALVO.exists():
    sys.exit(f"ERRO: {ALVO} nao encontrado")

texto = ALVO.read_text()
n = texto.count(OLD)
if n != 1:
    sys.exit(f"ERRO: esperava 1 ocorrencia, encontrou {n}")

ALVO.write_text(texto.replace(OLD, NEW))
print("  + evidence-observability.sh: resolucao de NODE_IP com fallback port-forward")
print("Concluido.")
