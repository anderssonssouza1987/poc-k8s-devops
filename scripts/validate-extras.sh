#!/usr/bin/env bash
set -uo pipefail
NS=observability
APP=poc-k8s
okc=0; noc=0; pdc=0
ok(){ printf '  [APROVADO]  %s\n' "$1"; okc=$((okc+1)); }
no(){ printf '  [REPROVADO] %s\n' "$1"; noc=$((noc+1)); }
pd(){ printf '  [PENDENTE]  %s\n' "$1"; pdc=$((pdc+1)); }

echo "== Loki =="
kubectl -n $NS get sts loki -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q 1 \
  && ok "loki-0 pronto" || no "loki-0 nao pronto"

kubectl -n $NS port-forward svc/loki 3100:3100 >/tmp/pf-loki.log 2>&1 &
PF=$!; sleep 6
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3100/ready || true)
kill "$PF" 2>/dev/null; wait "$PF" 2>/dev/null
[ "$code" = "200" ] && ok "loki /ready 200" || no "loki /ready HTTP ${code:-sem-resposta}"

echo "== Promtail =="
nodes=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
ready=$(kubectl -n $NS get ds promtail -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
[ "${ready:-0}" -ge "$nodes" ] && [ "$nodes" -gt 0 ] \
  && ok "promtail ${ready}/${nodes} nodes" || no "promtail ${ready:-0}/${nodes} nodes"

echo "== Grafana security =="
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
uid=$(kubectl -n $NS exec "$POD" -c grafana -- id -u 2>/dev/null | tr -d '\r\n')
[ "$uid" = "10001" ] && ok "grafana uid efetivo 10001" || no "grafana uid efetivo ${uid:-desconhecido}"

rofs=$(kubectl -n $NS get deploy kube-prom-grafana \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="grafana")].securityContext.readOnlyRootFilesystem}' 2>/dev/null)
[ "$rofs" = "true" ] && ok "grafana readOnlyRootFilesystem=true" || no "grafana readOnlyRootFilesystem=${rofs:-ausente}"

ds=$(kubectl -n $NS get cm kube-prom-kube-prometheus-grafana-datasource \
  -o jsonpath='{.data}' 2>/dev/null | grep -c 'loki.observability' || true)
[ "${ds:-0}" -ge 1 ] && ok "datasource Loki provisionado" || no "datasource Loki ausente"

echo "== Servicos auxiliares =="
for c in nexus jenkins sonarqube; do
  st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo ausente)
  [ "$st" = "running" ] && ok "container $c running" || no "container $c $st"
done

echo "== Politica Kyverno =="
kubectl get validatingpolicy disallow-latest-tag >/dev/null 2>&1 \
  && ok "ValidatingPolicy disallow-latest-tag aplicada" || no "ValidatingPolicy ausente"

out=$(kubectl -n $APP run policy-probe --image=nginx:latest --dry-run=server -o yaml 2>&1 || true)
if printf '%s' "$out" | grep -q 'disallow-latest-tag'; then
  ok "politica bloqueia :latest"
elif printf '%s' "$out" | grep -q 'AlreadyExists'; then
  no "probe colidiu com pod existente"
else
  no "politica nao bloqueou :latest"
fi

echo
echo "Resumo: $((okc+noc+pdc)) checagens, ${noc} reprovados, ${pdc} pendentes"
[ "$noc" -eq 0 ] && exit 0 || exit 1
