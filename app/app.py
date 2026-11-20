import os
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
