from typing import TypedDict, NotRequired


class ProcedureTask(TypedDict):
    id: int
    name: str
    position: int
    completed: bool
    description: NotRequired[str]
    parent_task_id: NotRequired[int]


class Procedure(TypedDict):
    id: int
    name: str
    run: bool
    tasks: list[ProcedureTask]
    description: NotRequired[str]
    company_id: NotRequired[int]
    slug: NotRequired[str]


class CreateProcedurePayload(TypedDict, total=False):
    name: str
    description: str
    company_id: int


class CreateProcedureTaskPayload(TypedDict, total=False):
    name: str
    procedure_id: int
    position: int
    description: str
    parent_task_id: int
    completed: bool


# sourceId -> targetId
ProcedureMap = dict[int, int]
