from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap
from ..types.folder import FolderMap
from ..types.article import ArticleMap


async def migrate_articles(
    source: HuduClient,
    target: HuduClient,
    company_map: CompanyMap,
    folder_map: FolderMap,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None = None,
    max_file_size_mb: int = 100,
) -> ArticleMap:
    """Step 2b — Articles + attachments + relink. Scope filters global vs company KB."""
    raise NotImplementedError
