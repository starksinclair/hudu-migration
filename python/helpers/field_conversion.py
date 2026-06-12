from typing import Optional, Union
from ..types.asset_layout import AssetLayoutField, LayoutFieldMap, ListMap
from ..types.asset import AssetFieldValue, AssetMap


def convert_to_hudu_plain_description(html: str) -> str:
    """Strip HTML tags and convert block elements (p, li, br, h1-h6, tr) to plain text."""
    raise NotImplementedError


def convert_to_hudu_api_string_flag(value: Union[bool, str, None]) -> str:
    """Convert a boolean or string value to 'true' | 'false' for the Hudu API."""
    raise NotImplementedError


def convert_to_migration_asset_layout_field(
    source_field: AssetLayoutField,
    list_map: ListMap,
    layout_map: dict[int, int],
) -> dict:
    """Map a source field definition to a target field definition, remapping list/layout IDs."""
    raise NotImplementedError


def convert_to_migration_asset_field_values(
    source_fields: list[AssetFieldValue],
    layout_field_map: LayoutFieldMap,
    list_map: ListMap,
    asset_map: AssetMap,
    exclude_asset_tags: bool,
) -> dict[str, Union[str, list[str]]]:
    """Extract custom field values, resolving AssetTag references and ListSelect options."""
    raise NotImplementedError


def convert_to_asset_custom_field_key(label: str) -> str:
    """Convert a field label to the API key format: lowercase with underscores."""
    raise NotImplementedError


def resolve_migration_list_select_value(
    value: str,
    available_options: list[str],
) -> Optional[str]:
    """Resolve smart aliases for ListSelect values (e.g. SMB -> SMB/CIFS, Smartphone -> Phone)."""
    raise NotImplementedError
