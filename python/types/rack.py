from typing import TypedDict, NotRequired, Literal

RackSide = Literal[0, 1]    # 0 = front, 1 = rear
RackStatus = Literal[0, 1]  # 0 = reserved/available, 1 = occupied


class RackStorage(TypedDict):
    id: int
    name: str
    height: int
    width: int
    starting_unit: int
    description: NotRequired[str]
    company_id: NotRequired[int]
    max_wattage: NotRequired[int]


class RackStorageItem(TypedDict):
    id: int
    rack_storage_id: int
    start_unit: int
    end_unit: int
    status: RackStatus
    side: RackSide
    company_id: NotRequired[int]
    asset_id: NotRequired[int]
    rack_storage_role_id: NotRequired[int]
    max_wattage: NotRequired[int]
    power_draw: NotRequired[int]
    reserved_message: NotRequired[str]


class CreateRackStoragePayload(TypedDict, total=False):
    name: str
    company_id: int
    description: str
    height: int
    width: int
    max_wattage: int
    starting_unit: int


class CreateRackStorageItemPayload(TypedDict, total=False):
    rack_storage_id: int
    start_unit: int
    end_unit: int
    company_id: int
    asset_id: int
    rack_storage_role_id: int
    status: RackStatus
    side: RackSide
    max_wattage: int
    power_draw: int
    reserved_message: str


# sourceId -> targetId
RackMap = dict[int, int]
