"""Interactive company selection after listing source companies via API."""

from __future__ import annotations

from ..api.importers import get_companies
from ..clients.hudu_client import HuduClient
from ..types.company import Company


def pick_company_ids(source: HuduClient) -> list[int] | None:
    """List companies from source and prompt the user to pick one or all.

    Returns:
        None — migrate all companies
        [id] — single company selected
        [] — no companies on source (caller should abort)
    """
    print("\nFetching companies from source instance...")
    companies: list[Company] = get_companies(source)

    if not companies:
        print("No companies found on source instance.")
        return []

    companies = sorted(companies, key=lambda c: (c.get("name") or "").lower())
    print(f"\nFound {len(companies)} {'company' if len(companies) == 1 else 'companies'}:\n")
    for i, company in enumerate(companies, 1):
        print(f"  {i:>3}.  {company['name']}  (id: {company['id']})")
    print("\n    0.  All companies\n")

    while True:
        raw = input("Select a company to migrate [0 for all]: ").strip().lower()
        if raw in ("0", "", "all"):
            print("\nMigrating all companies.\n")
            return None
        try:
            idx = int(raw)
            if 1 <= idx <= len(companies):
                selected = companies[idx - 1]
                print(f"\nSelected: {selected['name']} (id: {selected['id']})\n")
                return [int(selected["id"])]
        except ValueError:
            pass
        print(f"  Enter a number between 0 and {len(companies)}, or 0 for all.")
