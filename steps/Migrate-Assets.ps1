# ============================================================================
# Migrate-Assets.ps1 — company assets (requires asset layouts + CompanyMap)
# ============================================================================

function Invoke-AssetMigration {
    param(
        [hashtable]$CompanyMap,
        [hashtable]$LayoutMap,
        [hashtable]$LayoutFieldMap,
        [System.Collections.IDictionary]$Stats,
        [string]$MigrationMode,
        [int]$SelectedCompanyId
    )

    Write-Log "========== STEP 11: MIGRATING ASSETS =========="

    $assetMap = @{}

    if (-not $LayoutMap -or $LayoutMap.Count -eq 0) {
        Write-Log "No asset layout mappings; skipping assets." "WARN"
        return $assetMap
    }

    $targetLayoutCache = @{}
    $listOptionsCache  = @{}

    foreach ($srcCompanyKey in @($CompanyMap.Keys)) {
        $sourceCompanyId = [int]$srcCompanyKey
        $targetCompanyId = [int]$CompanyMap[$srcCompanyKey]

        if ($MigrationMode -eq 'SINGLE' -and $sourceCompanyId -ne $SelectedCompanyId) { continue }

        Use-SourceHudu
        $sourceAssets = @(Get-HuduObjectList -Response (Get-HuduAssets -CompanyId $sourceCompanyId) -CollectionNames @('assets'))
        if ($sourceAssets.Count -eq 0) { continue }

        Write-Log "Company $sourceCompanyId -> $targetCompanyId : $($sourceAssets.Count) asset(s)"

        Use-TargetHudu
        $targetAssets = @(Get-HuduObjectList -Response (Get-HuduAssets -CompanyId $targetCompanyId) -CollectionNames @('assets'))

        foreach ($asset in $sourceAssets) {
            if ($asset.archived) {
                Write-Log "Skipping archived asset '$($asset.name)' (source $($asset.id))." "WARN"
                $Stats.AssetsSkipped++
                continue
            }

            if (-not $asset.asset_layout_id -or -not $LayoutMap.ContainsKey([string]$asset.asset_layout_id)) {
                Write-Log "Skipping asset '$($asset.name)': no layout mapping for layout $($asset.asset_layout_id)." "WARN"
                $Stats.AssetsSkipped++
                continue
            }

            $targetLayoutId = [int]$LayoutMap[[string]$asset.asset_layout_id]
            $displayName = Get-MigrationAssetDisplayName -Asset $asset
            if (-not $displayName) {
                Write-Log "Skipping asset source $($asset.id): missing or invalid name." "WARN"
                $Stats.AssetsSkipped++
                continue
            }
            $targetName = Get-MigrationName -Name $displayName

            $existing = Find-TargetAssetMatch -SourceAsset $asset -TargetAssets $targetAssets
            if ($existing) {
                $assetMap[[string]$asset.id] = [int]$existing.id
                $Stats.AssetsSkipped++
                continue
            }

            try {
                if (-not $targetLayoutCache.ContainsKey([string]$targetLayoutId)) {
                    Use-TargetHudu
                    $targetLayoutCache[[string]$targetLayoutId] = Get-AssetLayoutDetail -LayoutId $targetLayoutId
                }
                $targetLayoutDetail = $targetLayoutCache[[string]$targetLayoutId]

                $fieldValues = ConvertTo-MigrationAssetFieldValues `
                    -SourceAsset $asset `
                    -TargetLayoutDetail $targetLayoutDetail `
                    -AssetMap $assetMap `
                    -ListOptionsCache $listOptionsCache

                Use-TargetHudu
                $params = @{
                    Name          = $targetName
                    CompanyId     = $targetCompanyId
                    AssetLayoutId = $targetLayoutId
                }
                if ($asset.primary_serial) { $params['PrimarySerial'] = $asset.primary_serial }
                if ($asset.primary_mail) { $params['PrimaryMail'] = $asset.primary_mail }
                if ($asset.primary_model) { $params['PrimaryModel'] = $asset.primary_model }
                if ($asset.primary_manufacturer) { $params['PrimaryManufacturer'] = $asset.primary_manufacturer }
                $customFields = ConvertTo-HuduAssetCustomFieldsPayload -FieldValues $fieldValues
                if ($customFields.Count -gt 0) { $params['Fields'] = $customFields }

                $created = New-HuduAsset @params
                if (-not $created) {
                    throw 'New-HuduAsset returned no response (see HuduAPI error log in LogDir).'
                }
                $newAsset = $created.asset ?? $created
                if (-not $newAsset -or -not $newAsset.id -or [int]$newAsset.id -le 0) {
                    throw 'New-HuduAsset did not return a valid asset id.'
                }
                $newId = [int]$newAsset.id
                $assetMap[[string]$asset.id] = $newId
                $Stats.AssetsCreated++
                Write-Log "Created asset '$targetName' => target ID $newId" "SUCCESS"

                $targetAssets = @($targetAssets) + @($newAsset)
            } catch {
                Write-Log "Failed to create asset '$($asset.name)': $_" "ERROR"
                $Stats.AssetsFailed++
            }
        }
    }

    # Second pass: AssetTag fields that reference assets migrated in pass 1
    foreach ($srcCompanyKey in @($CompanyMap.Keys)) {
        $sourceCompanyId = [int]$srcCompanyKey
        $targetCompanyId = [int]$CompanyMap[$srcCompanyKey]
        if ($MigrationMode -eq 'SINGLE' -and $sourceCompanyId -ne $SelectedCompanyId) { continue }

        Use-SourceHudu
        $sourceAssets = @(Get-HuduObjectList -Response (Get-HuduAssets -CompanyId $sourceCompanyId) -CollectionNames @('assets'))

        foreach ($asset in $sourceAssets) {
            if (-not $assetMap.ContainsKey([string]$asset.id)) { continue }
            $targetAssetId = [int]$assetMap[[string]$asset.id]
            $targetLayoutId = [int]$LayoutMap[[string]$asset.asset_layout_id]
            if (-not $targetLayoutCache.ContainsKey([string]$targetLayoutId)) { continue }

            $fieldValues = ConvertTo-MigrationAssetFieldValues `
                -SourceAsset $asset `
                -TargetLayoutDetail $targetLayoutCache[[string]$targetLayoutId] `
                -AssetMap $assetMap `
                -ListOptionsCache $listOptionsCache

            $hasAssetTags = $false
            foreach ($k in $fieldValues.Keys) {
                $vals = $fieldValues[$k]
                if ($vals -is [System.Array] -and $vals.Count -gt 0 -and $vals[0] -is [int]) { $hasAssetTags = $true }
            }
            if (-not $hasAssetTags) { continue }

            try {
                Use-TargetHudu
                $tagPayload = ConvertTo-HuduAssetCustomFieldsPayload -FieldValues $fieldValues
                if ($tagPayload.Count -eq 0) { continue }
                Set-HuduAsset -Id $targetAssetId -Fields $tagPayload | Out-Null
                Write-Log "Updated AssetTag fields on asset '$($asset.name)' (target $targetAssetId)" "SUCCESS"
            } catch {
                Write-Log "Could not update AssetTag fields on '$($asset.name)': $_" "WARN"
            }
        }
    }

    Write-Log "Assets - Created: $($Stats.AssetsCreated) | Skipped: $($Stats.AssetsSkipped) | Failed: $($Stats.AssetsFailed)"
    return $assetMap
}
