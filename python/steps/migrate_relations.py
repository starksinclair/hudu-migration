from dataclasses import dataclass

from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap
from ..types.article import ArticleMap
from ..types.asset import AssetMap
from ..types.website import WebsiteMap
from ..types.password import PasswordFolderMap
from ..types.procedure import ProcedureMap
from ..types.ipam import IpamMaps
from ..types.rack import RackMap


@dataclass
class RelationMigrationMaps:
    company_map: CompanyMap
    article_map: ArticleMap
    asset_map: AssetMap
    website_map: WebsiteMap
    password_folder_map: PasswordFolderMap
    procedure_map: ProcedureMap
    ipam_maps: IpamMaps
    rack_map: RackMap


async def migrate_relations(
    source: HuduClient,
    target: HuduClient,
    maps: RelationMigrationMaps,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None = None,
) -> None:
    """Step 13 — Relations (company scope)."""
    raise NotImplementedError
