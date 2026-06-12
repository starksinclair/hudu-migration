from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap
from ..types.asset_layout import LayoutMap, LayoutFieldMap, ListMap
from ..types.asset import AssetMap


async def migrate_assets(
    source: HuduClient,
    target: HuduClient,
    company_map: CompanyMap,
    layout_map: LayoutMap,
    layout_field_map: LayoutFieldMap,
    list_map: ListMap,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None = None,
) -> AssetMap:
    """Step 11 — Company assets (company scope; layouts from global phase)."""
    raise NotImplementedError
