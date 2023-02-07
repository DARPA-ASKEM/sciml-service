"""
Defines interface available to the HMI
"""

from importlib import metadata

from fastapi import FastAPI

server = FastAPI(
    title="Executor API",
    version=metadata.version("executor"),
    description="Interface for Simulation workflows",
    docs_url="/",
)


@server.get("/logs")
def fetch_logs():
    return {"message": "No logs being created yet"}
