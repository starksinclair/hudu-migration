from typing import TypedDict, NotRequired


class HuduListItem(TypedDict):
    id: int
    value: str
    position: int


class HuduList(TypedDict):
    id: int
    name: str
    items: list[HuduListItem]


class CreateHuduListPayload(TypedDict, total=False):
    """POST /api/v1/lists — items are option names (become list_items_attributes)."""

    name: str
    items: list[str]


# sourceListId -> targetListId
ListMap = dict[int, int]

# sourceListItemId -> targetListItemId
ListItemMap = dict[int, int]
