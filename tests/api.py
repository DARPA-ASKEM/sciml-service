"""
Ensure the endpoints of the API layer are working.

Each test should have three parts: ARRANGE, ACT, ASSERT. 
"""

from fastapi.testclient import TestClient

from api.server import server


def test_logs():
    """
    Test if service has started
    """
    client = TestClient(server)

    response = client.get("/logs")

    assert response.status_code == 200
    assert response.json() == {"message": "No logs being created yet"}
