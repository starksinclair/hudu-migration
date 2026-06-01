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

Websites are migrated with name, company, notes, paused state, and the DNS/SSL/Whois monitoring flags. Monitoring will resume immediately on the target instance using the same flags as the source — pause all monitors on the target first if you want to do a dry-run without triggering alerts.

---

## IPAM (Networks and IP Addresses)

Networks (subnets) are migrated with name, CIDR address, description, notes, company, and location. IP addresses within each network are migrated with address, name, description, notes, and status.

### Location IDs are not remapped

Networks and IPs carry a `location_id` from the source. If locations were not migrated (contacts/locations are not in scope), the location reference on the target will be a dangling foreign key. The record will still be created but will not be linked to a location.

---

## Company Photos

Public photos attached to companies are downloaded from the source instance and re-uploaded to the matching target company via `New-HuduPublicPhoto`. Only photos returned in the `public_photos` array of the company detail response are migrated — photos embedded in asset fields or magic dash tiles are not covered here.

---

## Racks

Racks are migrated with name, company, size (rack units), notes, and location. Rack items within each rack are migrated with name, position, size, description, and notes.

### Rack item asset links not preserved

Rack items in Hudu can be linked to asset records. Those links are not re-created — the item will exist in the rack but will not be associated with its corresponding asset on the target.

### `Get-HuduRacks` / `Get-HuduRackItems` availability

These cmdlets wrap the `/api/v1/racks` endpoint. If your HuduAPI module version does not include them the step will log a warning and skip gracefully — no other steps are affected.

---

## What is not migrated at all

| Item                                  | Reason                                                                                                 |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| **Passwords / credentials**           | Requires a separate API key scope; intentionally excluded to avoid accidental exposure                 |
| **Flexible asset layouts and assets** | Not implemented — layout field types, tag relations, and asset data require a separate migration phase |
| **Contacts**                          | Not implemented                                                                                        |
| **Configurations**                    | Not implemented                                                                                        |
| **Magic Dash tiles**                  | No public API for Magic Dash items                                                                     |
| **Relations between records**         | Asset-to-asset and article-to-asset relations are not recreated                                        |
| **Password folders**                  | Not implemented                                                                                        |

---

## General

### No parallelism

All API calls are sequential. Large instances with thousands of articles or procedures will run slowly. There is no built-in rate-limit backoff — if the source or target API starts returning 429s the script will fail on that item and continue.

### Resume is not fully incremental

The script checks for existing records by name match before creating them (idempotent), so re-running is safe. However, there is no checkpoint file between steps — if the script crashes mid-run, it will re-attempt all records in every prior step when restarted, not pick up from the exact failure point.

### HuduAPI module version

Requires HuduAPI >= 2.4.5. Older versions may be missing cmdlets used by this script (`New-HuduProcedure`, `New-HuduProcedureTask`, `Set-HuduProcedureTask`, `Get-HuduRacks`, `Get-HuduIPAddresses`).

### PowerShell 7+ required

The null-coalescing operator (`??`) and other syntax used throughout the script are not available in Windows PowerShell 5.x.
