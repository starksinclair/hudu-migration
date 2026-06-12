from typing import TypedDict, NotRequired, Literal, Union

FieldType = Literal["AssetTag", "ListSelect", "CheckBox", "Date", "Number", "Text"]


class AssetFieldValue(TypedDict):
    label: str
    field_type: FieldType
    value: Union[str, list[str], bool, int, None]


class Asset(TypedDict):
    id: int
    name: str
    asset_layout_id: int
    fields: list[AssetFieldValue]
    company_id: NotRequired[int]
    primary_serial: NotRequired[str]
    primary_mail: NotRequired[str]
    primary_model: NotRequired[str]
    primary_manufacturer: NotRequired[str]
    slug: NotRequired[str]


class CreateAssetPayload(TypedDict, total=False):
    name: str
    asset_layout_id: int
    company_id: int
    primary_serial: str
    primary_mail: str
    primary_model: str
    primary_manufacturer: str
    fields: dict[str, Union[str, list[str]]]


# sourceId -> targetId
AssetMap = dict[int, int]
