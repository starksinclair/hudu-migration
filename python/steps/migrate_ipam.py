from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap
from ..types.ipam import IpamMaps


async def migrate_ipam(
    source: HuduClient,
    target: HuduClient,
    company_map: CompanyMap,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None = None,
) -> IpamMaps:
    """Step 7 — VLAN zones → VLANs → networks → IPs (company scope)."""
    raise NotImplementedError
