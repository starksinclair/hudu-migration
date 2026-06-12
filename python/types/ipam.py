from typing import TypedDict, NotRequired, Literal
from dataclasses import dataclass

IpAddressStatus = Literal["available", "reserved", "used"]


class VlanZone(TypedDict):
    id: int
    name: str
    description: NotRequired[str]
    company_id: NotRequired[int]
    vlan_id_ranges: NotRequired[str]


class CreateVlanZonePayload(TypedDict, total=False):
    name: str
    description: str
    company_id: int
    vlan_id_ranges: str


class CreateVlanPayload(TypedDict, total=False):
    name: str
    vlan_id: int
    description: str
    notes: str
    company_id: int
    vlan_zone_id: int


class CreateNetworkPayload(TypedDict, total=False):
    name: str
    address: str
    description: str
    notes: str
    company_id: int
    location_id: int


class CreateIpAddressPayload(TypedDict, total=False):
    address: str
    network_id: int
    company_id: int
    description: str
    notes: str
    fqdn: str
    status: IpAddressStatus


class Vlan(TypedDict):
    id: int
    name: str
    vlan_id: int
    description: NotRequired[str]
    notes: NotRequired[str]
    company_id: NotRequired[int]
    vlan_zone_id: NotRequired[int]
    status_list_item_id: NotRequired[int]
    role_list_item_id: NotRequired[int]


class Network(TypedDict):
    id: int
    name: str
    address: str
    description: NotRequired[str]
    notes: NotRequired[str]
    company_id: NotRequired[int]
    location_id: NotRequired[int]


class IpAddress(TypedDict):
    id: int
    address: str
    description: NotRequired[str]
    notes: NotRequired[str]
    fqdn: NotRequired[str]
    status: NotRequired[IpAddressStatus]
    network_id: NotRequired[int]
    company_id: NotRequired[int]
    skip_dns_validation: NotRequired[bool]


# sourceId -> targetId
VlanZoneMap = dict[int, int]
VlanMap = dict[int, int]
NetworkMap = dict[int, int]
IpAddressMap = dict[int, int]


@dataclass
class IpamMaps:
    vlan_zone_map: VlanZoneMap
    vlan_map: VlanMap
    network_map: NetworkMap
    ip_address_map: IpAddressMap
