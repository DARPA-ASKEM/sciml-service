"""
CIEMSS or SciML Jobs    
"""

from julia import Julia, Main
from rq import Worker

from api.redis import redis_store
from api.settings import settings

jl = Julia()
jl.using("Deterministic")


def run_deterministic(task: str):
    # return Main.eval(f"Deterministic.{task}()")
    return jl.eval(f'"hello"')


def init_worker():
    worker = Worker(["default"], connection=redis_store)
    worker.work()
