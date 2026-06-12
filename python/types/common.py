from dataclasses import dataclass
from typing import Literal, Optional

MigrationScope = Literal["global", "company"]


@dataclass
class InstanceConfig:
    """Source/target credentials and run settings (from .env). Two-instance only."""

    source_api_key: str
    source_base_url: str
    target_api_key: str
    target_base_url: str
    max_file_size_mb: int = 100
    skip_asset_migration: bool = False


@dataclass
class Stats:
    companies_created: int = 0
    companies_skipped: int = 0
    companies_failed: int = 0

    asset_layouts_created: int = 0
    asset_layouts_skipped: int = 0
    asset_layouts_failed: int = 0

    folders_created: int = 0
    folders_failed: int = 0

    articles_created: int = 0
    articles_skipped: int = 0
    articles_failed: int = 0

    files_uploaded: int = 0
    files_skipped: int = 0
    files_failed: int = 0

    passwords_created: int = 0
    passwords_skipped: int = 0
    passwords_failed: int = 0

    password_folders_created: int = 0
    password_folders_skipped: int = 0
    password_folders_failed: int = 0

    procedures_created: int = 0
    procedures_skipped: int = 0
    procedures_failed: int = 0

    tasks_created: int = 0
    tasks_failed: int = 0

    websites_created: int = 0
    websites_skipped: int = 0
    websites_failed: int = 0

    networks_created: int = 0
    networks_skipped: int = 0
    networks_failed: int = 0

    vlan_zones_created: int = 0
    vlan_zones_skipped: int = 0
    vlan_zones_failed: int = 0

    vlans_created: int = 0
    vlans_skipped: int = 0
    vlans_failed: int = 0

    ips_created: int = 0
    ips_skipped: int = 0
    ips_failed: int = 0

    photo_folders_created: int = 0
    photo_folders_skipped: int = 0
    photo_folders_failed: int = 0

    photos_uploaded: int = 0
    photos_failed: int = 0

    racks_created: int = 0
    racks_skipped: int = 0
    racks_failed: int = 0

    rack_items_created: int = 0
    rack_items_failed: int = 0

    assets_created: int = 0
    assets_skipped: int = 0
    assets_failed: int = 0

    relations_created: int = 0
    relations_skipped: int = 0
    relations_failed: int = 0

    flag_types_created: int = 0
    flag_types_skipped: int = 0
    flag_types_failed: int = 0

    flags_created: int = 0
    flags_skipped: int = 0
    flags_duplicates_skipped: int = 0
    flags_failed: int = 0
