from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap
from ..types.asset import AssetMap
from ..types.rack import RackMap


async def migrate_racks(
    source: HuduClient,
    target: HuduClient,
    company_map: CompanyMap,
    asset_map: AssetMap,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None = None,
) -> RackMap:
    """Step 9 — Rack storages + items (company scope)."""
    raise NotImplementedError
