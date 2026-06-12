from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap
from ..types.website import WebsiteMap


async def migrate_websites(
    source: HuduClient,
    target: HuduClient,
    company_map: CompanyMap,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None = None,
) -> WebsiteMap:
    """Step 6 — Monitored websites (company scope)."""
    raise NotImplementedError
