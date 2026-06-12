from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap
from ..types.password import PasswordFolderMap


async def migrate_passwords(
    source: HuduClient,
    target: HuduClient,
    company_map: CompanyMap,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None = None,
) -> PasswordFolderMap:
    """Step 3 — Password folders + credentials. Global: tenant-wide; company: per company."""
    raise NotImplementedError
