from typing import Any, Literal, Optional, TypeVar
from dataclasses import dataclass
from ..types.common import MigrationConfig

HttpMethod = Literal["GET", "POST", "PUT", "PATCH", "DELETE"]

T = TypeVar("T")


@dataclass
class ApiContext:
    base_url: str
    api_key: str


_source_context: Optional[ApiContext] = None
_target_context: Optional[ApiContext] = None
_active_context: Optional[ApiContext] = None


def init_api_contexts(config: MigrationConfig) -> None:
    raise NotImplementedError


def use_source_hudu() -> None:
    raise NotImplementedError


def use_target_hudu() -> None:
    raise NotImplementedError


def invoke_hudu_json_api(method: HttpMethod, path: str, body: Any = None) -> Any:
    raise NotImplementedError


def get_all_pages(path: str, items_key: str) -> list[Any]:
    raise NotImplementedError
