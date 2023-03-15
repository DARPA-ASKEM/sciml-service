"""
Schemas
"""

from pydantic import BaseModel


class SimulationRun(BaseModel):
    task: str
