"""
Ensure the endpoints of the API layer are working.

Each test should have three parts: ARRANGE, ACT, ASSERT. 
"""

from datetime import datetime

from pydantic import BaseModel, ValidationError

from lib.run import execute, gen_id, lookup
from lib.schema import SimulationPlan, SimulationRun


def fits_schema(schema: type[BaseModel], obj):
    """
    Checks if object conforms to schema
    """
    try:
        schema.parse_obj(obj)
    except ValidationError:
        return False
    return True


def test_plan_schema():
    """
    Test if the operation validation is working
    """

    working_solve_payload = {
        "model_id": 1,
        "framework": "petri",
        "operation": "solve",
        "inputs": {},
    }
    broken_solve_payload = {
        "model_id": 1,
        "framework": "petri",
        "operation": "solve",
        "dataset_id": 1,
        "inputs": {},
    }
    working_fit_payload = {
        "model_id": 1,
        "framework": "petri",
        "operation": "fit",
        "dataset_id": 1,
        "inputs": {},
    }
    broken_fit_payload = {
        "model_id": 1,
        "framework": "petri",
        "operation": "fit",
        "inputs": {},
    }

    working_solve = fits_schema(SimulationPlan, working_solve_payload)
    broken_solve = fits_schema(SimulationPlan, broken_solve_payload)
    working_fit = fits_schema(SimulationPlan, working_fit_payload)
    broken_fit = fits_schema(SimulationPlan, broken_fit_payload)

    assert working_solve
    assert not broken_solve
    assert working_fit
    assert not broken_fit


def test_run_schema():
    """
    Validate completion logic
    """

    sim_plan_payload = {
        "model_id": 1,
        "framework": "petri",
        "operation": "solve",
        "inputs": {},
    }
    result_payload = {
        "success": False,
        "completed_at": datetime.now(),
        "message": "",
    }
    working_incomplete_payload = {
        "id": 1,
        "plan": sim_plan_payload,
        "status": "working",
    }
    broken_incomplete_payload = {
        "id": 1,
        "plan": sim_plan_payload,
        "status": "working",
        "result": result_payload,
    }
    working_complete_payload = {
        "id": 1,
        "plan": sim_plan_payload,
        "status": "completed",
        "result": result_payload,
    }
    broken_complete_payload = {
        "id": 1,
        "plan": sim_plan_payload,
        "status": "completed",
    }

    working_incomplete = fits_schema(SimulationRun, working_incomplete_payload)
    broken_incomplete = fits_schema(SimulationRun, broken_incomplete_payload)
    working_complete = fits_schema(SimulationRun, working_complete_payload)
    broken_complete = fits_schema(SimulationRun, broken_complete_payload)

    assert working_incomplete
    assert not broken_incomplete
    assert working_complete
    assert not broken_complete


# TODO(five): Validate full function when `gen_id` is fully implemented
def test_id_gen():
    """
    Ensure ID generation is creating unique keys
    """
    assert gen_id() != 1


# TODO(five): Validate full function when `execute` is fully implemented
def test_execute():
    """
    Ensure sim plan generates a run properly
    """
    sim_plan_payload = {
        "model_id": 1,
        "framework": "petri",
        "operation": "solve",
        "inputs": {},
    }

    run = execute(SimulationPlan.parse_obj(sim_plan_payload))

    assert run.id != 1


# TODO(five): Validate full function when `lookup` is fully implemented
def test_lookup():
    """
    Test if run can be retrieved
    """
    assert lookup(1) is None
