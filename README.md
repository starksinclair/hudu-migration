# Hudu-to-Hudu Migration

PowerShell migration toolkit for moving data between **Hudu tenants** (source → target) using the [HuduAPI](https://www.powershellgallery.com/packages/HuduAPI) module (v2.4.5+).

The main entry point is `company-migration.ps1`, which orchestrates companies, asset layouts, knowledge base content, passwords, procedures, websites, IPAM, photo galleries, assets, rack storages, relations, and flags. A separate script, `Confluence-Migration.ps1`, handles Confluence → Hudu (different workflow).

## Overview

| Step | Phase             | What happens                                                               |
| ---- | ----------------- | -------------------------------------------------------------------------- |
| 1    | **Companies**     | Name, type, address, phone/fax, website, ID, notes, parent link → `CompanyMap` |
| 2    | **Lists + asset layouts** | Lists fetched by ID first, then layouts + ListSelect fields → `LayoutMap` |
| 3a   | **KB folders**    | Article folders only (photo folders handled later) → `FolderMap`           |
| 3b   | **Articles**      | Content, sharing, attachments (`public_photos` + `uploads`) → `ArticleMap` |
| 4    | **Passwords**     | Password folders + credentials (description, `login_url`; not vault `url`) |
| 5    | **URL relinking** | Internal article links and embed paths rewritten to target URLs            |
| 6    | **Procedures**    | Templates/runs and tasks                                                   |
| 7    | **Websites**      | URLs, notes, monitoring and DMARC/DKIM/SPF settings                        |
| 8    | **IPAM**          | VLAN zones, VLANs, networks (subnets), and IP addresses → `NetworkMap`     |
| 9    | **Photo gallery** | Company photo folders + gallery photos (`/api/v1/photos`)                  |
| 10   | **Assets**        | Company assets per layout + custom fields → `AssetMap`                     |
| 11   | **Racks**         | Rack storages and rack items (uses `AssetMap`) → `RackMap`                 |
| 12   | **Relations**     | Links between migrated assets, articles, passwords, etc.                   |
| 13   | **Flags**         | Flag types + flags on articles, assets, passwords, etc.                    |

**References used during development:**

- [ITGlue-Hudu-Migration](https://github.com/lwhitelock/ITGlue-Hudu-Migration) — attachment and migration patterns (reference only)
- [HuduAPI module](https://www.powershellgallery.com/packages/HuduAPI) — REST API wrapper

For gaps, intentional skips, and API caveats, see **[Limitations.md](Limitations.md)**. For contributor/AI context, see **[AGENT.md](AGENT.md)**.

## Requirements

- **PowerShell 7+** (uses `??` and other PS7 syntax)
- **HuduAPI** module v2.4.5 or later (`Install-Module HuduAPI -MinimumVersion 2.4.5`)
- API keys for **source** and **target** Hudu instances (admin-level recommended)
- Network access to both Hudu base URLs
- **Photo gallery step:** Hudu **≥ 2.41** with `Get-HuduPhotos` / `New-HuduPhoto` in your HuduAPI build

## Quick Start

```powershell
Install-Module HuduAPI -MinimumVersion 2.4.5 -Scope CurrentUser

cd path\to\hudu-migration
. .\company-migration.ps1
```

On launch, the script will:

1. Ask **how many Hudu instances** (`1` or `2`):
   - **2** — normal migration (source URL/key + target URL/key)
   - **1** — same-tenant **test mode** until a real target is available; one URL/key, and new records get a name suffix (default ` [MIG-TEST]`) via `Get-MigrationName` so creates do not hit “already exists” errors
2. Prompt for URL(s) and API key(s) (`SecureString`; never written to disk)
3. Open the **company selector** — WinForms on Windows, console menu on macOS/Linux
4. Run all migration steps in order (single company or all companies)
5. Write a timestamped log and optional phase JSON under the log directory (default: `~/HuduMigration/logs` on Mac/Linux, `%USERPROFILE%\HuduMigration\logs` on Windows)

### Optional parameters

Pre-set variables before dot-sourcing:

```powershell
# Optional: force same-instance test mode and custom suffix before dot-sourcing
$MigrationTestNameSuffix = ' [MIG-TEST]'

$SourceHuduUrl = "https://source.example.hudu.com"
$TargetHuduUrl = "https://target.example.hudu.com"
$SourceHuduApiKeySecure = Read-Host "Source API Key" -AsSecureString
$TargetHuduApiKeySecure = Read-Host "Target API Key" -AsSecureString
$MaxFileSizeMB = 100
$TempPath = "C:\Temp\HuduMigration\downloads"
$LogDir   = "C:\Temp\HuduMigration\logs"

. .\company-migration.ps1

# KB-only (no asset layouts, assets, or relations):
. .\company-migration.ps1 -SkipAssetMigration

# Two-phase production migration (recommended for source → target):
. .\company-migration.ps1 -MigrationScope Global    # once: layouts, central KB, flag types
. .\company-migration.ps1 -MigrationScope Company   # per company: everything else
```

Dot-source (`. .\company-migration.ps1`) is required so `$CompanyMap`, `$ArticleMap`, stats, and selector state persist in your session.

At startup you are asked for **migration scope** (`All` | `Global` | `Company`) unless `-MigrationScope` is passed. You are also asked whether to skip asset layouts (and assets/relations when applicable) unless `-SkipAssetMigration` is passed.

| Scope | What runs |
| ----- | --------- |
| **All** (default) | Full migration — same as before |
| **Global** | Asset layouts (+ lists), central KB folders/articles, relink, flag types, tenant-wide passwords; **no** company selector |
| **Company** | Companies, company KB, passwords, procedures, websites, IPAM, photos, assets, racks, relations, flags; **no** layouts or central KB |

## Features

- **MigrationScope** — `All`, `Global`, or `Company` to split tenant-wide vs per-company work across runs
- **SkipAssetMigration** — skip asset layouts (Global/All) and assets/relations (Company/All)
- **Single-instance test mode** — run against one tenant with suffixed names (`1` at startup)
- **Single-company test mode** — migrate one company before a full production run
- **Idempotent creates** — match existing target records by name (+ company) where possible before creating
- **Resume-friendly checkpoints** — phase mappings saved as JSON in `$LogDir` (e.g. `companies.json`, `folders.json`, `racks.json`)
- **Secure credentials** — API keys held as `SecureString` and disposed in `finally`
- **Article attachments** — `public_photos` (inline images) and `uploads` (files); skips over size limit (default 100 MB) with `skipped_files.csv`
- **URL relinking** — rewrites source article/base URLs and slug paths to target
- **Flag deduplication** — skips flags that already exist on the target (same object, type, and description)
- **Structured logging** — timestamped log plus end-of-run counters for every step

## Migration flow

```
START
  │
  ├─ Credentials + company selector (SINGLE | ALL)
  │
  ├─ 1. Companies          → CompanyMap
  ├─ 2. Asset layouts      → LayoutMap (+ LayoutFieldMap)
  ├─ 3a. KB folders        → FolderMap
  ├─ 3b. Articles + files  → ArticleMap
  ├─ 4. Passwords + password folders
  ├─ 5. Relink article HTML / embed URLs
  ├─ 6. Procedures + tasks
  ├─ 7. Websites
  ├─ 8. IPAM (VLAN zones, VLANs, networks, IPs) → NetworkMap
  ├─ 9. Company photo gallery + photo folders
  ├─ 10. Assets            → AssetMap
  ├─ 11. Rack storages + rack items → RackMap
  ├─ 12. Relations (Article, Asset, Password, Company, Website, Rack, Network)
  └─ 13. Flag types + flags (uses ArticleMap, AssetMap, RackMap)
  │
  SUMMARY + dispose API keys
```

Session variables after a successful run include `$CompanyMap`, `$LayoutMap`, `$FolderMap`, `$ArticleMap`, `$AssetMap`, `$NetworkMap`, and `$RackMap`.

## What is not migrated

These are **out of scope** for `company-migration.ps1` today (details in [Limitations.md](Limitations.md)):

| Item                            | Notes                                                                                                                                            |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Contacts / locations**        | Not implemented; IPAM `location_id` may be dangling on target                                                                                    |
| **Some relation endpoints**     | Procedure, IpAddress, Vlan, and similar types are skipped until those objects are mapped                                                         |
| **Configurations / Magic Dash** | Not implemented                                                                                                                                  |
| **Asset photos / comments**     | Layout flags are set; per-asset photos and comments are not bulk-migrated                                                                        |

## Flags and assets

- **Asset layouts** are created (or matched by name) before assets; **ListSelect** fields use a source→target list map.
- **Assets** are created per company with `custom_fields` keyed by layout field labels (snake_case). **AssetTag** field values and layout **linkable_id** fixes run in a second pass after layouts exist.
- **Rack items** prefer `AssetMap` (migrated IDs), then fall back to name match within the company.
- **Relations** remap endpoints when both sides resolve (`Asset`, `Article`, `AssetPassword`, `Company`, `Website`, `RackStorage`, `Network`).
- **Flag types** are matched on the target by name + color, or created if missing.
- **Flag instances** use `AssetMap` for assets, plus maps/lookups for articles, passwords, websites, racks, and companies.
- **Re-runs** skip duplicate flags via a target-side index (`FlagsDuplicatesSkipped` in the summary).

## Repository layout

```
hudu-migration/
├── company-migration.ps1     # Main orchestrator
├── Confluence-Migration.ps1  # Confluence → Hudu (separate flow)
├── AGENT.md                  # AI / contributor context
├── Limitations.md            # Known gaps and API limits
├── README.md                 # This file
├── steps/
│   ├── Helpers.ps1           # Logging, tenant switch, file upload, maps
│   ├── CompanySelector.ps1
│   ├── Migrate-Companies.ps1
│   ├── Migrate-AssetLayouts.ps1
│   ├── Migrate-Folders.ps1
│   ├── Migrate-Articles.ps1
│   ├── Migrate-Passwords.ps1
│   ├── Migrate-Relink.ps1
│   ├── Migrate-Procedures.ps1
│   ├── Migrate-Websites.ps1
│   ├── Migrate-IPAM.ps1
│   ├── Migrate-CompanyPhotos.ps1
│   ├── Migrate-Assets.ps1
│   ├── Migrate-Racks.ps1
│   ├── Migrate-Relations.ps1
│   └── Migrate-Flags.ps1
└── helpers/                  # Confluence helpers (not used by company-migration)
```

## Testing checklist

Use a **small test company** (roughly 10–50 articles) before a full run:

- [ ] Run in **single-company** mode
- [ ] Verify companies created or matched in target
- [ ] Confirm KB folders and articles (content, sharing, attachments)
- [ ] Spot-check passwords and password folders
- [ ] Click internal article links — should point to target URLs
- [ ] Confirm websites and IPAM if used in that company
- [ ] Check company photo gallery and rack layout if applicable
- [ ] Verify asset layouts, sample assets, and custom field values
- [ ] Spot-check relations (asset↔password, asset↔article) if used
- [ ] Review flags on articles and migrated assets
- [ ] Review log file, `skipped_files.csv` (if any), and phase JSON in `$LogDir`
- [ ] Re-run once to confirm duplicate flags are skipped (`FlagsDuplicatesSkipped`)
- [ ] Schedule **all-companies** migration after sign-off

## Known issues

Track run-specific findings in your team tracker. Standing limitations and workarounds are documented in **[Limitations.md](Limitations.md)** (racks, photos, websites, procedures, flags, resume behavior, HuduAPI version, etc.).

## Code review focus

1. `company-migration.ps1` — step order, stats (`IDictionary` binding), security
2. `steps/Migrate-Articles.ps1` — `public_photos` vs `uploads` routing
3. `steps/Migrate-Assets.ps1` / `Migrate-AssetLayouts.ps1` — field types, AssetTag second pass
4. `steps/Migrate-Racks.ps1` — `AssetMap` vs name fallback
5. `steps/Migrate-Relations.ps1` — endpoint types and dedupe
6. `steps/Migrate-Flags.ps1` — dedupe keys and `AssetMap`
7. `steps/Migrate-Passwords.ps1` — folder security and single-company filter

## References

- [HuduAPI on PowerShell Gallery](https://www.powershellgallery.com/packages/HuduAPI)
- [ITGlue-Hudu-Migration](https://github.com/lwhitelock/ITGlue-Hudu-Migration)
- [Hudu API documentation](https://www.hudu.com/api)
