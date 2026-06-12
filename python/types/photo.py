from typing import TypedDict, NotRequired, Literal

PhotoableType = Literal[
    "Article", "Asset", "AssetPassword", "Company", "Website", "RackStorage"
]


class PhotoFolder(TypedDict):
    id: int
    name: str
    folder_type: Literal["photo"]
    company_id: NotRequired[int]


class Photo(TypedDict):
    id: int
    photoable_type: PhotoableType
    photoable_id: int
    pinned: bool
    caption: NotRequired[str]
    company_id: NotRequired[int]
    folder_id: NotRequired[int]
    url: NotRequired[str]
    path: NotRequired[str]


# sourceId -> targetId
PhotoFolderMap = dict[int, int]
