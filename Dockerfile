# ---- estagio 1: dependencias de execucao ----
FROM python:3.12-slim AS deps
ENV PIP_NO_CACHE_DIR=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /src
COPY app/requirements.txt .
RUN pip install --prefix=/install -r requirements.txt

# ---- estagio 2: testes ----
FROM python:3.12-slim AS test
ENV PIP_NO_CACHE_DIR=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /src
COPY --from=deps /install /usr/local
COPY app/ .
RUN pip install pytest==8.3.4 && python -m pytest -q

# ---- estagio 3: runtime ----
FROM python:3.12-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN useradd --uid 10001 --create-home appuser
WORKDIR /app
COPY --from=deps /install /usr/local
COPY --from=test /src/app.py /src/wsgi.py ./
USER 10001
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "wsgi:app"]
