from typing import Optional
from ..types.flag import FlagableType
from ..types.relation import RelationType


def get_article_lookup_key(
    name: str,
    company_id: Optional[int],
    folder_id: Optional[int],
) -> str:
    raise NotImplementedError


def get_password_lookup_key(
    name: str,
    company_id: Optional[int],
    folder_id: Optional[int],
    username: Optional[str],
    login_url: Optional[str],
) -> str:
    raise NotImplementedError


def get_folder_lookup_key(
    name: str,
    company_id: Optional[int],
    parent_folder_id: Optional[int],
) -> str:
    raise NotImplementedError


def get_flag_dedupe_key(
    flag_type_id: int,
    flagable_type: FlagableType,
    flagable_id: int,
    description: Optional[str],
) -> str:
    raise NotImplementedError


def get_migration_relation_pair_key(
    from_type: RelationType,
    from_id: int,
    to_type: RelationType,
    to_id: int,
) -> str:
    """Returns a stable sorted key for a relation pair (normalises direction)."""
    raise NotImplementedError
