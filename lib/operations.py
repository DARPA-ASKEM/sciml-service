"""
Possible Operations
"""

from enum import Enum
from typing import Any

from pydantic import BaseModel


class Operation(BaseModel):
    """
    Operation to become a template
    """

    class Config:
        """
        Additional pydantic configuration
        """

        validate_assignment = True


OperationType = Enum("OperationType", {})
type_to_cls = {}


def register(label: str):
    def attach(pydantic_cls: type[BaseModel]) -> type[BaseModel]:
        global OperationType
        global type_to_cls
        mappings = {choice.name: choice.value for choice in list(OperationType)}
        mappings[label] = label
        OperationType = Enum("OperationType", mappings)
        type_to_cls[OperationType(label)] = pydantic_cls
        OperationType.get = lambda x: type_to_cls.get(x, None)
        return pydantic_cls

    return attach


@register("init")
class OperationInit(Operation):
    """
    Implicit import of all the necessary modules
    """


@register("select_model")
class OperationSelectModel(Operation):
    framework: str  # this should be attached to the model
    model_id: int


@register("parameterize")
class OperationParameterize(Operation):
    inputs: dict[str, dict[str, Any]]


@register("solve")
class OperationSolve:
    tspan: tuple[int, int]


# class Framework(str, Enum):
#    """
#    Schema used to read acset
#    """
#
#    PETRI = "petri"
#

#    CONVERSION = xx
#   SOLVE = "solve"
#   FIT = "fit"
