# ============================================================================
# Migrate-Flags.ps1 — flag types and flags (Hudu-to-Hudu)
# ============================================================================

function Initialize-FlagTypeMap {
    param(
        [System.Collections.IDictionary]$Stats
    )

    $map = @{}
    Use-SourceHudu
    $sourceTypes = @(Get-HuduFlagTypes)
    Use-TargetHudu
    $targetTypes = @(Get-HuduFlagTypes)

    $targetByKey = @{}
    foreach ($tt in $targetTypes) {
        $key = Get-FlagTypeLookupKey -FlagType $tt
        if (-not $targetByKey.ContainsKey($key)) { $targetByKey[$key] = [int]$tt.id }
    }

    foreach ($st in $sourceTypes) {
        if (-not $st.id) { continue }
        $key = Get-FlagTypeLookupKey -FlagType $st
        if ($targetByKey.ContainsKey($key)) {
            $map[[string]$st.id] = $targetByKey[$key]
            $Stats.FlagTypesSkipped++
            continue
        }

        try {
            $color = if ($st.color) { [string]$st.color } else { 'grey' }
            $created = New-HuduFlagType -Name (Get-MigrationName -Name $st.name) -Color $color
            $newId = $created.id ?? $created.flag_type.id
            if ($newId) {
                $map[[string]$st.id] = [int]$newId
                $targetByKey[$key] = [int]$newId
                $Stats.FlagTypesCreated++
                Write-Log "Created flag type '$($st.name)' => target ID $newId" "SUCCESS"
            }
        } catch {
            Write-Log "Failed to create flag type '$($st.name)': $_" "ERROR"
            $Stats.FlagTypesFailed++
        }
    }

    return $map
}

function Get-SourceAssetCompanyId {
    param(
        [int]$AssetId,
        [hashtable]$Cache
    )

    $key = [string]$AssetId
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }

    $companyId = 0
    try {
        Use-SourceHudu
        $asset = Get-HuduSingleAsset -AssetId $AssetId
        if ($asset -eq 'CompanyScopeDenied') {
            $deniedKey = "asset:denied:$AssetId"
            if (-not $Cache.ContainsKey($deniedKey)) {
                Write-Log "Source asset $AssetId : API key cannot access this asset (permissions scoped to company) — skipping." "WARN"
                $Cache[$deniedKey] = $true
            }
        } elseif ($asset -and $asset.PSObject.Properties['company_id'] -and $asset.company_id) {
            $companyId = [int]$asset.company_id
        }
    } catch {
        Write-Log "Could not load source asset $AssetId for flag mapping: $(Get-HuduApiErrorSummary $_)" "WARN"
    }

    $Cache[$key] = $companyId
    return $companyId
}

function Build-TargetFlagIndex {
    param([hashtable]$FlagTypeMap)

    $index = @{}
    Use-TargetHudu
    $targetFlags = @(Get-HuduObjectList -Response (Get-HuduFlags) -CollectionNames @('flags'))
    foreach ($tf in $targetFlags) {
        if (-not $tf.flagable_type -or -not $tf.flagable_id -or -not $tf.flag_type_id) { continue }
        $key = Get-FlagDedupeKey -FlagableType ([string]$tf.flagable_type) `
            -FlagableId ([int]$tf.flagable_id) -FlagTypeId ([int]$tf.flag_type_id) `
            -Description ([string]$tf.description)
        $index[$key] = $true
    }
    Write-Log "Target has $($targetFlags.Count) existing flags ($($index.Count) unique dedupe keys)." "INFO"
    return $index
}

function Warm-AssetMapsForFlags {
    param(
        [object[]]$Flags,
        [hashtable]$CompanyMap,
        [hashtable]$AssetMapCache,
        [hashtable]$SourceAssetCompanyCache,
        [string]$MigrationMode,
        [int]$SelectedCompanyId
    )

    $pairs = @{}
    foreach ($flag in $Flags) {
        if ([string]$flag.flagable_type -notmatch '^Asset$') { continue }

        $sourceCompanyId = Get-SourceAssetCompanyId -AssetId ([int]$flag.flagable_id) -Cache $SourceAssetCompanyCache
        if ($MigrationMode -eq 'SINGLE' -and $sourceCompanyId -ne 0 -and $sourceCompanyId -ne $SelectedCompanyId) {
            continue
        }
        if (-not $sourceCompanyId) { continue }

        $targetCompanyId = $CompanyMap[[string]$sourceCompanyId]
        if (-not $targetCompanyId) { continue }

        $pairKey = "${sourceCompanyId}:${targetCompanyId}"
        $pairs[$pairKey] = [PSCustomObject]@{
            SourceCompanyId = [int]$sourceCompanyId
            TargetCompanyId = [int]$targetCompanyId
        }
    }

    foreach ($pair in $pairs.Values) {
        $map = Get-CompanyAssetMap -SourceCompanyId $pair.SourceCompanyId `
            -TargetCompanyId $pair.TargetCompanyId -Cache $AssetMapCache
        Write-Log "Asset map for company $($pair.SourceCompanyId) -> $($pair.TargetCompanyId): $($map.Count) matched by name/slug/serial." "INFO"
    }
}

function Build-ArticleTargetLookup {
    Use-TargetHudu
    $lookup = @{}
    foreach ($ta in @(Get-HuduObjectList -Response (Get-HuduArticles) -CollectionNames @('articles'))) {
        Add-ArticleLookupEntry -Lookup $lookup -Article $ta
    }
    return $lookup
}

function Resolve-MigrationFlagableId {
    param(
        [object]$Flag,
        [hashtable]$ArticleMap,
        [hashtable]$ArticleTargetLookup,
        [hashtable]$ArticleResolveCache,
        [hashtable]$CompanyMap,
        [hashtable]$FolderMap,
        [hashtable]$AssetMapCache,
        [hashtable]$SourceAssetCompanyCache,
        [hashtable]$TargetPasswordBySourceId,
        [hashtable]$TargetWebsiteBySourceId,
        [hashtable]$RackMap,
        [hashtable]$MigratedAssetMap = @{},
        [string]$MigrationMode,
        [int]$SelectedCompanyId
    )

    $sourceId = [int]$Flag.flagable_id
    $type = [string]$Flag.flagable_type

    switch -Regex ($type) {
        '^Article$' {
            return Resolve-MigrationArticleTargetId `
                -SourceArticleId $sourceId `
                -ArticleMap $ArticleMap `
                -ArticleTargetLookup $ArticleTargetLookup `
                -CompanyMap $CompanyMap `
                -FolderMap $FolderMap `
                -Cache $ArticleResolveCache
        }
        '^Asset$' {
            if ($MigratedAssetMap.ContainsKey([string]$sourceId)) {
                return [int]$MigratedAssetMap[[string]$sourceId]
            }
            $sourceCompanyId = Get-SourceAssetCompanyId -AssetId $sourceId -Cache $SourceAssetCompanyCache
            if ($MigrationMode -eq 'SINGLE' -and $sourceCompanyId -ne 0 -and $sourceCompanyId -ne $SelectedCompanyId) {
                return $null
            }
            if (-not $sourceCompanyId) { return $null }
            $targetCompanyId = $CompanyMap[[string]$sourceCompanyId]
            if (-not $targetCompanyId) { return $null }
            $assetMap = Get-CompanyAssetMap -SourceCompanyId $sourceCompanyId -TargetCompanyId $targetCompanyId -Cache $AssetMapCache
            if ($assetMap.ContainsKey([string]$sourceId)) { return $assetMap[[string]$sourceId] }
            return $null
        }
        '^AssetPassword$' {
            if ($TargetPasswordBySourceId.ContainsKey([string]$sourceId)) {
                return $TargetPasswordBySourceId[[string]$sourceId]
            }
            return $null
        }
        '^Company$' {
            $targetId = $CompanyMap[[string]$sourceId]
            if ($targetId) { return [int]$targetId }
            return $null
        }
        '^Website$' {
            if ($TargetWebsiteBySourceId.ContainsKey([string]$sourceId)) {
                return $TargetWebsiteBySourceId[[string]$sourceId]
            }
            return $null
        }
        '^RackStorage$' {
            $targetId = $RackMap[[string]$sourceId]
            if ($targetId) { return [int]$targetId }
            return $null
        }
        default {
            return $null
        }
    }
}

function Build-TargetPasswordSourceIdMap {
    param(
        [hashtable]$CompanyMap,
        [string]$MigrationMode,
        [int]$SelectedCompanyId
    )

    $map = @{}
    Use-SourceHudu
    $sourcePasswords = @(Get-HuduPasswords)
    Use-TargetHudu
    $targetLookup = @{}
    foreach ($tp in @(Get-HuduPasswords)) {
        Add-PasswordLookupEntry -Lookup $targetLookup -Password $tp
    }

    foreach ($sp in $sourcePasswords) {
        if ($MigrationMode -eq 'SINGLE' -and $sp.company_id -and $sp.company_id -ne 0 -and $sp.company_id -ne $SelectedCompanyId) {
            continue
        }

        $targetCompanyId = 0
        if ($sp.company_id -and $sp.company_id -ne 0) {
            $targetCompanyId = $CompanyMap[[string]$sp.company_id]
            if (-not $targetCompanyId) { continue }
        }

        $key = Get-PasswordLookupKey -Name $sp.name -CompanyId $targetCompanyId `
            -PasswordFolderId 0 -Username $sp.username -Url (Get-MigrationPasswordLoginUrl -Password $sp)
        if ($targetLookup.ContainsKey($key)) {
            $map[[string]$sp.id] = [int]$targetLookup[$key].id
        }
    }

    return $map
}

function Build-TargetWebsiteSourceIdMap {
    param(
        [hashtable]$CompanyMap,
        [string]$MigrationMode,
        [int]$SelectedCompanyId
    )

    $map = @{}
    Use-SourceHudu
    $sourceSites = @(Get-HuduObjectList -Response (Get-HuduWebsites) -CollectionNames @('websites'))
    Use-TargetHudu
    $targetSites = @(Get-HuduObjectList -Response (Get-HuduWebsites) -CollectionNames @('websites'))

    foreach ($site in $sourceSites) {
        if ($MigrationMode -eq 'SINGLE' -and $site.company_id -and $site.company_id -ne $SelectedCompanyId) {
            continue
        }
        if (-not $site.company_id -or $site.company_id -eq 0) { continue }

        $targetCompanyId = $CompanyMap[[string]$site.company_id]
        if (-not $targetCompanyId) { continue }

        $rawSiteName = Get-HuduWebsiteDisplayName -Site $site
        if (-not $rawSiteName) { continue }
        $siteName = Get-MigrationName -Name $rawSiteName

        $match = $targetSites | Where-Object {
            $_.company_id -eq $targetCompanyId -and (Get-HuduWebsiteDisplayName -Site $_) -eq $siteName
        } | Select-Object -First 1
        if ($match) { $map[[string]$site.id] = [int]$match.id }
    }

    return $map
}

function Invoke-FlagMigration {
    param(
        [hashtable]$CompanyMap,
        [hashtable]$ArticleMap,
        [hashtable]$FolderMap = @{},
        [hashtable]$RackMap = @{},
        [hashtable]$AssetMap = @{},
        [System.Collections.IDictionary]$Stats,
        [string]$MigrationMode,
        [int]$SelectedCompanyId
    )

    Write-Log "========== STEP: MIGRATING FLAGS =========="

    $flagTypeMap = Initialize-FlagTypeMap -Stats $Stats
    if ($flagTypeMap.Count -eq 0) {
        Write-Log "No flag types mapped — skipping flags." "WARN"
        return
    }

    $assetMapCache = @{}
    $sourceAssetCompanyCache = @{}
    $articleTargetLookup = Build-ArticleTargetLookup
    $articleResolveCache = @{}
    $targetPasswordBySourceId = Build-TargetPasswordSourceIdMap -CompanyMap $CompanyMap `
        -MigrationMode $MigrationMode -SelectedCompanyId $SelectedCompanyId
    $targetWebsiteBySourceId = Build-TargetWebsiteSourceIdMap -CompanyMap $CompanyMap `
        -MigrationMode $MigrationMode -SelectedCompanyId $SelectedCompanyId

    Use-SourceHudu
    $flags = @(Get-HuduObjectList -Response (Get-HuduFlags) -CollectionNames @('flags'))
    Write-Log "Found $($flags.Count) flags in source."

    Warm-AssetMapsForFlags -Flags $flags -CompanyMap $CompanyMap -AssetMapCache $assetMapCache `
        -SourceAssetCompanyCache $sourceAssetCompanyCache -MigrationMode $MigrationMode `
        -SelectedCompanyId $SelectedCompanyId

    $targetFlagIndex = Build-TargetFlagIndex -FlagTypeMap $flagTypeMap

    foreach ($flag in $flags) {
        if (-not $flag.id -or -not $flag.flag_type_id) { continue }

        $targetFlagTypeId = $flagTypeMap[[string]$flag.flag_type_id]
        if (-not $targetFlagTypeId) {
            Write-Log "No target flag type for source type ID $($flag.flag_type_id) (flag $($flag.id)) — skipping." "WARN"
            $Stats.FlagsSkipped++
            continue
        }

        $targetFlagableId = Resolve-MigrationFlagableId -Flag $flag `
            -ArticleMap $ArticleMap -ArticleTargetLookup $articleTargetLookup `
            -ArticleResolveCache $articleResolveCache -CompanyMap $CompanyMap -FolderMap $FolderMap `
            -AssetMapCache $assetMapCache -SourceAssetCompanyCache $sourceAssetCompanyCache `
            -TargetPasswordBySourceId $targetPasswordBySourceId `
            -TargetWebsiteBySourceId $targetWebsiteBySourceId -RackMap $RackMap `
            -MigratedAssetMap $AssetMap `
            -MigrationMode $MigrationMode -SelectedCompanyId $SelectedCompanyId

        if (-not $targetFlagableId) {
            $skipReason = "no target $($flag.flagable_type) for source id $($flag.flagable_id)"
            if ([string]$flag.flagable_type -match '^Article$') {
                $skipReason = 'no target article by source id or by migrated name + company/folder'
            } elseif ([string]$flag.flagable_type -match '^Asset$') {
                $skipReason = 'no target asset (not in AssetMap and no name/slug/serial match on target)'
            }
            Write-Log "Flag $($flag.id): $skipReason — skipping." "WARN"
            $Stats.FlagsSkipped++
            continue
        }

        $dedupeKey = Get-FlagDedupeKey -FlagableType ([string]$flag.flagable_type) `
            -FlagableId $targetFlagableId -FlagTypeId $targetFlagTypeId `
            -Description ([string]$flag.description)
        if ($targetFlagIndex.ContainsKey($dedupeKey)) {
            Write-Log "Flag $($flag.id) already exists on target $($flag.flagable_type) $targetFlagableId — skipping duplicate." "INFO"
            $Stats.FlagsDuplicatesSkipped++
            continue
        }

        try {
            Use-TargetHudu
            $params = @{
                FlagTypeId    = [int]$targetFlagTypeId
                Flagable_Type = [string]$flag.flagable_type
                flagable_id   = [int]$targetFlagableId
            }
            if ($flag.description) { $params.Description = [string]$flag.description }

            $null = New-HuduFlag @params
            $targetFlagIndex[$dedupeKey] = $true
            $Stats.FlagsCreated++
            Write-Log "Created flag on $($flag.flagable_type) $targetFlagableId (source flag $($flag.id))" "SUCCESS"
        } catch {
            Write-Log "Failed to create flag $($flag.id): $_" "ERROR"
            $Stats.FlagsFailed++
        }
    }

    $dup = if ($Stats.FlagsDuplicatesSkipped) { $Stats.FlagsDuplicatesSkipped } else { 0 }
    Write-Log "Flags complete — Created: $($Stats.FlagsCreated) | Skipped: $($Stats.FlagsSkipped) | Duplicates: $dup | Failed: $($Stats.FlagsFailed)"
}
