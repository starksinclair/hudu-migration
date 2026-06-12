"""Scope helpers for global vs company migration."""

from __future__ import annotations

from .types.common import MigrationScope


def is_global_record(company_id: int | None) -> bool:
    """True when a record belongs to central/tenant scope (no company)."""
    return company_id is None or company_id == 0


def is_company_in_scope(company_id: int | None, company_ids: list[int] | None) -> bool:
    """Filter company-scoped records when user picked specific company IDs."""
    if company_ids is None:
        return True
    if not company_ids:
        return False
    return company_id is not None and company_id in company_ids


def run_layouts(scope: MigrationScope, skip_asset_migration: bool) -> bool:
    return scope == "global" and not skip_asset_migration


def run_assets(scope: MigrationScope, skip_asset_migration: bool) -> bool:
    return scope == "company" and not skip_asset_migration
