from dataclasses import dataclass

from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.asset_layout import LayoutMap, LayoutFieldMap, ListMap


@dataclass
class AssetLayoutMigrationResult:
    layout_map: LayoutMap
    layout_field_map: LayoutFieldMap
    list_map: ListMap


async def migrate_asset_layouts(
    source: HuduClient,
    target: HuduClient,
    stats: Stats,
    *,
    scope: MigrationScope,
) -> AssetLayoutMigrationResult:
    """Step 2 — Lists + asset layouts + admin folders (global scope)."""
    raise NotImplementedError
