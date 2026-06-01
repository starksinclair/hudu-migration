# ============================================================================
# Migrate-Racks.ps1 — racks and rack items
# ============================================================================

function Invoke-RackMigration {
    param(
        [hashtable]$CompanyMap,
        [hashtable]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId
    )

    Write-Log "========== STEP 9: MIGRATING RACKS =========="

    $rackMap = @{}

    Use-SourceHudu
    $sourceRacks = @()
    try { $sourceRacks = @(Get-HuduRacks) } catch {
        Write-Log "Could not fetch racks (may not be available in this Hudu version): $_" "WARN"
    }
    Write-Log "Found $($sourceRacks.Count) racks in source."

    Use-TargetHudu
    $targetRacks = @()
    try { $targetRacks = @(Get-HuduRacks) } catch { $targetRacks = @() }

    foreach ($rack in $sourceRacks) {
        if ($MigrationMode -eq "SINGLE" -and $rack.company_id -and $rack.company_id -ne $SelectedCompanyId) { continue }

        $targetCompanyId = $null
        if ($rack.company_id -and $rack.company_id -ne 0) {
            $targetCompanyId = $CompanyMap[[string]$rack.company_id]
            if (-not $targetCompanyId) {
                Write-Log "No company mapping for rack '$($rack.name)'. Skipping." "WARN"
                $Stats.RacksSkipped++
                continue
            }
        }

        $existing = $targetRacks | Where-Object {
            $_.name -eq $rack.name -and $_.company_id -eq $targetCompanyId
        } | Select-Object -First 1

        if ($existing) {
            Write-Log "Rack '$($rack.name)' already exists in target. Mapping." "WARN"
            $rackMap[[string]$rack.id] = $existing.id
            $Stats.RacksSkipped++
            continue
        }

        try {
            Use-TargetHudu
            $params = @{ Name = $rack.name }
            if ($targetCompanyId)  { $params['CompanyId']  = $targetCompanyId  }
            if ($rack.size)        { $params['Size']        = $rack.size        }
            if ($rack.notes)       { $params['Notes']       = $rack.notes       }
            if ($rack.location_id) { $params['LocationId'] = $rack.location_id }

            $created   = New-HuduRack @params
            $newRack   = $created.rack ?? $created
            $newRackId = $newRack.id
            $rackMap[[string]$rack.id] = $newRackId
            $Stats.RacksCreated++
            Write-Log "Created rack '$($rack.name)' => target ID $newRackId" "SUCCESS"

            # Migrate rack items
            Use-SourceHudu
            $srcItems = @()
            try { $srcItems = @(Get-HuduRackItems -RackId $rack.id) } catch {
                Write-Log "  Could not fetch items for rack '$($rack.name)': $_" "WARN"
            }

            foreach ($item in $srcItems) {
                try {
                    Use-TargetHudu
                    $ip = @{ RackId = $newRackId; Name = $item.name }
                    if ($item.position)    { $ip['Position']    = $item.position    }
                    if ($item.size)        { $ip['Size']        = $item.size        }
                    if ($item.description) { $ip['Description'] = $item.description }
                    if ($item.notes)       { $ip['Notes']       = $item.notes       }

                    New-HuduRackItem @ip | Out-Null
                    Write-Log "  Created rack item '$($item.name)' in rack '$($rack.name)'" "SUCCESS"
                } catch {
                    Write-Log "  Failed to create rack item '$($item.name)': $_" "ERROR"
                }
            }
        } catch {
            Write-Log "Failed to create rack '$($rack.name)': $_" "ERROR"
            $Stats.RacksFailed++
        }
    }

    Write-Log "Racks - Created: $($Stats.RacksCreated) | Skipped: $($Stats.RacksSkipped) | Failed: $($Stats.RacksFailed)"
    return $rackMap
}
