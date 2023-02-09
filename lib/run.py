"""
Generate and handle sim runs
"""


from logging import Logger
from random import random

from lib.schema import SimulationPlan, SimulationRun

logger = Logger(__name__)

# TODO(five)!: Create IDs that are ACTUALLY unique
def gen_id() -> int:
    """
    Generate a unique ID for a run
    """
    return int(random() * 1000) + 3


# TODO(five)!: Save run and register in workflow
def execute(plan: SimulationPlan) -> SimulationRun:
    """
    Start run based of off plan
    """
    id = gen_id()
    new_run = SimulationRun(id=id, plan=plan)
    logger.error("Run was actually not created")
    return new_run


# TODO(five)!: Perform actual lookup
def lookup(id: int) -> SimulationRun | None:
    """
    Return status of run
    """
    logger.error("%d is not being looked up", id)
