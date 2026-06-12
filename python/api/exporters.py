from typing import Optional
from ..clients.hudu_client import HuduClient
from ..types.company import Company, CreateCompanyPayload
from ..types.article import Article, CreateArticlePayload, PublicPhoto, ArticleUpload
from ..types.asset_layout import AssetLayout, CreateAssetLayoutPayload, SidebarFolder
from ..types.folder import Folder, CreateFolderPayload
from ..types.password import Password, PasswordFolder, CreatePasswordPayload, CreatePasswordFolderPayload
from ..types.procedure import Procedure, ProcedureTask, CreateProcedurePayload, CreateProcedureTaskPayload
from ..types.website import Website, CreateWebsitePayload
from ..types.ipam import (
    VlanZone, Vlan, Network, IpAddress,
    CreateVlanZonePayload, CreateVlanPayload, CreateNetworkPayload, CreateIpAddressPayload,
)
from ..types.photo import Photo, PhotoFolder
from ..types.asset import Asset, CreateAssetPayload
from ..types.rack import RackStorage, RackStorageItem, CreateRackStoragePayload, CreateRackStorageItemPayload
from ..types.relation import Relation, CreateRelationPayload
from ..types.flag import Flag, FlagType, CreateFlagPayload, CreateFlagTypePayload
from ..types.list import HuduList, CreateHuduListPayload


# ── Companies ─────────────────────────────────────────────────────────────────

def create_company(client: HuduClient, payload: CreateCompanyPayload) -> Company:
    raise NotImplementedError

def update_company(client: HuduClient, company_id: int, payload: CreateCompanyPayload) -> Company:
    raise NotImplementedError


# ── Articles ──────────────────────────────────────────────────────────────────

def create_article(client: HuduClient, payload: CreateArticlePayload) -> Article:
    raise NotImplementedError

def update_article(client: HuduClient, article_id: int, payload: CreateArticlePayload) -> Article:
    raise NotImplementedError




# -- Public Photos ─────────────────────────────────────────────────────────────
def create_public_photo(client: HuduClient, file_data: bytes, filename: str, content_type: str) -> PublicPhoto:
    """Upload an embeddable public photo (/public_photo/<slug>)."""
    raise NotImplementedError



# ── Asset Layouts ─────────────────────────────────────────────────────────────

def create_asset_layout(client: HuduClient, payload: CreateAssetLayoutPayload) -> AssetLayout:
    raise NotImplementedError

def update_asset_layout(client: HuduClient, layout_id: int, payload: CreateAssetLayoutPayload) -> AssetLayout:
    raise NotImplementedError

def create_list(client: HuduClient, payload: CreateHuduListPayload) -> HuduList:
    raise NotImplementedError

def create_sidebar_folder(client: HuduClient, name: str, parent_folder_id: Optional[int] = None) -> SidebarFolder:
    raise NotImplementedError

def link_layout_to_sidebar_folder(client: HuduClient, layout_id: int, folder_id: int) -> None:
    raise NotImplementedError


# ── Folders ───────────────────────────────────────────────────────────────────

def create_folder(client: HuduClient, payload: CreateFolderPayload) -> Folder:
    raise NotImplementedError


# ── Passwords ─────────────────────────────────────────────────────────────────

def create_password_folder(client: HuduClient, payload: CreatePasswordFolderPayload) -> PasswordFolder:
    raise NotImplementedError

def create_password(client: HuduClient, payload: CreatePasswordPayload) -> Password:
    raise NotImplementedError


# ── Procedures ────────────────────────────────────────────────────────────────

def create_procedure(client: HuduClient, payload: CreateProcedurePayload) -> Procedure:
    raise NotImplementedError

def create_procedure_task(client: HuduClient, payload: CreateProcedureTaskPayload) -> ProcedureTask:
    raise NotImplementedError

def start_procedure(client: HuduClient, procedure_id: int) -> Procedure:
    """Generate a run instance from a procedure template."""
    raise NotImplementedError


# ── Websites ──────────────────────────────────────────────────────────────────

def create_website(client: HuduClient, payload: CreateWebsitePayload) -> Website:
    raise NotImplementedError


# ── IPAM ──────────────────────────────────────────────────────────────────────

def create_vlan_zone(client: HuduClient, payload: CreateVlanZonePayload) -> VlanZone:
    raise NotImplementedError

def create_vlan(client: HuduClient, payload: CreateVlanPayload) -> Vlan:
    raise NotImplementedError

def create_network(client: HuduClient, payload: CreateNetworkPayload) -> Network:
    raise NotImplementedError

def create_ip_address(client: HuduClient, payload: CreateIpAddressPayload) -> IpAddress:
    raise NotImplementedError


# ── Photos ────────────────────────────────────────────────────────────────────

def create_photo_folder(client: HuduClient, name: str, company_id: Optional[int] = None) -> PhotoFolder:
    raise NotImplementedError

def create_photo(client: HuduClient, file_data: bytes, filename: str, content_type: str, company_id: Optional[int] = None, folder_id: Optional[int] = None, photoable_type: Optional[str] = None, photoable_id: Optional[int] = None, caption: Optional[str] = None, pinned: bool = False) -> Photo:
    raise NotImplementedError


# ── Assets ────────────────────────────────────────────────────────────────────

def create_asset(client: HuduClient, payload: CreateAssetPayload) -> Asset:
    raise NotImplementedError

def update_asset(client: HuduClient, asset_id: int, payload: CreateAssetPayload) -> Asset:
    raise NotImplementedError


# ── Racks ─────────────────────────────────────────────────────────────────────

def create_rack_storage(client: HuduClient, payload: CreateRackStoragePayload) -> RackStorage:
    raise NotImplementedError

def create_rack_storage_item(client: HuduClient, payload: CreateRackStorageItemPayload) -> RackStorageItem:
    raise NotImplementedError


# ── Relations ─────────────────────────────────────────────────────────────────

def create_relation(client: HuduClient, payload: CreateRelationPayload) -> Relation:
    raise NotImplementedError


# ── Flags ─────────────────────────────────────────────────────────────────────

def create_flag_type(client: HuduClient, payload: CreateFlagTypePayload) -> FlagType:
    raise NotImplementedError

def create_flag(client: HuduClient, payload: CreateFlagPayload) -> Flag:
    raise NotImplementedError
