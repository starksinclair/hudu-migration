"""Migration orchestrator — two-instance only; scope passed to each step."""

from __future__ import annotations

import argparse
import asyncio
import sys
from dataclasses import replace

from python.api.preflight import preflight_check

from .config import load_config, create_empty_stats
from .clients.hudu_client import HuduClient
from .helpers.company_selector import pick_company_ids
from .helpers.logging import write_log_section, write_log_skipped, write_stats_summary
from .scope import run_assets, run_layouts
from .types.common import InstanceConfig, MigrationScope, Stats

from .steps.migrate_companies import migrate_companies
from .steps.migrate_asset_layouts import (
    migrate_asset_layouts,
    AssetLayoutMigrationResult,
)
from .steps.migrate_folders import migrate_folders
from .steps.migrate_articles import migrate_articles
from .steps.migrate_passwords import migrate_passwords
from .steps.migrate_procedures import migrate_procedures
from .steps.migrate_websites import migrate_websites
from .steps.migrate_ipam import migrate_ipam
from .steps.migrate_photos import migrate_photos
from .steps.migrate_assets import migrate_assets
from .steps.migrate_racks import migrate_racks
from .steps.migrate_relations import migrate_relations, RelationMigrationMaps
from .steps.migrate_flags import migrate_flags, FlagMigrationMaps
from .types.ipam import IpamMaps


def _empty_layout_result() -> AssetLayoutMigrationResult:
    return AssetLayoutMigrationResult(
        layout_map={},
        layout_field_map={},
        list_map={},
    )


def _empty_ipam_maps() -> IpamMaps:
    return IpamMaps(
        vlan_zone_map={},
        vlan_map={},
        network_map={},
        ip_address_map={},
    )


async def run_migration(
    instance: InstanceConfig,
    scope: MigrationScope,
    company_ids: list[int] | None,
) -> Stats:
    stats = create_empty_stats()

    source = HuduClient(instance.source_base_url, instance.source_api_key)
    target = HuduClient(instance.target_base_url, instance.target_api_key)

    company_map: dict[int, int] = {}
    layout_result = _empty_layout_result()
    folder_map: dict[int, int] = {}
    article_map = {}
    password_folder_map = {}
    procedure_map = {}
    website_map = {}
    ipam_maps = _empty_ipam_maps()
    asset_map = {}
    rack_map = {}

    if scope == "company":
        write_log_section("Step 1: Companies")
        company_map = await migrate_companies(
            source, target, stats, scope=scope, company_ids=company_ids
        )
    else:
        write_log_skipped("Companies", "global scope")

    if run_layouts(scope, instance.skip_asset_migration):
        write_log_section("Step 2: Lists + Asset Layouts")
        layout_result = await migrate_asset_layouts(
            source, target, stats, scope=scope
        )
    else:
        write_log_skipped(
            "Asset layouts",
            "company scope or --skip-assets (run global phase first for layouts)",
        )

    write_log_section("Step 2a: Folders")
    folder_map = await migrate_folders(
        source, target, company_map, stats, scope=scope, company_ids=company_ids
    )

    write_log_section("Step 2b: Articles")
    article_map = await migrate_articles(
        source,
        target,
        company_map,
        folder_map,
        stats,
        scope=scope,
        company_ids=company_ids,
        max_file_size_mb=instance.max_file_size_mb,
    )

    write_log_section("Step 3: Passwords")
    password_folder_map = await migrate_passwords(
        source, target, company_map, stats, scope=scope, company_ids=company_ids
    )

    if scope == "company":
        write_log_section("Step 5: Procedures")
        procedure_map = await migrate_procedures(
            source, target, company_map, stats, scope=scope, company_ids=company_ids
        )

        write_log_section("Step 6: Websites")
        website_map = await migrate_websites(
            source, target, company_map, stats, scope=scope, company_ids=company_ids
        )

        write_log_section("Step 7: IPAM")
        ipam_maps = await migrate_ipam(
            source, target, company_map, stats, scope=scope, company_ids=company_ids
        )

        write_log_section("Step 8: Photos")
        await migrate_photos(
            source,
            target,
            company_map,
            folder_map,
            stats,
            scope=scope,
            company_ids=company_ids,
            max_file_size_mb=instance.max_file_size_mb,
        )
    else:
        write_log_skipped("Procedures, websites, IPAM, photos", "global scope")

    if run_assets(scope, instance.skip_asset_migration):
        write_log_section("Step 11: Assets")
        asset_map = await migrate_assets(
            source,
            target,
            company_map,
            layout_result.layout_map,
            layout_result.layout_field_map,
            layout_result.list_map,
            stats,
            scope=scope,
            company_ids=company_ids,
        )
    else:
        write_log_skipped("Assets", "global scope or --skip-assets")

    if scope == "company":
        write_log_section("Step 9: Racks")
        rack_map = await migrate_racks(
            source, target, company_map, asset_map, stats,
            scope=scope, company_ids=company_ids,
        )
    else:
        write_log_skipped("Racks", "global scope")

    if scope == "company" and run_assets(scope, instance.skip_asset_migration):
        write_log_section("Step 13: Relations")
        await migrate_relations(
            source,
            target,
            RelationMigrationMaps(
                company_map=company_map,
                article_map=article_map,
                asset_map=asset_map,
                website_map=website_map,
                password_folder_map=password_folder_map,
                procedure_map=procedure_map,
                ipam_maps=ipam_maps,
                rack_map=rack_map,
            ),
            stats,
            scope=scope,
            company_ids=company_ids,
        )
    else:
        write_log_skipped("Relations", "global scope or assets skipped")

    write_log_section("Step 14: Flags")
    await migrate_flags(
        source,
        target,
        FlagMigrationMaps(
            company_map=company_map,
            article_map=article_map,
            asset_map=asset_map,
            website_map=website_map,
            rack_map=rack_map,
        ),
        stats,
        scope=scope,
        company_ids=company_ids,
    )

    write_log_section("Migration Complete")
    write_stats_summary(stats)
    return stats


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Hudu-to-Hudu migration (Python — two-instance only)",
        epilog=(
            "Run --scope global first, then --scope company.\n"
            "Company scope prompts you to pick a company or migrate all."
        ),
    )
    parser.add_argument(
        "--scope",
        choices=("global", "company"),
        required=True,
        help="global: layouts + central KB  |  company: companies + assets + ...",
    )
    parser.add_argument(
        "--skip-assets",
        action="store_true",
        help="Skip asset layouts (global) and assets/relations (company).",
    )
    return parser.parse_args(argv)


def run_cli(argv: list[str] | None = None) -> None:
    args = _parse_args(argv)
    instance = load_config()
    if args.skip_assets:
        instance = replace(instance, skip_asset_migration=True)

    scope: MigrationScope = args.scope  # type: ignore[assignment]

    source = HuduClient(instance.source_base_url, instance.source_api_key)
    target = HuduClient(instance.target_base_url, instance.target_api_key)
    preflight_check(source, target) 

    company_ids: list[int] | None = None
    if scope == "company":
        company_ids = pick_company_ids(source)
        if company_ids == []:
            print("Nothing to migrate.", file=sys.stderr)
            sys.exit(1)

    try:
        asyncio.run(run_migration(instance, scope, company_ids))
    except Exception as exc:
        print(f"Migration failed: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    run_cli()
