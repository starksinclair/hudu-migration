# Migration Limitations

Known limitations of `company-migration.ps1` — items that are either partially migrated, skipped entirely, or cannot be fully reconstructed via the Hudu API.

---

## Created / updated dates

The Hudu API does not expose a supported way to set **Date Created** or **Date Updated** on migrated records. New items on the target will show the migration run time in the UI, not the source dates.

---

## Procedures

### Procedure run ↔ template relationship not preserved

Hudu tracks which template a run was started from internally. The API provides no way to set this link when creating a procedure via `New-HuduProcedure`. Runs will exist in the target instance but will appear as standalone runs rather than being associated with their source template.

### Procedure runs use `Start-HuduProcedure`

HuduAPI 4.x creates **templates** with `New-HuduProcedure` only. **Runs** are started via `Start-HuduProcedure` (kickoff) after the matching template exists on the target. The API copies tasks from the template into the run — **do not** POST tasks to a run (`Procedure cannot add tasks to runs`). Subtasks on templates use `parent_task_id` via `New-MigrationProcedureTask` / `Invoke-HuduJsonApi`.

Run-specific task state (completed, assignees, due dates) from the source run is not replayed onto the new run.

### Task fields are partial

Only `name`, `description`, `position`, `parent_task_id`, and `completed` are carried over per task. Any other task fields (assignees, due dates, notes) that the Hudu API exposes are not migrated.

---

## Websites

Websites are migrated with name (URL), company, notes, paused state, DNS/SSL/Whois monitoring flags, and DMARC/DKIM/SPF flags when present. `Get-HuduWebsites` returns paginated API wrappers; the script unwraps the `websites` collection before processing.

Monitoring will resume on the target using the same flags as the source — pause monitors on the target first if you want a dry-run without alerts. ITGlue-Hudu-Migration maps IT Glue **domains** to websites with a `https://` prefix; this Hudu-to-Hudu step copies the source website name **as stored** (no URL rewriting).

---

## IPAM (VLAN Zones, VLANs, Networks, and IP Addresses)

**VLAN zones** are migrated first (name, description, `vlan_id_ranges`, company), then **VLANs** (name, numeric VLAN ID, description, notes, company, mapped `vlan_zone_id`, optional status/role list items). **Networks** (subnets) are migrated next and mapped by source ID. **IP addresses** are migrated last via `GET/POST /api/v1/ip_addresses` filtered by `network_id` (HuduAPI `Get-HuduIPAddresses` does not expose a `network_id` parameter).

Networks are migrated with name, CIDR address, company, and location. **Description** is plain text only (`ConvertTo-HuduPlainDescription` strips HTML). **Notes** (rich HTML) are sent via JSON `POST /api/v1/networks` when the source has `notes`; `New-HuduNetwork` does not accept `notes`. IP addresses are created with `address`, `network_id`, `company_id`, plain-text `description`, `notes`, `status`, and `fqdn` when present. IPs run for every mapped network (including networks that already existed on the target). Optional `asset_id` on IPs is not remapped unless the asset was migrated in the assets step.

### Location IDs are not remapped

Networks and IPs carry a `location_id` from the source. If locations were not migrated (contacts/locations are not in scope), the location reference on the target will be a dangling foreign key. The record will still be created but will not be linked to a location.

---

## Company Photos (Photo Gallery)

Company **Photo Gallery** uses `GET/POST /api/v1/photos` (`Get-HuduPhotos`, `New-HuduPhoto`), not `public_photos`. Each photo can include `folder_id` pointing at a **photo folder** (`folder_type: photo` on `/api/v1/folders`).

| Topic                | Limitation                                                                                                                                                                            |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **What is migrated** | Gallery photos with `photoable_type` **Company** for the mapped company; photo folders referenced by those photos (or marked `folder_type` photo).                                    |
| **Photo folders**    | Created via API with `folder_type: photo`. KB/article folders are migrated separately in step 2a (`Migrate-Folders.ps1` skips `folder_type` photo).                                   |
| **Not migrated**     | Photos attached to **assets** or **articles** via `photoable_type` (no asset/article migration). `public_photos` (rich-text embeds) are a different API — see article file migration. |
| **Hudu version**     | Requires Hudu **>= 2.41** and HuduAPI with `Get-HuduPhotos` / `New-HuduPhoto`.                                                                                                        |
| **Download**         | Uses `GET /api/v1/photos/{id}?download=true` (via `Get-HuduPhotos -Download`).                                                                                                        |
| **Re-run**           | No deduplication — re-running can duplicate folders and photos.                                                                                                                       |
| **Password folders** | Not migrated. ITGlue password folders are a separate IT Glue → Hudu flow.                                                                                                             |

---

## Racks (rack storages)

Racks are a **Hudu-to-Hudu only** feature. [ITGlue-Hudu-Migration](https://github.com/lwhitelock/ITGlue-Hudu-Migration) does **not** implement rack migration. The API uses `rack_storages` and `rack_storage_items` (not legacy `/api/v1/racks` or `rack_items`).

### Rack storages (partial)

Migrated via `Get-HuduRackStorages` / `New-HuduRackStorage` with name, company, height, width, description, max wattage, and starting unit.

| Topic                  | Limitation                                                                                                                                                 |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Location**           | `location_id` is **not copied** (locations are out of scope).                                                                                              |
| **Missing dimensions** | If height is missing or zero, **42U** is assumed. If width is missing or zero, **600** is assumed (required by `New-HuduRackStorage`).                     |
| **Other rack fields**  | Serial number, asset tag, utilization metrics, and similar read-only/UI fields are not migrated.                                                           |
| **Re-run behavior**    | An existing target rack with the same **name + company** is matched and skipped for creation, but **items are still processed** for that rack (see below). |

### Rack storage items (partial)

Items are read from the rack detail response (`front_items` / `rear_items` on `GET /rack_storages/{id}`), deduplicated by item id, with a fallback to the flat `GET /rack_storage_items` list when `rack_storage_id` is set.

| Item type                                  | Behavior                                                                                                                                                                                                  |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Asset-linked** (`asset_id` set)          | The target asset is matched **by asset name only** within the mapped company (any asset layout). If no asset with that name exists on the target, the item is **skipped** — not created as a placeholder. |
| **Reserved / placeholder** (no `asset_id`) | Migrated when `reserved_message` or `is_reserved` is present, with `status` set for reserved slots.                                                                                                       |

Run **asset migration** before racks so `AssetMap` is populated. Re-runs still have no rack-item deduplication.

### API / HuduAPI quirks (discovered during testing)

| Topic                         | Limitation                                                                                                                                                                                                                                                           |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`New-HuduRackStorageItem`** | Not used. The HuduAPI cmdlet always sends `rack_storage_role_id: 0` and omits `status`, which caused **HTTP 500** on some instances. Items are created via `Invoke-HuduJsonApi` with `rack_storage_role_id` omitted when absent on the source and `status` included. |
| **`rack_storage_role_id`**    | Many source placements have **no role** (`null`). When present, the numeric id is copied as-is; role definitions are **instance-specific** and may not exist on the target.                                                                                          |
| **`side`**                    | Source values like `"both"` are mapped to API side **0** (front). Rear-only semantics are not fully preserved.                                                                                                                                                       |
| **`status`**                  | Source string values (e.g. `"used"`) are mapped to integers for the API.                                                                                                                                                                                             |
| **Item re-runs**              | There is **no deduplication** of rack items on re-run. Re-migrating the same company can create **duplicate** placements on an existing rack.                                                                                                                        |
| **Module version**            | Requires `Get-HuduRackStorages`, `New-HuduRackStorage`, and `Get-HuduRackStorageItems` (HuduAPI **>= 2.4.5**). If cmdlets are missing, the step logs a warning and skips; other steps continue.                                                                      |

Phase mapping is saved to `logs/racks.json` (source rack id → target rack id) for reference; it is not used to resume item migration incrementally.

---

## Asset layouts and assets

**Asset layouts are tenant-wide**, not per company. The same layout definitions apply to every company; company pages show **assets** (records) grouped under whichever layouts are **active** for the instance.

**Asset layouts** run after companies. Each layout is created with `New-HuduAssetLayout` (or matched by suffixed name on the target). Fields are copied with types supported by `ConvertTo-MigrationAssetLayoutField` (`Text`, `RichText`, `Number`, `Checkbox`, `Date`, `ListSelect`, `AssetTag`, etc.).

| Topic | Limitation |
| ----- | ---------- |
| **Active flag** | Layouts created via API default to **inactive** until activated. The migration calls `Set-HuduAssetLayout -Active $true` when the source layout is active (most are). Inactive layouts do not appear in company sidebars. In **single-instance test mode**, you will see both original layouts and `[MIG-TEST]` layouts if both are active — open the migrated company and look for suffixed layout names. |
| **Admin folders** | `sidebar_folder_id` (Admin → Asset Layouts folder groupings) is not remapped; layouts may appear ungrouped until reorganized in admin. |
| **ListSelect** | Source list ids are mapped to target lists by **list name** (`Get-MigrationListMap`). Unmatched lists leave `list_id` unset. |
| **AssetTag layouts** | `linkable_id` pointing at another layout is remapped in a **second pass** via `Set-HuduAssetLayout` after all layouts exist. |
| **Skipped layouts** | If layout create fails, assets using that layout are skipped. |
| **Assets** | Per-company via `New-HuduAsset` with `custom_fields` from layout field **labels** (snake_case). Archived source assets are skipped. |
| **AssetTag values** | Linked asset ids use `AssetMap`; a second pass may call `Set-HuduAsset` when tag fields were empty on create. |
| **Not migrated** | Asset-level photos, files, comments, passwords embedded on assets, integrator **cards**, and `move_layout` history. |
| **Re-run** | Existing target asset matched by name (+ test suffix), slug, or primary serial is mapped and skipped for create. |

---

## Relations

Relations are read from source (`Get-HuduRelations`) and recreated with `New-HuduRelation` when **both** endpoints resolve on the target.

| Endpoint type | Resolution |
| ------------- | ---------- |
| `Asset` | `AssetMap` |
| `Article` | `ArticleMap` |
| `AssetPassword` | Password lookup by source id (name + company on target) |
| `Company` | `CompanyMap` |
| `Website` | Website lookup by source id |
| `RackStorage` | `RackMap` |
| `Network` | `NetworkMap` |
| `Procedure`, `IpAddress`, `Vlan`, `VlanZone`, `Folder`, … | **Skipped** — no ID map yet |

Duplicate relations (same endpoint pair, including Hudu’s auto-inverse) are skipped on re-run. `New-HuduRelation` returning null (duplicate API error) counts as skipped, not created.

---

## What is not migrated at all

| Item                                  | Reason                                                                                                                                                                                                       |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Contacts**                          | Not implemented                                                                                                                                                                                              |
| **Configurations**                    | Not implemented                                                                                                                                                                                              |
| **Magic Dash tiles**                  | No public API for Magic Dash items                                                                                                                                                                           |

---

## Passwords

Hudu returns two URL fields on password records:

| Field | Meaning |
| ----- | ------- |
| `url` | Link to the password record **in Hudu** (e.g. `https://tenant.hudu.com/passwords/{slug}`) — not copied as the login URL |
| `login_url` | Actual site or resource URL (e.g. iDRAC, RDP gateway) — migrated when present |

`Get-MigrationPasswordLoginUrl` prefers `login_url`, falls back to `url` only when it is not a `/passwords/{slug}` vault link, and drops links that still point at another Hudu instance’s password vault (e.g. `docs.msp4.com/passwords/...`). Non-vault links on the **source** host are rewritten to the **target** base URL when source and target differ.

**API:** Company/password vault records use **`/api/v1/asset_passwords`** (list/create/update), not `/api/v1/passwords`. The UI may still show paths under `/passwords/{slug}`. Migration creates records with **`New-HuduPassword`** (`Description`, `URL` for the login link, `PasswordFolderId`, etc.), which wraps that API.

---

## Flags

Flag **types** are matched on the target by name + color; missing types are created with `New-HuduFlagType`. Flag **instances** copy `description`, remapped `flag_type_id`, and the target `flagable_id`.

| `flagable_type` | How the target object is resolved |
| --------------- | --------------------------------- |
| `Article` | `ArticleMap` from article migration |
| `Asset` | Same-company asset matched **by name** (assets are not bulk-migrated) |
| `AssetPassword` | Password matched by name + company (+ username/URL when present) |
| `Company` | `CompanyMap` |
| `Website` | Website matched by display name + company |
| `RackStorage` | `RackMap` from rack migration |
| Other (`Procedure`, `Network`, `IpAddress`, `Vlan`, …) | Skipped — no ID map for those objects yet |

Flags run **after** rack migration so rack-backed flags can resolve.

**Dedupe:** Before creating a flag, the script indexes existing target flags by `flagable_type`, `flagable_id`, `flag_type_id`, and normalized `description`. Re-runs skip matches (counter: `FlagsDuplicatesSkipped`).

**Asset flags:** Prefer **`AssetMap`**. If the asset was not migrated, the same name/slug/serial fallback applies within the mapped company.

---

## Single-instance test mode (`MigrationInstanceCount = 1`)

Use when source and target are the **same** Hudu tenant (no second instance yet). The orchestrator prompts for `1` or `2` at startup.

- One URL and API key; `Get-MigrationName` adds a suffix (default ` [MIG-TEST]`) to **names** on create and on idempotent lookups (companies, folders, articles, passwords, procedures, websites, networks, racks, photo folders, flag types).
- Original records are left unchanged; duplicate companies/articles/etc. are created alongside them under the mapped **new** company ID.
- **Asset layouts and assets** get the test suffix on **names**; layout/field structure is still created.
- **Asset flags** on suffixed test assets resolve via `AssetMap` after asset migration.

Override suffix before dot-sourcing: `$MigrationTestNameSuffix = ' [MY-TEST]'`.

---

## General

### No parallelism

All API calls are sequential. Large instances with thousands of articles or procedures will run slowly. There is no built-in rate-limit backoff — if the source or target API starts returning 429s the script will fail on that item and continue.

### Resume is not fully incremental

The script checks for existing records by name match before creating them (idempotent), so re-running is safe. However, there is no checkpoint file between steps — if the script crashes mid-run, it will re-attempt all records in every prior step when restarted, not pick up from the exact failure point.

### HuduAPI module version

Requires HuduAPI >= 2.4.5. Older versions may be missing cmdlets used by this script (`New-HuduProcedure`, `New-HuduProcedureTask`, `Set-HuduProcedureTask`, `Get-HuduRackStorages`, `Get-HuduIPAddresses`).

### PowerShell 7+ required

The null-coalescing operator (`??`) and other syntax used throughout the script are not available in Windows PowerShell 5.x.
