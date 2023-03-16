"""
Defines interface available to the HMI
"""

from importlib import metadata

from fastapi import FastAPI
from rq import Queue

from api.redis import redis_store
from api.schema import SimulationRun

# from api.worker import run_deterministic

queue = Queue(connection=redis_store)

server = FastAPI(
    title="Executor API",
    version=metadata.version("executor"),
    description="Interface for Simulation workflows",
    docs_url="/",
)


@server.post("/submit")
def create_run(payload: SimulationRun) -> int:
    """
    Kick off a job that spawns a run
    """
    sim = queue.enqueue("api.worker.run_deterministic", payload.task)
    return sim.id


@server.get("/status/{id}")
def create_status(id: str) -> str:
    """
    Kick off a job that spawns a run
    """
    sim = queue.fetch_job(id)
    return sim.get_status()
