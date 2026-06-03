# Hudu-to-Hudu Migration

PowerShell migration toolkit for moving data between **Hudu tenants** (source → target) using the [HuduAPI](https://www.powershellgallery.com/packages/HuduAPI) module (v2.4.5+).

The main entry point is `company-migration.ps1`, which orchestrates companies, knowledge base content, passwords, procedures, websites, IPAM, photo galleries, rack storages, and flags. A separate script, `Confluence-Migration.ps1`, handles Confluence → Hudu (different workflow).

## Overview

| Step | Phase             | What happens                                                               |
| ---- | ----------------- | -------------------------------------------------------------------------- |
| 1    | **Companies**     | Fetched from source; created or matched in target → `CompanyMap`           |
| 2a   | **KB folders**    | Article folders only (photo folders handled later) → `FolderMap`           |
| 2b   | **Articles**      | Content, sharing, attachments (`public_photos` + `uploads`) → `ArticleMap` |
| 3    | **Passwords**     | Password folders + credential records (idempotent by name/company)         |
| 4    | **URL relinking** | Internal article links and embed paths rewritten to target URLs            |
| 5    | **Procedures**    | Templates/runs and tasks                                                   |
| 6    | **Websites**      | URLs, notes, monitoring and DMARC/DKIM/SPF settings                        |
| 7    | **IPAM**          | Networks (subnets) and IP addresses → `NetworkMap`                         |
| 8    | **Photo gallery** | Company photo folders + gallery photos (`/api/v1/photos`)                  |
| 9    | **Racks**         | Rack storages and rack items → `RackMap`                                   |
| 10   | **Flags**         | Flag types + flags on articles, assets, passwords, etc.                    |

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

1. Prompt for source and target Hudu URLs and API keys (`SecureString`; never written to disk)
2. Open the **company selector** — WinForms on Windows, console menu on macOS/Linux
3. Run all migration steps in order (single company or all companies)
4. Write a timestamped log and optional phase JSON under the log directory (default: `~/HuduMigration/logs` on Mac/Linux, `%USERPROFILE%\HuduMigration\logs` on Windows)

### Optional parameters

Pre-set variables before dot-sourcing:

```powershell
$SourceHuduUrl = "https://source.example.hudu.com"
$TargetHuduUrl = "https://target.example.hudu.com"
$SourceHuduApiKeySecure = Read-Host "Source API Key" -AsSecureString
$TargetHuduApiKeySecure = Read-Host "Target API Key" -AsSecureString
$MaxFileSizeMB = 100
$TempPath = "C:\Temp\HuduMigration\downloads"
$LogDir   = "C:\Temp\HuduMigration\logs"

. .\company-migration.ps1
```

Dot-source (`. .\company-migration.ps1`) is required so `$CompanyMap`, `$ArticleMap`, stats, and selector state persist in your session.

## Features

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
  ├─ 2a. KB folders        → FolderMap
  ├─ 2b. Articles + files  → ArticleMap
  ├─ 3. Passwords + password folders
  ├─ 4. Relink article HTML / embed URLs
  ├─ 5. Procedures + tasks
  ├─ 6. Websites
  ├─ 7. IPAM (networks + IPs) → NetworkMap
  ├─ 8. Company photo gallery + photo folders
  ├─ 9. Rack storages + rack items → RackMap
  └─ 10. Flag types + flags (uses ArticleMap, RackMap; asset flags match by name/slug/serial)
  │
  SUMMARY + dispose API keys
```

Session variables after a successful run include `$CompanyMap`, `$FolderMap`, `$ArticleMap`, `$NetworkMap`, and `$RackMap`.

## What is not migrated

These are **out of scope** for `company-migration.ps1` today (details in [Limitations.md](Limitations.md)):

| Item                            | Notes                                                                                                                                            |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Flexible assets (bulk)**      | Layouts and asset records are not created; rack items and **asset flags** only work when a target asset already matches by name, slug, or serial |
| **Contacts / locations**        | Not implemented; IPAM `location_id` may be dangling on target                                                                                    |
| **Relations**                   | Asset↔password / asset↔asset links are not recreated                                                                                           |
| **Configurations / Magic Dash** | Not implemented                                                                                                                                  |

## Flags and asset flags

- **Flag types** are matched on the target by name + color, or created if missing.
- **Flag instances** are attached to migrated objects using ID maps (`Article`, `Company`, `RackStorage`, etc.) or lookups (passwords, websites).
- **Re-runs** skip duplicates via a target-side index (`FlagsDuplicatesSkipped` in the summary).
- **Asset flags** require a matching asset on the target in the same company; the script does not create assets. Check the log for `Asset map for company X -> Y: N matched`.

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
│   ├── Migrate-Folders.ps1
│   ├── Migrate-Articles.ps1
│   ├── Migrate-Passwords.ps1
│   ├── Migrate-Relink.ps1
│   ├── Migrate-Procedures.ps1
│   ├── Migrate-Websites.ps1
│   ├── Migrate-IPAM.ps1
│   ├── Migrate-CompanyPhotos.ps1
│   ├── Migrate-Racks.ps1
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
- [ ] Review flags on articles; for asset flags, confirm matching assets exist on target
- [ ] Review log file, `skipped_files.csv` (if any), and phase JSON in `$LogDir`
- [ ] Re-run once to confirm duplicate flags are skipped (`FlagsDuplicatesSkipped`)
- [ ] Schedule **all-companies** migration after sign-off

## Known issues

Track run-specific findings in your team tracker. Standing limitations and workarounds are documented in **[Limitations.md](Limitations.md)** (racks, photos, websites, procedures, flags, resume behavior, HuduAPI version, etc.).

## Code review focus

1. `company-migration.ps1` — step order, stats (`IDictionary` binding), security
2. `steps/Migrate-Articles.ps1` — `public_photos` vs `uploads` routing
3. `steps/Migrate-Racks.ps1` — asset-linked items when no name match
4. `steps/Migrate-Flags.ps1` — dedupe keys and asset matching
5. `steps/Migrate-Passwords.ps1` — folder security and single-company filter

## References

- [HuduAPI on PowerShell Gallery](https://www.powershellgallery.com/packages/HuduAPI)
- [ITGlue-Hudu-Migration](https://github.com/lwhitelock/ITGlue-Hudu-Migration)
- [Hudu API documentation](https://www.hudu.com/api)
