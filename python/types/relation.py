from typing import TypedDict, NotRequired, Literal

RelationType = Literal[
    "AssetPassword",
    "RackStorage",
    "IpAddress",
    "VlanZone",
    "Article",
    "Company",
    "Website",
    "Network",
    "Asset",
    "Procedure",
    "Vlan",
]


class Relation(TypedDict):
    id: int
    fromable_type: RelationType
    fromable_id: int
    toable_type: RelationType
    toable_id: int
    description: NotRequired[str]


class CreateRelationPayload(TypedDict, total=False):
    fromable_type: RelationType
    fromable_id: int
    toable_type: RelationType
    toable_id: int
    description: str
