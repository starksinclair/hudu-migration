from ..clients.hudu_client import HuduClient
from ..types.common import MigrationScope, Stats
from ..types.company import CompanyMap
from ..types.procedure import ProcedureMap


async def migrate_procedures(
    source: HuduClient,
    target: HuduClient,
    company_map: CompanyMap,
    stats: Stats,
    *,
    scope: MigrationScope,
    company_ids: list[int] | None = None,
) -> ProcedureMap:
    """Step 5 — Procedure templates, runs, and tasks (company scope)."""
    raise NotImplementedError
