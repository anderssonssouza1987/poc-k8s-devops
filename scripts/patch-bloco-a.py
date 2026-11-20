#!/usr/bin/env python3
"""Bloco A: checksum correto, tag sem latest, /metrics, ServiceMonitor e flag no pipeline.

Idempotente: pode rodar duas vezes sem duplicar nada.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALTERADOS = []


def ler(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def gravar(rel, texto):
    (ROOT / rel).write_text(texto, encoding="utf-8")
    ALTERADOS.append(rel)


def sub(rel, padrao, repl, esperado=1, guarda=None):
    texto = ler(rel)
    if guarda and guarda in texto:
        print(f"  = {rel}: ja aplicado")
        return False
    novo, n = re.subn(padrao, repl, texto, flags=re.M)
    if n != esperado:
        sys.exit(f"ERRO {rel}: esperava {esperado} ocorrencia(s), encontrou {n}")
    gravar(rel, novo)
    print(f"  + {rel}: {n} substituicao(oes)")
    return True


# --------------------------------------------------------------------------
# 1. deployment.yaml: checksum de ConfigMap e Secret (antes apontava para SA)
# --------------------------------------------------------------------------
def _checksums(m):
    ind = m.group(1)
    return (
        f'{ind}checksum/config: {{{{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}}}\n'
        f'{ind}checksum/secret: {{{{ include (print $.Template.BasePath "/secret.yaml") . | sha256sum }}}}'
    )


sub("chart/templates/deployment.yaml",
    r"^(\s*)checksum/config:.*$",
    _checksums,
    guarda="checksum/secret")

# --------------------------------------------------------------------------
# 2. deployment.yaml: tag vazia cai para appVersion do Chart
# --------------------------------------------------------------------------
sub("chart/templates/deployment.yaml",
    r'^(\s*)image: "\{\{ \.Values\.image\.repository \}\}:\{\{ \.Values\.image\.tag \}\}"\s*$',
    lambda m: (m.group(1)
               + 'image: "{{ .Values.image.repository }}:'
               + '{{ .Values.image.tag | default .Chart.AppVersion }}"'),
    guarda=".Values.image.tag | default .Chart.AppVersion")

# --------------------------------------------------------------------------
# 3. values.yaml: remove o default :latest (incompativel com a politica Kyverno)
# --------------------------------------------------------------------------
sub("chart/values.yaml", r"^(\s*)tag:\s*latest\s*$", lambda m: f'{m.group(1)}tag: ""')

# --------------------------------------------------------------------------
# 4. values.yaml: bloco serviceMonitor
# --------------------------------------------------------------------------
if "serviceMonitor:" not in ler("chart/values.yaml"):
    gravar("chart/values.yaml", ler("chart/values.yaml").rstrip("\n") + """

serviceMonitor:
  enabled: true
  interval: 30s
  scrapeTimeout: 10s
  path: /metrics
  namespace: ""
  labels: {}
""")
    print("  + chart/values.yaml: bloco serviceMonitor")

# --------------------------------------------------------------------------
# 5. chart/templates/servicemonitor.yaml
# --------------------------------------------------------------------------
SM = '''{{- if .Values.serviceMonitor.enabled }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "poc-k8s-app.fullname" . }}
  {{- with .Values.serviceMonitor.namespace }}
  namespace: {{ . }}
  {{- end }}
  labels:
    {{- include "poc-k8s-app.labels" . | nindent 4 }}
    {{- with .Values.serviceMonitor.labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
spec:
  namespaceSelector:
    matchNames:
      - {{ .Release.Namespace }}
  selector:
    matchLabels:
      {{- include "poc-k8s-app.selectorLabels" . | nindent 6 }}
  endpoints:
    - port: http
      path: {{ .Values.serviceMonitor.path }}
      interval: {{ .Values.serviceMonitor.interval }}
      scrapeTimeout: {{ .Values.serviceMonitor.scrapeTimeout }}
{{- end }}
'''
alvo_sm = ROOT / "chart/templates/servicemonitor.yaml"
if not alvo_sm.exists():
    alvo_sm.write_text(SM, encoding="utf-8")
    ALTERADOS.append("chart/templates/servicemonitor.yaml")
    print("  + chart/templates/servicemonitor.yaml: criado")

# --------------------------------------------------------------------------
# 6. app/requirements.txt: cliente Prometheus
# --------------------------------------------------------------------------
req = ler("app/requirements.txt")
if "prometheus-client" not in req:
    gravar("app/requirements.txt", req.rstrip("\n") + "\nprometheus-client==0.21.1\n")
    print("  + app/requirements.txt: prometheus-client==0.21.1")

# --------------------------------------------------------------------------
# 7. app/app.py: endpoint /metrics com registry proprio
# --------------------------------------------------------------------------
APP = '''import os
import time

from flask import Flask, Response, g, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

app = Flask(__name__)

START_TIME = time.time()
VERSION = os.getenv("APP_VERSION", "dev")

REGISTRY = CollectorRegistry(auto_describe=True)

HTTP_REQUESTS = Counter(
    "poc_app_http_requests_total",
    "Total de requisicoes HTTP recebidas",
    ["method", "endpoint", "status"],
    registry=REGISTRY,
)
HTTP_LATENCY = Histogram(
    "poc_app_http_request_duration_seconds",
    "Latencia das requisicoes HTTP em segundos",
    ["endpoint"],
    registry=REGISTRY,
)
APP_INFO = Gauge(
    "poc_app_info",
    "Informacoes da versao em execucao",
    ["version"],
    registry=REGISTRY,
)
APP_INFO.labels(version=VERSION).set(1)


@app.before_request
def _marcar_inicio():
    g.inicio = time.time()


@app.after_request
def _observar(response):
    endpoint = request.endpoint or "unmatched"
    if endpoint != "metrics":
        HTTP_REQUESTS.labels(request.method, endpoint, response.status_code).inc()
        inicio = getattr(g, "inicio", None)
        if inicio is not None:
            HTTP_LATENCY.labels(endpoint).observe(time.time() - inicio)
    return response


@app.get("/healthz")
def healthz():
    return jsonify(
        status="ok",
        version=VERSION,
        uptime_seconds=round(time.time() - START_TIME, 2),
    )


@app.get("/metrics")
def metrics():
    return Response(generate_latest(REGISTRY), content_type=CONTENT_TYPE_LATEST)


@app.get("/")
def index():
    return jsonify(message="POC Kubernetes - aplicacao de exemplo", version=VERSION)
'''
if "generate_latest" not in ler("app/app.py"):
    gravar("app/app.py", APP)
    print("  + app/app.py: /metrics instrumentado")

# --------------------------------------------------------------------------
# 8. app/tests/test_app.py: cobre /metrics para nao derrubar cobertura
# --------------------------------------------------------------------------
TESTE = '''

def test_metrics_expoe_formato_prometheus(client):
    client.get("/healthz")
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert "text/plain" in resp.headers["Content-Type"]
    assert b"poc_app_info" in resp.data
    assert b"poc_app_http_requests_total" in resp.data
'''
if "test_metrics_expoe_formato_prometheus" not in ler("app/tests/test_app.py"):
    gravar("app/tests/test_app.py", ler("app/tests/test_app.py").rstrip("\n") + TESTE)
    print("  + app/tests/test_app.py: teste de /metrics")

# --------------------------------------------------------------------------
# 9. Jenkinsfile: release do kube-prometheus-stack e flag condicional
# --------------------------------------------------------------------------
sub("Jenkinsfile",
    r"^(\s*)KUBECONFIG = '/root/\.kube/config'\s*$",
    lambda m: (m.group(1) + "KUBECONFIG = '/root/.kube/config'\n"
               + m.group(1) + "PROM_STACK_RELEASE = 'kube-prom'"),
    guarda="PROM_STACK_RELEASE")


def _sm_flag(m):
    ind = m.group(1)
    bloco = [
        "if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then",
        '  SM_FLAG="--set serviceMonitor.enabled=true --set serviceMonitor.labels.release=${PROM_STACK_RELEASE}"',
        "else",
        '  echo "AVISO: CRD ServiceMonitor ausente; observabilidade da app desabilitada"',
        '  SM_FLAG="--set serviceMonitor.enabled=false"',
        "fi",
    ]
    return "\n".join(ind + linha for linha in bloco) + "\n" + m.group(0)


sub("Jenkinsfile",
    r'^(\s*)helm lint "\$\{CHART_DIR\}" \\$',
    _sm_flag,
    guarda="SM_FLAG=")

sub("Jenkinsfile",
    r"^(\s*)--set imagePullSecrets\[0\]\.name=nexus-regcred \\$",
    lambda m: m.group(0) + "\n" + m.group(1) + "${SM_FLAG} \\",
    esperado=2,
    guarda="${SM_FLAG} \\")

# --------------------------------------------------------------------------
# 10. limpeza dos .bak versionados
# --------------------------------------------------------------------------
if (ROOT / ".git").exists():
    rastreados = subprocess.run(["git", "ls-files", "*.bak*"], cwd=ROOT,
                                capture_output=True, text=True).stdout.split()
    for arq in rastreados:
        subprocess.run(["git", "rm", "--cached", "--quiet", arq], cwd=ROOT, check=False)
        print(f"  - {arq}: removido do indice")
    gitignore = ROOT / ".gitignore"
    atual = gitignore.read_text(encoding="utf-8") if gitignore.exists() else ""
    if "*.bak.*" not in atual:
        gitignore.write_text(atual.rstrip("\n") + "\n*.bak.*\n", encoding="utf-8")
        print("  + .gitignore: *.bak.*")

print("\nArquivos alterados:")
for a in ALTERADOS:
    print(f"  {a}")
