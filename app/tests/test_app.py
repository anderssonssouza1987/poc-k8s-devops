import pytest

from app import app


@pytest.fixture
def client():
    app.config.update(TESTING=True)
    with app.test_client() as c:
        yield c


def test_healthz_retorna_200(client):
    assert client.get("/healthz").status_code == 200


def test_healthz_payload(client):
    body = client.get("/healthz").get_json()
    assert body["status"] == "ok"
    assert "version" in body
    assert body["uptime_seconds"] >= 0


def test_index_responde(client):
    body = client.get("/").get_json()
    assert "message" in body


def test_rota_inexistente_retorna_404(client):
    assert client.get("/nao-existe").status_code == 404
