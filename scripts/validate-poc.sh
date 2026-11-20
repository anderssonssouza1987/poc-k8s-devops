#!/usr/bin/env bash
# scripts/validate-poc.sh - auditoria dos requisitos do POC
set -uo pipefail

NS="${NS:-poc-k8s}"
APP="${APP:-poc-k8s-app}"
HOST_HDR="${HOST_HDR:-poc-k8s.local}"
TRIVY_REPORT="${TRIVY_REPORT:-/srv/jenkins/workspace/poc-k8s-app/trivy-report.txt}"
PASS=0
FAIL=0

ok()  { printf '  [APROVADO]  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [REPROVADO] %s\n' "$1"; FAIL=$((FAIL+1)); }
hdr() { printf '\n== %s ==\n' "$1"; }

command -v kubectl >/dev/null || { echo "kubectl ausente"; exit 2; }

hdr "Disponibilidade"
READY=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
DESIRED=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.replicas}' 2>/dev/null)
if [ "${READY:-0}" = "${DESIRED:-0}" ] && [ "${READY:-0}" -ge 1 ]; then
  ok "replicas prontas ${READY}/${DESIRED}"
else
  bad "replicas prontas ${READY:-0}/${DESIRED:-0}"
fi

POD=$(kubectl -n "$NS" get pod -l "app.kubernetes.io/name=$APP" \
  --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "${POD:-}" ]; then
  bad "nenhum pod Running para inspecionar"
  printf '\nResumo: %d aprovados, %d reprovados\n' "$PASS" "$FAIL"
  exit 1
fi
ok "pod de inspecao: $POD"

hdr "Security context"
POD_UID=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.securityContext.runAsUser}')
CTR_UID=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].securityContext.runAsUser}')
[ "$POD_UID" = "10001" ] && ok "pod runAsUser=10001" || bad "pod runAsUser=${POD_UID:-vazio}"
[ "$CTR_UID" = "10001" ] && ok "container runAsUser=10001" || bad "container runAsUser=${CTR_UID:-vazio}"

ROFS=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}')
[ "$ROFS" = "true" ] && ok "readOnlyRootFilesystem=true" || bad "readOnlyRootFilesystem=${ROFS:-vazio}"

APE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].securityContext.allowPrivilegeEscalation}')
[ "$APE" = "false" ] && ok "allowPrivilegeEscalation=false" || bad "allowPrivilegeEscalation=${APE:-vazio}"

DROP=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].securityContext.capabilities.drop[*]}')
case "$DROP" in *ALL*) ok "capabilities.drop contem ALL" ;; *) bad "capabilities.drop=${DROP:-vazio}" ;; esac

hdr "Runtime"
UID_OUT=$(kubectl -n "$NS" exec "$POD" -- id -u 2>/dev/null)
[ "$UID_OUT" = "10001" ] && ok "uid efetivo 10001" || bad "uid efetivo ${UID_OUT:-?}"

if kubectl -n "$NS" exec "$POD" -- sh -c 'touch /tmp/.probe && rm -f /tmp/.probe' >/dev/null 2>&1; then
  ok "/tmp gravavel"
else
  bad "/tmp nao gravavel"
fi

if kubectl -n "$NS" exec "$POD" -- sh -c 'touch /app/.probe' >/dev/null 2>&1; then
  bad "raiz gravavel (readOnlyRootFilesystem nao aplicado)"
  kubectl -n "$NS" exec "$POD" -- rm -f /app/.probe >/dev/null 2>&1
else
  ok "raiz somente leitura"
fi

CODE=$(kubectl -n "$NS" exec "$POD" -- python -c \
  "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/healthz',timeout=5).status)" 2>/dev/null)
[ "$CODE" = "200" ] && ok "/healthz interno 200" || bad "/healthz interno ${CODE:-?}"

hdr "Probes e volumes"
LIVE=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}')
RDY=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}')
[ "$LIVE" = "/healthz" ] && ok "liveness em /healthz" || bad "liveness em ${LIVE:-vazio}"
[ "$RDY" = "/healthz" ] && ok "readiness em /healthz" || bad "readiness em ${RDY:-vazio}"

TMPMOUNT=$(kubectl -n "$NS" get deploy "$APP" -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.name}:{.mountPath}{"\n"}{end}' | grep -c '^tmp:/tmp$')
[ "${TMPMOUNT:-0}" -ge 1 ] && ok "emptyDir tmp montado em /tmp" || bad "emptyDir tmp ausente em /tmp"

hdr "HPA"
CPU=""
for _ in $(seq 1 12); do
  CPU=$(kubectl -n "$NS" get hpa "$APP" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)
  [ -n "${CPU:-}" ] && break
  sleep 10
done
if [ -n "${CPU:-}" ]; then
  ok "HPA medindo CPU em ${CPU}%"
else
  bad "HPA sem metrica (TARGETS <unknown>) apos 120s"
fi
MINP=$(kubectl -n "$NS" get hpa "$APP" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
MAXP=$(kubectl -n "$NS" get hpa "$APP" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
[ "${MINP:-0}" -ge 2 ] && ok "minReplicas=${MINP}" || bad "minReplicas=${MINP:-vazio}"
[ "${MAXP:-0}" -gt "${MINP:-0}" ] && ok "maxReplicas=${MAXP}" || bad "maxReplicas=${MAXP:-vazio}"

hdr "Ingress"
CLASS=$(kubectl -n "$NS" get ingress "$APP" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
[ "$CLASS" = "nginx" ] && ok "ingressClassName=nginx" || bad "ingressClassName=${CLASS:-vazio}"
IHOST=$(kubectl -n "$NS" get ingress "$APP" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null)
[ "$IHOST" = "$HOST_HDR" ] && ok "host $IHOST" || bad "host ${IHOST:-vazio} (esperado $HOST_HDR)"

hdr "HTTP externo"
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null)

probe_http() {
  local base="$1" label="$2" h r
  h=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H "Host: $HOST_HDR" "$base/healthz" 2>/dev/null)
  r=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H "Host: $HOST_HDR" "$base/" 2>/dev/null)
  [ "$h" = "200" ] && ok "$label /healthz 200" || bad "$label /healthz ${h:-erro}"
  [ "$r" = "200" ] && ok "$label / 200" || bad "$label / ${r:-erro}"
}

if [ -n "${NP:-}" ] && curl -sS -m 3 -o /dev/null "http://$NODE_IP:$NP/" 2>/dev/null; then
  probe_http "http://$NODE_IP:$NP" "NodePort $NP"
else
  FREE_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  kubectl -n ingress-nginx port-forward --address 127.0.0.1 \
    svc/ingress-nginx-controller "$FREE_PORT:80" >/tmp/pf-validate.log 2>&1 &
  PF_PID=$!
  sleep 4
  probe_http "http://127.0.0.1:$FREE_PORT" "port-forward $FREE_PORT"
  kill "$PF_PID" 2>/dev/null
  wait "$PF_PID" 2>/dev/null
fi

hdr "Trivy"
if [ -s "$TRIVY_REPORT" ]; then
  N=$(grep -cE 'CVE-[0-9]{4}-|GHSA-' "$TRIVY_REPORT" || true)
  ok "relatorio presente, ${N} ocorrencia(s) CVE/GHSA"
else
  bad "relatorio ausente em $TRIVY_REPORT"
fi

printf '\nResumo: %d aprovados, %d reprovados\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
