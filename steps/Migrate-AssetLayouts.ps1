# ============================================================================
# Migrate-AssetLayouts.ps1 — asset layouts and field definitions
# ============================================================================

function Set-MigrationAssetLayoutActive {
    param(
        [int]$TargetLayoutId,
        [object]$SourceLayout
    )

    $wantActive = $true
    if ($SourceLayout.PSObject.Properties['active'] -and $null -ne $SourceLayout.active) {
        $wantActive = [bool]$SourceLayout.active
    }
    if (-not $wantActive) { return $false }

    try {
        Set-HuduAssetLayout -Id $TargetLayoutId -Active $true | Out-Null
        return $true
    } catch {
        Write-Log "Could not activate asset layout target ID $TargetLayoutId : $_" "WARN"
        return $false
    }
}

function Get-AssetLayoutDetail {
    param([int]$LayoutId)

    $raw = Get-HuduAssetLayouts -LayoutId $LayoutId
    if ($raw.PSObject.Properties['asset_layout'] -and $raw.asset_layout) { return $raw.asset_layout }
    if ($raw.PSObject.Properties['id'] -and $raw.id) { return $raw }
    return $raw
}

function Invoke-AssetLayoutMigration {
    param(
        [System.Collections.IDictionary]$Stats,
        [string]$MigrationMode,
        [int]$SelectedCompanyId
    )

    Write-Log "========== STEP 2: MIGRATING ASSET LAYOUTS =========="

    $layoutMap = @{}
    $layoutFieldMap = @{}
    $activatedCount = 0

    Use-SourceHudu
    $sourceLayouts = @(Get-HuduObjectList -Response (Get-HuduAssetLayouts) -CollectionNames @('asset_layouts'))
    Write-Log "Found $($sourceLayouts.Count) asset layout(s) in source."

    Write-Log "Building list map for ListSelect fields..."
    $listMap = Get-MigrationListMap

    Use-TargetHudu
    $targetLayouts = @(Get-HuduObjectList -Response (Get-HuduAssetLayouts) -CollectionNames @('asset_layouts'))

    foreach ($layout in $sourceLayouts) {
        $targetLayoutName = Get-MigrationName -Name $layout.name
        $existing = $targetLayouts | Where-Object {
            $_.name -and [string]$_.name -eq $targetLayoutName
        } | Select-Object -First 1

        if ($existing) {
            Write-Log "Asset layout '$targetLayoutName' already exists (ID $($existing.id)). Mapping." "WARN"
            $layoutMap[[string]$layout.id] = [int]$existing.id
            $Stats.AssetLayoutsSkipped++
            Use-TargetHudu
            if (Set-MigrationAssetLayoutActive -TargetLayoutId ([int]$existing.id) -SourceLayout $layout) {
                $activatedCount++
            }
            continue
        }

        try {
            Use-TargetHudu
            $fieldDefs = @()
            if ($layout.fields) {
                foreach ($field in @($layout.fields | Sort-Object { $_.position })) {
                    $def = ConvertTo-MigrationAssetLayoutField -Field $field -ListMap $listMap -LayoutMap $layoutMap
                    if ($def) { $fieldDefs += $def }
                }
            }

            $params = @{
                Name              = $targetLayoutName
                Icon              = if ($layout.icon) { $layout.icon } else { 'fas fa-laptop' }
                Color             = if ($layout.color) { $layout.color } else { '#6136ff' }
                IconColor         = if ($layout.icon_color) { $layout.icon_color } else { '#FFFFFF' }
                IncludePasswords  = [bool]($layout.include_passwords ?? $true)
                IncludePhotos     = [bool]($layout.include_photos ?? $true)
                IncludeComments   = [bool]($layout.include_comments ?? $true)
                IncludeFiles      = [bool]($layout.include_files ?? $true)
            }
            if ($fieldDefs.Count -gt 0) { $params['Fields'] = $fieldDefs }

            $created = New-HuduAssetLayout @params
            $newLayout = $created.asset_layout ?? $created
            $newId = [int]$newLayout.id
            $layoutMap[[string]$layout.id] = $newId
            $Stats.AssetLayoutsCreated++
            Write-Log "Created asset layout '$targetLayoutName' => target ID $newId ($($fieldDefs.Count) fields)" "SUCCESS"
            if (Set-MigrationAssetLayoutActive -TargetLayoutId $newId -SourceLayout $layout) {
                $activatedCount++
            }
            $targetLayouts += $newLayout
        } catch {
            Write-Log "Failed to create asset layout '$targetLayoutName': $_" "ERROR"
            $Stats.AssetLayoutsFailed++
        }
    }

    # Second pass: remap AssetTag linkable_id fields that point at layouts created in pass 1
    foreach ($layout in $sourceLayouts) {
        $sourceLayoutId = [string]$layout.id
        if (-not $layoutMap.ContainsKey($sourceLayoutId)) { continue }

        $needsLinkableFix = $false
        foreach ($field in @($layout.fields)) {
            if ($field.field_type -eq 'AssetTag' -and $field.linkable_id -and -not $layoutMap.ContainsKey([string]$field.linkable_id)) {
                $needsLinkableFix = $true
                break
            }
        }
        if (-not $needsLinkableFix) { continue }

        try {
            Use-TargetHudu
            $targetId = [int]$layoutMap[$sourceLayoutId]
            $detail = Get-AssetLayoutDetail -LayoutId $targetId
            $updatedFields = @()
            foreach ($field in @($layout.fields | Sort-Object { $_.position })) {
                $def = ConvertTo-MigrationAssetLayoutField -Field $field -ListMap $listMap -LayoutMap $layoutMap
                if ($def) { $updatedFields += $def }
            }
            if ($updatedFields.Count -gt 0) {
                Set-HuduAssetLayout -Id $targetId -Fields $updatedFields | Out-Null
                Write-Log "Updated AssetTag linkable layouts on '$($layout.name)' (target $targetId)" "SUCCESS"
            }
        } catch {
            Write-Log "Could not update linkable fields on layout '$($layout.name)': $_" "WARN"
        }
    }

    # Map source field id -> target field id by label per layout
    foreach ($layout in $sourceLayouts) {
        $sourceLayoutId = [string]$layout.id
        if (-not $layoutMap.ContainsKey($sourceLayoutId)) { continue }

        try {
            Use-TargetHudu
            $targetDetail = Get-AssetLayoutDetail -LayoutId ([int]$layoutMap[$sourceLayoutId])
            $byLabel = @{}
            foreach ($tf in @($targetDetail.fields)) {
                if ($tf.label) { $byLabel[[string]$tf.label.Trim().ToLowerInvariant()] = $tf }
            }

            $fieldIdMap = @{}
            foreach ($sf in @($layout.fields)) {
                if (-not $sf.id -or -not $sf.label) { continue }
                $norm = [string]$sf.label.Trim().ToLowerInvariant()
                if ($byLabel.ContainsKey($norm)) {
                    $fieldIdMap[[string]$sf.id] = [int]$byLabel[$norm].id
                }
            }
            $layoutFieldMap[$sourceLayoutId] = $fieldIdMap
        } catch {
            Write-Log "Could not build field map for layout '$($layout.name)': $_" "WARN"
        }
    }

    Write-Log "Asset layouts - Created: $($Stats.AssetLayoutsCreated) | Skipped: $($Stats.AssetLayoutsSkipped) | Failed: $($Stats.AssetLayoutsFailed) | Activated: $activatedCount"
    Write-Log "Layouts must be active to appear in company sidebars (Admin → Asset Layouts → activate). Migrated layouts are activated when active on source." "INFO"
    return @{
        LayoutMap      = $layoutMap
        LayoutFieldMap = $layoutFieldMap
        ListMap        = $listMap
    }
}
