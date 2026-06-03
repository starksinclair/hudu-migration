# ============================================================================
# Migrate-Racks.ps1 — rack storages and rack storage items (Hudu API)
#
# Hudu uses rack_storages / rack_storage_items (not legacy "racks" paths).
# ITGlue-Hudu-Migration does not migrate racks; this is Hudu-to-Hudu only.
# ============================================================================

function Get-RackStorageDetail {
    param([int]$RackId)
    $raw = Get-HuduRackStorages -Id $RackId
    if ($raw.PSObject.Properties['rack_storage'] -and $raw.rack_storage) { return $raw.rack_storage }
    if ($raw.PSObject.Properties['rack'] -and $raw.rack) { return $raw.rack }
    return $raw
}

function Get-RackItemsForStorage {
    param(
        [object]$RackDetail,
        [object[]]$FlatItems
    )
    $byId = @{}
    $add = {
        param([object]$Item)
        if ($null -eq $Item -or -not $Item.id) { return }
        $key = [string]$Item.id
        if (-not $byId.ContainsKey($key)) {
            $byId[$key] = $Item
        }
    }

    foreach ($slotName in @('front_items', 'rear_items')) {
        if (-not ($RackDetail.PSObject.Properties[$slotName] -and $RackDetail.$slotName)) { continue }
        foreach ($slot in @($RackDetail.$slotName)) {
            if (-not $slot.has_items -or -not $slot.items) { continue }
            foreach ($item in @($slot.items)) { & $add $item }
        }
    }

    $rackId = [string]$RackDetail.id
    foreach ($item in $FlatItems) {
        $itemRackId = $null
        if ($item.PSObject.Properties['rack_storage_id'] -and $item.rack_storage_id) {
            $itemRackId = [string]$item.rack_storage_id
        }
        if ($itemRackId -eq $rackId) { & $add $item }
    }

    return @($byId.Values)
}

function ConvertTo-HuduRackSide {
    param([object]$Side)
    if ($null -eq $Side) { return 0 }
    if ($Side -is [int] -or $Side -is [long]) { return [int]$Side }
    switch -Regex ([string]$Side) {
        '^(?i)rear|back$' { return 1 }
        default           { return 0 }
    }
}

function ConvertTo-HuduRackStatus {
    param([object]$Status)
    if ($null -eq $Status) { return 1 }
    if ($Status -is [int] -or $Status -is [long]) { return [int]$Status }
    switch -Regex ([string]$Status) {
        '^(?i)reserved|available|empty$' { return 0 }
        default                          { return 1 }
    }
}

function New-MigrationRackStorageItem {
    param(
        [int]$RackStorageId,
        [int]$CompanyId,
        [int]$StartUnit,
        [int]$EndUnit,
        [int]$AssetId = 0,
        [int]$RackStorageRoleId = 0,
        [int]$Status = 1,
        [int]$Side = 0,
        [int]$MaxWattage = 0,
        [int]$PowerDraw = 0,
        [string]$ReservedMessage
    )

    $itemPayload = @{
        rack_storage_id = $RackStorageId
        start_unit      = $StartUnit
        end_unit        = $EndUnit
        company_id      = $CompanyId
        side            = $Side
        status          = $Status
    }
    if ($AssetId -gt 0) { $itemPayload['asset_id'] = $AssetId }
    if ($RackStorageRoleId -gt 0) { $itemPayload['rack_storage_role_id'] = $RackStorageRoleId }
    if ($MaxWattage -gt 0)      { $itemPayload['max_wattage'] = $MaxWattage }
    if ($PowerDraw -gt 0)       { $itemPayload['power_draw'] = $PowerDraw }
    if ($ReservedMessage)       { $itemPayload['reserved_message'] = $ReservedMessage }

    $response = Invoke-HuduJsonApi -Method POST -Resource '/api/v1/rack_storage_items' -Body @{
        rack_storage_item = $itemPayload
    }

    $created = $null
    if ($response.PSObject.Properties['rack_storage_item'] -and $response.rack_storage_item) {
        $created = $response.rack_storage_item
    } else {
        $created = $response
    }
    if (-not $created -or -not $created.id) {
        throw 'API returned no rack_storage_item id'
    }
    return $created
}

function Invoke-RackItemMigration {
    param(
        [object]$Item,
        [int]$TargetRackId,
        [int]$TargetCompanyId,
        [string]$RackName,
        [hashtable]$AssetMap,
        [System.Collections.IDictionary]$Stats
    )

    $startUnit = 0
    $endUnit   = 0
    if ($Item.PSObject.Properties['start_unit'] -and $null -ne $Item.start_unit) {
        $startUnit = [int]($Item.start_unit)
    } elseif ($Item.PSObject.Properties['starting_unit'] -and $null -ne $Item.starting_unit) {
        $startUnit = [int]($Item.starting_unit)
    }
    if ($Item.PSObject.Properties['end_unit'] -and $null -ne $Item.end_unit) {
        $endUnit = [int]($Item.end_unit)
    }
    if ($startUnit -le 0 -or $endUnit -le 0) {
        Write-Log "  Skipping rack item id $($Item.id): invalid unit range ($startUnit-$endUnit)" "WARN"
        $Stats.RackItemsSkipped++
        return
    }

    $sourceAssetId = 0
    if ($Item.PSObject.Properties['asset_id'] -and $Item.asset_id) {
        $sourceAssetId = [int]($Item.asset_id)
    }

    $roleId = 0
    if ($Item.PSObject.Properties['rack_storage_role_id'] -and $Item.rack_storage_role_id) {
        $roleId = [int]($Item.rack_storage_role_id)
    }

    $targetAssetId = 0
    $reservedMessage = $null
    $label = "U$startUnit-$endUnit"

    if ($sourceAssetId -gt 0) {
        $assetName = $null
        if ($Item.PSObject.Properties['asset_name'] -and $Item.asset_name) {
            $assetName = [string]$Item.asset_name
        }
        if ($AssetMap.ContainsKey([string]$sourceAssetId)) {
            $targetAssetId = $AssetMap[[string]$sourceAssetId]
            $label = if ($assetName) { "$assetName ($label)" } else { "asset $targetAssetId ($label)" }
        } else {
            $namePart = if ($assetName) { $assetName } else { "asset $sourceAssetId" }
            Write-Log "  Skipping rack item ${label}: no target asset '$namePart' (source id $sourceAssetId)" "WARN"
            $Stats.RackItemsSkipped++
            return
        }
    } elseif ($Item.PSObject.Properties['reserved_message'] -and $Item.reserved_message) {
        $reservedMessage = [string]$Item.reserved_message
    } elseif ($Item.PSObject.Properties['is_reserved'] -and $Item.is_reserved) {
        $reservedMessage = 'Reserved'
    } else {
        Write-Log "  Skipping rack item id $($Item.id): no asset_id or reservation data" "WARN"
        $Stats.RackItemsSkipped++
        return
    }

    $side   = ConvertTo-HuduRackSide -Side $(if ($Item.PSObject.Properties['side']) { $Item.side } else { $null })
    $status = ConvertTo-HuduRackStatus -Status $(if ($Item.PSObject.Properties['status']) { $Item.status } else { $null })
    if ($targetAssetId -eq 0 -and $reservedMessage) {
        $status = 0
    }

    $maxWattage = 0
    $powerDraw  = 0
    if ($Item.PSObject.Properties['max_wattage'] -and $Item.max_wattage) { $maxWattage = [int]($Item.max_wattage) }
    if ($Item.PSObject.Properties['power_draw'] -and $Item.power_draw)  { $powerDraw  = [int]($Item.power_draw) }

    try {
        Use-TargetHudu
        $created = New-MigrationRackStorageItem `
            -RackStorageId     $TargetRackId `
            -CompanyId         $TargetCompanyId `
            -StartUnit         $startUnit `
            -EndUnit           $endUnit `
            -AssetId           $targetAssetId `
            -RackStorageRoleId $roleId `
            -Status            $status `
            -Side              $side `
            -MaxWattage        $maxWattage `
            -PowerDraw         $powerDraw `
            -ReservedMessage   $reservedMessage
        $Stats.RackItemsCreated++
        Write-Log "  Created rack item $label on '$RackName' => target item ID $($created.id)" "SUCCESS"
    } catch {
        Write-Log "  Failed to create rack item $label on '$RackName': $_" "ERROR"
        $Stats.RackItemsFailed++
    }
}

function Invoke-RackMigration {
    param(
        [hashtable]$CompanyMap,
        [hashtable]$AssetMap = @{},
        [System.Collections.IDictionary]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId
    )

    Write-Log "========== STEP 9: MIGRATING RACK STORAGES =========="

    if (-not (Get-Command Get-HuduRackStorages -ErrorAction SilentlyContinue)) {
        Write-Log "HuduAPI module does not expose Get-HuduRackStorages (requires HuduAPI >= 2.4.5). Skipping racks." "WARN"
        return @{}
    }

    $rackMap = @{}
    $assetMapCache = @{}

    Use-SourceHudu
    try {
        if ($MigrationMode -eq "SINGLE") {
            $sourceRacks = @(Get-HuduRackStorages -CompanyId $SelectedCompanyId)
        } else {
            $sourceRacks = @(Get-HuduRackStorages)
        }
    } catch {
        Write-Log "Could not fetch rack storages from source: $_" "WARN"
        $sourceRacks = @()
    }
    Write-Log "Found $($sourceRacks.Count) rack storage(s) in source."

    $sourceItems = @()
    try {
        $rawItems = Get-HuduRackStorageItems
        $sourceItems = @(Get-HuduObjectList -Response $rawItems -CollectionNames @('rack_storage_items'))
    } catch {
        Write-Log "Could not fetch rack storage items from source: $_" "WARN"
    }
    Write-Log "Found $($sourceItems.Count) rack storage item(s) in flat list."

    Use-TargetHudu
    $targetRacks = @()
    try {
        $rawRacks = Get-HuduRackStorages
        $targetRacks = @(Get-HuduObjectList -Response $rawRacks -CollectionNames @('rack_storages'))
    } catch {
        $targetRacks = @()
    }

    foreach ($rack in $sourceRacks) {
        if ($MigrationMode -eq "SINGLE" -and $rack.company_id -and $rack.company_id -ne $SelectedCompanyId) {
            continue
        }

        $targetCompanyId = $null
        if ($rack.company_id -and $rack.company_id -ne 0) {
            $targetCompanyId = $CompanyMap[[string]$rack.company_id]
            if (-not $targetCompanyId) {
                Write-Log "No company mapping for rack '$($rack.name)'. Skipping." "WARN"
                $Stats.RacksSkipped++
                continue
            }
        } else {
            Write-Log "Rack '$($rack.name)' has no company_id. Skipping (CompanyId is required)." "WARN"
            $Stats.RacksSkipped++
            continue
        }

        $existing = $targetRacks | Where-Object {
            $_.name -eq (Get-MigrationName -Name $rack.name) -and [string]$_.company_id -eq [string]$targetCompanyId
        } | Select-Object -First 1

        $targetRackId = $null
        if ($existing) {
            Write-Log "Rack '$($rack.name)' already exists in target (ID $($existing.id)). Mapping and migrating items." "WARN"
            $targetRackId = [int]($existing.id)
            $rackMap[[string]$rack.id] = $targetRackId
            $Stats.RacksSkipped++
        } else {
            $height = 0
            if ($rack.PSObject.Properties['height'] -and $rack.height) { $height = [int]($rack.height) }
            elseif ($rack.PSObject.Properties['size'] -and $rack.size) { $height = [int]($rack.size) }

            $width = 0
            if ($rack.PSObject.Properties['width'] -and $rack.width) { $width = [int]($rack.width) }

            if ($height -le 0) { $height = 42 }
            if ($width -le 0) {
                $width = 600
                Write-Log "  Rack '$($rack.name)' missing width; defaulting to $width" "WARN"
            }

            try {
                Use-TargetHudu
                $params = @{
                    Name      = (Get-MigrationName -Name $rack.name)
                    CompanyId = [int]$targetCompanyId
                    Height    = $height
                    Width     = $width
                }
                if ($rack.description) { $params['Description'] = $rack.description }
                if ($rack.max_wattage)  { $params['MaxWattage']  = [int]($rack.max_wattage) }
                if ($rack.starting_unit) { $params['StartingUnit'] = [int]($rack.starting_unit) }

                $created   = New-HuduRackStorage @params
                $newRack   = $created.rack_storage ?? $created.rack ?? $created
                $targetRackId = [int]($newRack.id)
                $rackMap[[string]$rack.id] = $targetRackId
                $Stats.RacksCreated++
                Write-Log "Created rack '$($rack.name)' => target ID $targetRackId" "SUCCESS"
            } catch {
                Write-Log "Failed to create rack '$($rack.name)': $_" "ERROR"
                $Stats.RacksFailed++
                continue
            }
        }

        Use-SourceHudu
        $rackDetail = $rack
        try {
            $rackDetail = Get-RackStorageDetail -RackId ([int]($rack.id))
        } catch {
            Write-Log "  Could not load rack detail for '$($rack.name)'; using list payload for items" "WARN"
        }

        $rackItems = Get-RackItemsForStorage -RackDetail $rackDetail -FlatItems $sourceItems
        Write-Log "  Rack '$($rack.name)': $($rackItems.Count) unique item(s) to migrate"

        if ($rackItems.Count -eq 0) { continue }

        $assetMap = @{}
        if ($AssetMap -and $AssetMap.Count -gt 0) {
            foreach ($entry in $AssetMap.GetEnumerator()) {
                $assetMap[$entry.Key] = $entry.Value
            }
        }
        $nameMap = Get-CompanyAssetMap `
            -SourceCompanyId ([int]($rack.company_id)) `
            -TargetCompanyId ([int]$targetCompanyId) `
            -Cache $assetMapCache
        foreach ($entry in $nameMap.GetEnumerator()) {
            if (-not $assetMap.ContainsKey($entry.Key)) {
                $assetMap[$entry.Key] = $entry.Value
            }
        }

        foreach ($item in $rackItems) {
            Invoke-RackItemMigration `
                -Item             $item `
                -TargetRackId     $targetRackId `
                -TargetCompanyId  ([int]$targetCompanyId) `
                -RackName         $rack.name `
                -AssetMap         $assetMap `
                -Stats            $Stats
        }
    }

    Save-Phase -Name 'racks' -Data $rackMap

    Write-Log "Racks      - Created: $($Stats.RacksCreated) | Skipped: $($Stats.RacksSkipped) | Failed: $($Stats.RacksFailed)"
    Write-Log "Rack items - Created: $($Stats.RackItemsCreated) | Skipped: $($Stats.RackItemsSkipped) | Failed: $($Stats.RackItemsFailed)"
    return $rackMap
}
