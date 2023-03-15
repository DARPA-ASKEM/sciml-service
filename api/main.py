"""
Runs the API component
"""

from click import echo, group, option
from uvicorn import run as uvicorn_run

from api.worker import init_worker


@group()
def cli() -> None:
    """
    Wrap api and worker
    """


@cli.command()
@option("--host", default="0.0.0.0", type=str, help="Address for the API")
@option("--port", default=9090, type=int, help="Port to expose API")
@option("--dev", default=True, type=bool, help="Set development flag")
def api(host: str, port: int, dev: bool):
    """
    Execute API using uvicorn
    """
    uvicorn_run("api.server:server", host=host, port=port, reload=dev)


@cli.command()
def worker():
    """
    Execute worker with preloaded libs
    """
    init_worker()
