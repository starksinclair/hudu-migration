from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap
from ..types.folder import FolderMap
from ..types.photo import PhotoFolderMap


async def migrate_photos(
    source: HuduClient,
    target: HuduClient,
    company_map: CompanyMap,
    folder_map: FolderMap,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None = None,
    max_file_size_mb: int = 100,
) -> PhotoFolderMap:
    """Step 8 — Company photo gallery (company scope)."""
    raise NotImplementedError
