"""
Defines interface available to the HMI
"""

from importlib import metadata
from json import dumps

from fastapi import FastAPI, HTTPException, Response, status

from lib.run import execute, lookup
from lib.schema import SimulationPlan, SimulationRun

server = FastAPI(
    title="Executor API",
    version=metadata.version("executor"),
    description="Interface for Simulation workflows",
    docs_url="/",
)


@server.get("/logs")
def fetch_logs():
    """
    Perform basic healthcheck
    """
    return {"message": "No workflow is implemented yet"}


@server.post("/simulate")
def simulate(payload: SimulationPlan):
    """
    Create simulation run from plan
    """
    new_run = execute(payload)

    return Response(
        status_code=status.HTTP_201_CREATED,
        headers={
            "content-type": "application/json",
        },
        content=dumps({"id": new_run.id}),
    )


@server.get("/run/{id}")
def get_run(id: int) -> SimulationRun:
    """
    Find related sim run and return its status
    """
    run = lookup(id)  # pylint: disable=assignment-from-no-return
    if run is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    return run
