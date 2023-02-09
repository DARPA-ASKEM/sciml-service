"""
Schemas for the API
"""
# pylint: disable=no-self-argument

from datetime import datetime
from enum import Enum

from pydantic import BaseModel, root_validator


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
    inputs: dict[str, dict[str, int]]
    operation: SimOperation = SimOperation.SOLVE

    @root_validator
    def verify_operation_requirements(cls, values):
        """
        Checks if the operation has all the requisite data
        """
        dataset_chosen = values.get("dataset_id", None) is not None
        dataset_needed = values.get("operation", None) == SimOperation.FIT
        if dataset_chosen and not dataset_needed:
            raise AssertionError("Dataset given when none is needed")
        if not dataset_chosen and dataset_needed:
            raise AssertionError("Dataset needed for operation")
        return values

    # TODO(five): Add some validation for inputs

    class Config:
        """
        Additional pydantic configuration
        """

        validate_assignment = True


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
    answer: float | int | bool | None = None
    generated: str | None = None


class SimulationRun(BaseModel):
    """
    Object created from a sim plan
    """

    id: int
    plan: SimulationPlan
    status: Status = Status.WORKING
    timestamp: datetime = datetime.now()
    result: Result | None = None

    @root_validator
    def handle_completed(cls, values):
        """
        Ensure result and completed status are mutual dependent
        """
        completed = values.get("status", None) == Status.COMPLETED
        is_result = values.get("result", None) is not None
        if completed and not is_result:
            raise AssertionError("Results not provided with completed run")
        if not completed and is_result:
            raise AssertionError("Results provided on an incomplete run")
        return values

    class Config:
        """
        Additional pydantic configuration
        """

        validate_assignment = True
