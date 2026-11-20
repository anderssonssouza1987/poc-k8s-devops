import os
import time

from flask import Flask, jsonify

app = Flask(__name__)

START_TIME = time.time()
VERSION = os.getenv("APP_VERSION", "dev")


@app.get("/healthz")
def healthz():
    return jsonify(
        status="ok",
        version=VERSION,
        uptime_seconds=round(time.time() - START_TIME, 2),
    )


@app.get("/")
def index():
    return jsonify(message="POC Kubernetes - aplicacao de exemplo", version=VERSION)
