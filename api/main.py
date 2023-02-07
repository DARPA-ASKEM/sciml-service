"""
Runs the API component
"""

from click import command, echo, option
from uvicorn import run as uvicorn_run


@command()
@option("--host", default="0.0.0.0", type=str, help="Address for the API")
@option("--port", default=9090, type=int, help="Port to expose API")
@option("--dev", default=True, type=bool, help="Set development flag")
def cli(host: str, port: int, dev: bool) -> None:
    """
    Execute data store API using uvicorn
    """
    echo("Starting API...")
    uvicorn_run(f"api.server:server", host=host, port=port, reload=dev)
