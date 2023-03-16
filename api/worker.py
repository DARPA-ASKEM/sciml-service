"""
CIEMSS or SciML Jobs    
"""

from rq import Worker
from rq.decorators import job

from api.redis import redis_store
from api.settings import settings


@job("default", connection=redis_store)
def run_deterministic(*args, **kwargs):
    from julia import Julia, Main

    jl = Julia()
    jl.using("Deterministic")
    return jl.eval(f'"hello"')
    return Main.eval(f"Deterministic.{task}()")


def init_worker():
    worker = Worker(["default"], connection=redis_store)
    worker.work()
