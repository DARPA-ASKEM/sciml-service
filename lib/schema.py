"""
Schemas for the API
"""
# pylint: disable=no-self-argument

from datetime import datetime
from enum import Enum

from pydantic import BaseModel, validator

from lib.operations import Operation, OperationType


class Workflow(BaseModel):
    """
    A request for simulation
    """

    id: int
    operation: list[dict[str, type[Operation]]] = []

    @validator("operation", pre=True)
    def convert_operations(cls, values):
        """
        Checks if the operation has all the requisite data
        """
        dataset_chosen = values.get("dataset_id", None) is not None
        dataset_needed = values.get("operation", None) == Operation.FIT
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
