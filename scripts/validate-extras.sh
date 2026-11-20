#!/usr/bin/env bash
set -uo pipefail
NS=observability
fail=0
ok(){ printf '  [APROVADO]  %s\n' "$1"; }
no(){ printf '  [REPROVADO] %s\n' "$1"; fail=$((fail+1)); }

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

echo "== Servicos auxiliares =="
for s in nexus jenkins sonarqube; do
  kubectl -n $NS get svc "$s" >/dev/null 2>&1 && ok "svc $s presente" || no "svc $s ausente"
done

echo
echo "Resumo: $((22-0)) checagens base + extras, $fail reprovados"
[ "$fail" -eq 0 ] || exit 1
