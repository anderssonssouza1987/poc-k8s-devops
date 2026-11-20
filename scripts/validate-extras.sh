#!/usr/bin/env bash
set -uo pipefail
NS=observability
fail=0; total=0; pends=0
ok(){ total=$((total+1)); printf '  [APROVADO]  %s\n' "$1"; }
no(){ total=$((total+1)); fail=$((fail+1)); printf '  [REPROVADO] %s\n' "$1"; }
pd(){ total=$((total+1)); pends=$((pends+1)); printf '  [PENDENTE]  %s\n' "$1"; }

echo "== Loki =="
kubectl -n $NS get sts loki -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q 1 \
  && ok "loki-0 pronto" || no "loki-0 nao pronto"

kubectl -n $NS port-forward svc/loki 3100:3100 >/tmp/pf-loki.log 2>&1 &
PF=$!; sleep 6
code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:3100/ready || echo 000)
[ "$code" = "200" ] && ok "loki /ready 200" || no "loki /ready $code"
kill "$PF" 2>/dev/null; wait "$PF" 2>/dev/null

echo "== Promtail =="
want=$(kubectl get nodes --no-headers | wc -l)
got=$(kubectl -n $NS get ds promtail -o jsonpath='{.status.numberReady}' 2>/dev/null)
[ "${got:-0}" = "$want" ] && ok "promtail $got/$want nodes" || no "promtail ${got:-0}/$want nodes"

echo "== Grafana security =="
GPOD=$(kubectl -n $NS get pod -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
uid=$(kubectl -n $NS exec "$GPOD" -c grafana -- id -u 2>/dev/null)
[ "$uid" = "10001" ] && ok "grafana uid efetivo 10001" || no "grafana uid efetivo ${uid:-vazio}"

ro=$(kubectl -n $NS get deploy kube-prom-grafana \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="grafana")].securityContext.readOnlyRootFilesystem}' 2>/dev/null)
[ "$ro" = "true" ] && ok "grafana readOnlyRootFilesystem=true" || no "grafana readOnlyRootFilesystem=${ro:-vazio}"

ds=$(kubectl -n $NS get cm kube-prom-kube-prometheus-grafana-datasource \
  -o jsonpath='{.data}' 2>/dev/null | grep -c 'loki.observability' || true)
[ "${ds:-0}" -ge 1 ] && ok "datasource Loki provisionado" || no "datasource Loki ausente"

echo "== Servicos auxiliares =="
for s in nexus jenkins sonarqube; do
  ns=$(kubectl get svc -A -o jsonpath="{range .items[?(@.metadata.name=='$s')]}{.metadata.namespace}{'\n'}{end}" 2>/dev/null | head -1)
  [ -n "$ns" ] && ok "svc $s em $ns" || pd "svc $s nao deployado"
done

echo
echo "Resumo: $total checagens, $fail reprovados, $pends pendentes"
[ "$fail" -eq 0 ] || exit 1
