from typing import TypedDict, NotRequired, Literal

AssetFieldType = Literal["AssetTag", "ListSelect", "CheckBox", "Date", "Number", "Text"]


class AssetLayoutField(TypedDict):
    id: int
    label: str
    field_type: AssetFieldType
    show_in_list: bool
    required: bool
    position: int
    expiration: bool
    multiple_options: bool
    hint: NotRequired[str]
    min: NotRequired[int]
    max: NotRequired[int]
    options: NotRequired[str]
    list_id: NotRequired[int]
    linkable_id: NotRequired[int]


class AssetLayout(TypedDict):
    id: int
    name: str
    include_passwords: bool
    include_photos: bool
    include_comments: bool
    include_files: bool
    active: bool
    fields: list[AssetLayoutField]
    icon: NotRequired[str]
    color: NotRequired[str]
    icon_color: NotRequired[str]
    slug: NotRequired[str]
    sidebar_folder_id: NotRequired[int]


class CreateAssetLayoutFieldPayload(TypedDict, total=False):
    label: str
    field_type: AssetFieldType
    show_in_list: bool
    required: bool
    position: int
    hint: str
    min: int
    max: int
    options: str
    list_id: int
    linkable_id: int
    multiple_options: bool
    expiration: bool


class CreateAssetLayoutPayload(TypedDict, total=False):
    name: str
    icon: str
    color: str
    icon_color: str
    include_passwords: bool
    include_photos: bool
    include_comments: bool
    include_files: bool
    active: bool
    sidebar_folder_id: int
    fields: list[CreateAssetLayoutFieldPayload]


class SidebarFolder(TypedDict):
    id: int
    name: str
    parent_folder_id: NotRequired[int]


# sourceLayoutId -> targetLayoutId
LayoutMap = dict[int, int]

# sourceFieldId -> targetFieldId
LayoutFieldMap = dict[int, int]

# sourceListId -> targetListId
ListMap = dict[int, int]
