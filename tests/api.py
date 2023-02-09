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
    assert response.json() == {"message": "No workflow is implemented yet"}


# TODO(five): Revise when `simulate` is fixed
def test_simulate():
    """
    Test if simulation kicks off
    """
    sim_plan_payload = {
        "model_id": 1,
        "framework": "petri",
        "operation": "solve",
        "inputs": {},
    }
    client = TestClient(server)

    response = client.post(
        "/simulate",
        json=sim_plan_payload,
        headers={
            "Content-type": "application/json",
            "Accept": "application/json",
        },
    )

    assert response.status_code == 201


# TODO(five): Revise when `get_run` is fixed
def test_get_run():
    """
    Test if run can be retrieved and updates over time
    """
    client = TestClient(server)

    response = client.get("/run/1")

    assert response.status_code == 404
