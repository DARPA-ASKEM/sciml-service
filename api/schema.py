"""
Schemas for the API
"""
# pylint: disable=no-self-argument

from datetime import datetime
from enum import Enum

from pydantic import BaseModel, validator


# TODO(five): Do not use Enum... Directly fetch semantics from TDS
class Framework(str, Enum):
    """
    Schema used to read acset
    """

    PETRI = "petri"


class SimOperation(str, Enum):
    """
    The allowable operations for model execution.
    """

    SOLVE = "solve"
    FIT = "fit"


class SimulationPlan(BaseModel):
    """
    A request for simulation
    """

    model_id: int
    framework: Framework = Framework.PETRI
    dataset_id: int | None = None
    inputs: dict[str, dict[str, str]]
    operation: SimOperation = SimOperation.SOLVE

    @validator("operation")
    def verify_operation_requirements(cls, operation, values):
        """
        Checks if the operation has all the requisite data
        """
        dataset_chosen = values.get("dataset_id", None) is not None
        dataset_needed = operation == SimOperation.FIT
        if dataset_chosen and not dataset_needed:
            return AssertionError("Dataset given when none is needed")
        if not dataset_chosen and dataset_needed:
            return AssertionError("Dataset needed for operation")
        return operation

    # TODO(five): Add some validation for inputs


class Status(str, Enum):
    """
    Exposed status of a sim run
    """

    WORKING = "working"
    COMPLETED = "completed"


class Result(BaseModel):
    """
    Output of a run
    """

    success: bool
    completed_at: datetime
    message: str
    answer: float | int | bool | None
    generated: str | None


class SimulationRun(BaseModel):
    """
    Object created from a sim plan
    """

    id: int
    plan: SimulationPlan
    status: Status = Status.WORKING
    timestamp: datetime = datetime.now()
    result: Result | None = None

    @validator("result")
    def handle_completed(cls, result, values):
        """
        Ensure result and completed status are mutual dependent
        """
        completed = values.get("status", None) == Status.COMPLETED
        is_result = result is not None
        if completed and not is_result:
            return AssertionError("Results not provided with completed run")
        if not completed and is_result:
            return AssertionError("Results provided on an incomplete run")
        return result
