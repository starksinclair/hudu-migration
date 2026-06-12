from dataclasses import dataclass

from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap
from ..types.article import ArticleMap
from ..types.asset import AssetMap
from ..types.website import WebsiteMap
from ..types.rack import RackMap
from ..types.flag import FlagTypeMap


@dataclass
class FlagMigrationMaps:
    company_map: CompanyMap
    article_map: ArticleMap
    asset_map: AssetMap
    website_map: WebsiteMap
    rack_map: RackMap


async def migrate_flags(
    source: HuduClient,
    target: HuduClient,
    maps: FlagMigrationMaps,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None = None,
) -> FlagTypeMap:
    """Step 14 — Flag types + flags. Global: types + global article flags. Company: company objects."""
    raise NotImplementedError
