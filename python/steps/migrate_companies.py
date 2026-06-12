from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap


async def migrate_companies(
    source: HuduClient,
    target: HuduClient,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None,
) -> CompanyMap:
    """Step 1 — Migrate companies from source to target (company scope only).

    company_ids: None = all companies on source; [id] = single company.
    """
    raise NotImplementedError
