from typing import TypedDict, NotRequired, Literal

FolderType = Literal["article", "photo", "asset_layout"]


class Folder(TypedDict):
    id: int
    name: str
    description: NotRequired[str]
    company_id: NotRequired[int]
    parent_folder_id: NotRequired[int]
    folder_type: NotRequired[FolderType]


class CreateFolderPayload(TypedDict, total=False):
    name: str
    description: str
    company_id: int
    parent_folder_id: int
    folder_type: FolderType


# sourceId -> targetId
FolderMap = dict[int, int]
