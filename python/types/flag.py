from typing import TypedDict, NotRequired, Literal

FlagableType = Literal[
    "Article", "Asset", "AssetPassword", "Company", "Website", "RackStorage"
]


class FlagType(TypedDict):
    id: int
    name: str
    color: str


class Flag(TypedDict):
    id: int
    flag_type_id: int
    flagable_type: FlagableType
    flagable_id: int
    description: NotRequired[str]


class CreateFlagTypePayload(TypedDict, total=False):
    name: str
    color: str


class CreateFlagPayload(TypedDict, total=False):
    flag_type_id: int
    flagable_type: FlagableType
    flagable_id: int
    description: str


# sourceId -> targetId
FlagTypeMap = dict[int, int]
