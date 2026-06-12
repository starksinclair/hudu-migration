from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap
from ..types.folder import FolderMap


async def migrate_folders(
    source: HuduClient,
    target: HuduClient,
    company_map: CompanyMap,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None = None,
) -> FolderMap:
    """Step 2a — KB folders. Global scope: central KB only. Company scope: company folders."""
    raise NotImplementedError
