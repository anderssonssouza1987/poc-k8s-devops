#!/usr/bin/env bash
# Coleta as tres evidencias pendentes: Ingress por host, target no Prometheus, logs no Loki.
set -uo pipefail

NS_APP="${NS_APP:-poc-k8s}"
NS_OBS="${NS_OBS:-observability}"
HOST="${HOST:-poc-k8s.local}"
OUT="${OUT:-docs/evidence}"
DIR="${OUT}/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIR"

PASS=0
FAIL=0
ok()  { printf '  [OK]    %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  [FALHA] %s\n' "$*"; FAIL=$((FAIL + 1)); }

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

wait_http() {
  local url="$1" tentativas="${2:-30}"
  for _ in $(seq 1 "$tentativas"); do
    curl -sf -o /dev/null "$url" && return 0
    sleep 1
  done
  return 1
}

echo "== 1. Ingress por hostname =="
NP=$(kubectl get svc -A -o jsonpath='{range .items[?(@.metadata.name=="ingress-nginx-controller")]}{.spec.ports[?(@.name=="http")].nodePort}{end}' 2>/dev/null)
if [ -z "${NP:-}" ]; then
  NP=30619
  echo "  nodePort nao detectado, usando fallback ${NP}"
fi
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | awk '{print $1}')
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
[ "$C1" = "200" ] && ok "GET /healthz via Ingress retornou 200" || bad "GET /healthz via Ingress retornou ${C1}"
[ "$C2" = "200" ] && ok "GET / via Ingress retornou 200" || bad "GET / via Ingress retornou ${C2}"
[ "$C3" = "200" ] && ok "GET /metrics via Ingress retornou 200" || bad "GET /metrics via Ingress retornou ${C3}"

echo "== 2. Target da aplicacao no Prometheus =="
PROM_POD=$(kubectl -n "$NS_OBS" get pods -l app.kubernetes.io/name=prometheus \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "${PROM_POD:-}" ]; then
  bad "pod do Prometheus nao encontrado em ${NS_OBS}"
else
  kubectl -n "$NS_OBS" port-forward "pod/${PROM_POD}" 19090:9090 >/dev/null 2>&1 &
  PIDS+=($!)
  if wait_http "http://127.0.0.1:19090/-/ready" 40; then
    curl -s "http://127.0.0.1:19090/api/v1/targets?state=active" -o "$DIR/prom-targets.json"
    curl -s -G --data-urlencode 'query=up{namespace="poc-k8s"}' \
      "http://127.0.0.1:19090/api/v1/query" -o "$DIR/prom-up.json"
    curl -s -G --data-urlencode 'query=poc_app_info' \
      "http://127.0.0.1:19090/api/v1/query" -o "$DIR/prom-app-info.json"
    curl -s -G --data-urlencode 'query=poc_app_http_requests_total' \
      "http://127.0.0.1:19090/api/v1/query" -o "$DIR/prom-app-requests.json"
    if python3 - "$DIR" <<'PY'
import json, sys
d = sys.argv[1]
alvos = [a for a in json.load(open(f"{d}/prom-targets.json"))["data"]["activeTargets"]
         if a.get("labels", {}).get("namespace") == "poc-k8s"]
if not alvos:
    print("  nenhum target com namespace poc-k8s"); sys.exit(1)
for a in alvos:
    print(f"  target job={a['labels'].get('job')} health={a['health']} lastScrape={a['lastScrape']}")
up = json.load(open(f"{d}/prom-up.json"))["data"]["result"]
print(f"  series up{{namespace=\"poc-k8s\"}} = {len(up)}")
for s in up:
    print(f"    {s['metric'].get('pod', '?')} -> {s['value'][1]}")
info = json.load(open(f"{d}/prom-app-info.json"))["data"]["result"]
req = json.load(open(f"{d}/prom-app-requests.json"))["data"]["result"]
print(f"  series poc_app_info = {len(info)}  poc_app_http_requests_total = {len(req)}")
sys.exit(0 if all(a["health"] == "up" for a in alvos) and up and info and req else 1)
PY
    then ok "target UP e metricas proprias coletadas"; else bad "target ausente, down ou sem metrica propria"; fi
  else
    bad "Prometheus nao respondeu em /-/ready"
  fi
fi

echo "== 3. Logs da aplicacao no Loki =="
kubectl -n "$NS_OBS" port-forward svc/loki 13100:3100 >/dev/null 2>&1 &
PIDS+=($!)
if wait_http "http://127.0.0.1:13100/ready" 40; then
  FIM=$(date +%s)000000000
  INI=$(( $(date +%s) - 3600 ))000000000
  curl -s -G "http://127.0.0.1:13100/loki/api/v1/query_range" \
    --data-urlencode 'query={namespace="poc-k8s"}' \
    --data-urlencode "start=${INI}" --data-urlencode "end=${FIM}" \
    --data-urlencode 'limit=20' --data-urlencode 'direction=backward' \
    -o "$DIR/loki-query.json"
  if python3 - "$DIR" <<'PY'
import json, sys
d = sys.argv[1]
streams = json.load(open(f"{d}/loki-query.json"))["data"]["result"]
linhas = sum(len(s["values"]) for s in streams)
print(f"  streams={len(streams)} linhas={linhas}")
for s in streams[:3]:
    print(f"  stream pod={s['stream'].get('pod', '?')} container={s['stream'].get('container', '?')}")
    for _, linha in s["values"][:2]:
        print(f"    {linha[:160]}")
sys.exit(0 if linhas else 1)
PY
  then ok "Loki retornou linhas do namespace poc-k8s"; else bad "Loki sem linhas para poc-k8s"; fi
else
  bad "Loki nao respondeu em /ready"
fi

echo
echo "Resumo: ${PASS} aprovados, ${FAIL} reprovados"
echo "Evidencias em ${DIR}"
[ "$FAIL" -eq 0 ]
