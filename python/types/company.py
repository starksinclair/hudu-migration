from typing import TypedDict, NotRequired

class Company(TypedDict):
    id: int
    name: str
    nickname: NotRequired[str]
    company_type: NotRequired[str]
    address_line_1: NotRequired[str]
    address_line_2: NotRequired[str]
    city: NotRequired[str]
    state: NotRequired[str]
    zip: NotRequired[str]
    country_name: NotRequired[str]
    phone_number: NotRequired[str]
    fax_number: NotRequired[str]
    website: NotRequired[str]
    id_number: NotRequired[str]
    notes: NotRequired[str]
    parent_company_id: NotRequired[int]
    slug: NotRequired[str]


class CreateCompanyPayload(TypedDict, total=False):
    name: str
    nickname: str
    company_type: str
    address_line_1: str
    address_line_2: str
    city: str
    state: str
    zip: str
    country_name: str
    phone_number: str
    fax_number: str
    website: str
    id_number: str
    notes: str
    parent_company_id: int


# sourceId -> targetId
CompanyMap = dict[int, int]
