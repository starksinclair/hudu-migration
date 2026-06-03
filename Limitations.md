# Migration Limitations

Known limitations of `company-migration.ps1` — items that are either partially migrated, skipped entirely, or cannot be fully reconstructed via the Hudu API.

---

## Procedures

### Procedure run ↔ template relationship not preserved

Hudu tracks which template a run was started from internally. The API provides no way to set this link when creating a procedure via `New-HuduProcedure`. Runs will exist in the target instance but will appear as standalone runs rather than being associated with their source template.

### `-Run` flag depends on HuduAPI module support

The script passes `-Run $true` when creating procedure runs. If the installed version of the HuduAPI module does not expose this parameter on `New-HuduProcedure`, all runs will be created as templates. Check the output log — if runs and templates show the same type in the target, this is the cause.

### Task fields are partial

Only `name`, `description`, `position`, `parent_task_id`, and `completed` are carried over per task. Any other task fields (assignees, due dates, notes) that the Hudu API exposes are not migrated.

---

## Websites

Websites are migrated with name (URL), company, notes, paused state, DNS/SSL/Whois monitoring flags, and DMARC/DKIM/SPF flags when present. `Get-HuduWebsites` returns paginated API wrappers; the script unwraps the `websites` collection before processing.

Monitoring will resume on the target using the same flags as the source — pause monitors on the target first if you want a dry-run without alerts. ITGlue-Hudu-Migration maps IT Glue **domains** to websites with a `https://` prefix; this Hudu-to-Hudu step copies the source website name **as stored** (no URL rewriting).

---

## IPAM (Networks and IP Addresses)

Networks (subnets) are migrated with name, CIDR address, description, notes, company, and location. IP addresses within each network are migrated with address, name, description, notes, and status.

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

**Assets are not migrated** by this script. To get asset-linked rack placements, create the assets on the target first (same **name** as source), then re-run the migration or add items manually.

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

## What is not migrated at all

| Item                                  | Reason                                                                                                                                                                                                       |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Flexible asset layouts and assets** | Not implemented — layout field types, tag relations, and asset data require a separate migration phase. Rack items that reference assets are **skipped** until matching asset **names** exist on the target. Asset **flags** use the same name match. |
| **Contacts**                          | Not implemented                                                                                                                                                                                              |
| **Configurations**                    | Not implemented                                                                                                                                                                                              |
| **Magic Dash tiles**                  | No public API for Magic Dash items                                                                                                                                                                           |
| **Relations between records**         | Asset-to-asset and article-to-asset relations are not recreated                                                                                                                                              |

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

**Asset flags:** Assets are **not** bulk-migrated. A flag is applied only when a target asset in the same company matches the source asset by **name** (case-insensitive), **slug**, or **primary_serial**. If asset flags are skipped, create or sync matching assets on the target first (or add a dedicated asset migration step).

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
