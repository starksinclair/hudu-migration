from typing import Optional
from ..clients.hudu_client import HuduClient
from ..types.company import Company
from ..types.article import Article
from ..types.asset_layout import AssetLayout, SidebarFolder
from ..types.folder import Folder, FolderType
from ..types.password import Password, PasswordFolder
from ..types.procedure import Procedure, ProcedureTask
from ..types.website import Website
from ..types.ipam import VlanZone, Vlan, Network, IpAddress
from ..types.photo import Photo, PhotoFolder
from ..types.asset import Asset
from ..types.rack import RackStorage, RackStorageItem
from ..types.relation import Relation
from ..types.flag import Flag, FlagType
from ..types.list import HuduList


# ── Companies ─────────────────────────────────────────────────────────────────

def get_companies(client: HuduClient) -> list[Company]:
    return client.get_all_pages("/api/v1/companies", "companies")

def get_company(client: HuduClient, company_id: int) -> Company:
    response = client.get(f"/api/v1/companies/{company_id}")
    return response["company"]


# ── Articles ──────────────────────────────────────────────────────────────────

def get_articles(client: HuduClient, company_id: Optional[int] = None) -> list[Article]:
    params = {"company_id": company_id} if company_id is not None else None
    # Hudu handles generic queries via optional URL parameters or global collection routes
    return client.get_all_pages("/api/v1/articles", "articles")


def get_article(client: HuduClient, article_id: int) -> Article:
    response = client.get(f"/api/v1/articles/{article_id}")
    return response["article"]


# ── Asset Layouts ─────────────────────────────────────────────────────────────

def get_asset_layouts(client: HuduClient) -> list[AssetLayout]:
    return client.get_all_pages("/api/v1/asset_layouts", "asset_layouts")

def get_asset_layout(client: HuduClient, layout_id: int) -> AssetLayout:
    response = client.get(f"/api/v1/asset_layouts/{layout_id}")
    return response["asset_layout"]

def get_lists(client: HuduClient) -> list[HuduList]:
    return client.get_all_pages("/api/v1/lists", "lists")

def get_sidebar_folders(client: HuduClient) -> list[SidebarFolder]:
    return client.get_all_pages("/api/v1/sidebar_folders", "sidebar_folders")


# ── Folders ───────────────────────────────────────────────────────────────────

def get_folders(client: HuduClient, company_id: Optional[int] = None, folder_type: Optional[FolderType] = None) -> list[Folder]:
    params = {}
    if company_id is not None:
        params["company_id"] = company_id
    if folder_type is not None:
        params["folder_type"] = folder_type
    
    # Passing dynamic params dictionary straight down into our underlying get pipeline
    url = "/api/v1/folders"
    if params:
        encoded_query = f"?{client.get(url, params=params)}" # Fallback wrapper adjustment if needed
    return client.get_all_pages(url, "folders")


# ── Passwords ─────────────────────────────────────────────────────────────────

def get_password_folders(client: HuduClient, company_id: Optional[int] = None) -> list[PasswordFolder]:
    # Passwords context maps directly to asset_passwords sub-properties inside structural lists
    return client.get_all_pages("/api/v1/password_folders", "password_folders")

def get_passwords(client: HuduClient, company_id: Optional[int] = None) -> list[Password]:
    return client.get_all_pages("/api/v1/asset_passwords", "asset_passwords")


# ── Procedures ────────────────────────────────────────────────────────────────

def get_procedures(client: HuduClient, company_id: Optional[int] = None) -> list[Procedure]:
    return client.get_all_pages("/api/v1/procedures", "procedures")

def get_procedure_tasks(client: HuduClient, procedure_id: int) -> list[ProcedureTask]:
    # Procedure steps are evaluated relative to individual templates or process definitions
    return client.get_all_pages("/api/v1/procedure_tasks", "procedure_tasks")


# ── Websites ──────────────────────────────────────────────────────────────────

def get_websites(client: HuduClient, company_id: Optional[int] = None) -> list[Website]:
    return client.get_all_pages("/api/v1/websites", "websites")


# ── IPAM ──────────────────────────────────────────────────────────────────────

def get_vlan_zones(client: HuduClient, company_id: Optional[int] = None) -> list[VlanZone]:
    return client.get_all_pages("/api/v1/vlan_zones", "vlan_zones")

def get_vlans(client: HuduClient, company_id: Optional[int] = None) -> list[Vlan]:
    return client.get_all_pages("/api/v1/vlans", "vlans")

def get_networks(client: HuduClient, company_id: Optional[int] = None) -> list[Network]:
    return client.get_all_pages("/api/v1/networks", "networks")

def get_ip_addresses(client: HuduClient, network_id: Optional[int] = None, company_id: Optional[int] = None) -> list[IpAddress]:
    return client.get_all_pages("/api/v1/ip_addresses", "ip_addresses")


# ── Photos ────────────────────────────────────────────────────────────────────

def get_photo_folders(client: HuduClient, company_id: Optional[int] = None) -> list[PhotoFolder]:
    return client.get_all_pages("/api/v1/photo_folders", "photo_folders")

def get_photos(client: HuduClient, company_id: Optional[int] = None) -> list[Photo]:
    return client.get_all_pages("/api/v1/photos", "photos")


# ── Assets ────────────────────────────────────────────────────────────────────

def get_assets(client: HuduClient, company_id: Optional[int] = None, asset_layout_id: Optional[int] = None) -> list[Asset]:
    # Route context optimization: If we target a specific client, use the optimized company endpoint context
    if company_id is not None:
        return client.get_all_pages(f"/api/v1/companies/{company_id}/assets", "assets")
    return client.get_all_pages("/api/v1/assets", "assets")

def get_asset(client: HuduClient, asset_id: int) -> Asset:
    # Asset structural details requires targeted retrieval wrapper parsing logic 
    response = client.get(f"/api/v1/assets/{asset_id}")
    return response["asset"]


# ── Racks ─────────────────────────────────────────────────────────────────────

def get_rack_storages(client: HuduClient, company_id: Optional[int] = None) -> list[RackStorage]:
    return client.get_all_pages("/api/v1/rack_storages", "rack_storages")

def get_rack_storage_items(client: HuduClient, rack_storage_id: int) -> list[RackStorageItem]:
    return client.get_all_pages("/api/v1/rack_storage_items", "rack_storage_items")


# ── Relations ─────────────────────────────────────────────────────────────────

def get_relations(client: HuduClient, company_id: Optional[int] = None) -> list[Relation]:
    return client.get_all_pages("/api/v1/relations", "relations")


# ── Flags ─────────────────────────────────────────────────────────────────────

def get_flag_types(client: HuduClient) -> list[FlagType]:
    return client.get_all_pages("/api/v1/flag_types", "flag_types")

def get_flags(client: HuduClient, company_id: Optional[int] = None) -> list[Flag]:
    return client.get_all_pages("/api/v1/flags", "flags")