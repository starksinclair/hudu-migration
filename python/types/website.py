from typing import TypedDict, NotRequired


class Website(TypedDict):
    id: int
    name: str
    paused: bool
    disable_dns: bool
    disable_ssl: bool
    disable_whois: bool
    enable_dmarc_tracking: bool
    enable_dkim_tracking: bool
    enable_spf_tracking: bool
    company_id: NotRequired[int]
    notes: NotRequired[str]
    slug: NotRequired[str]


class CreateWebsitePayload(TypedDict, total=False):
    name: str
    company_id: int
    notes: str
    paused: bool
    disable_dns: bool
    disable_ssl: bool
    disable_whois: bool
    enable_dmarc_tracking: bool
    enable_dkim_tracking: bool
    enable_spf_tracking: bool


# sourceId -> targetId
WebsiteMap = dict[int, int]
