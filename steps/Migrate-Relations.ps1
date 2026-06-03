# ============================================================================
# Migrate-Relations.ps1 — relations between migrated records
# ============================================================================

function Resolve-MigrationRelationEndpoint {
    param(
        [string]$Type,
        [int]$SourceId,
        [hashtable]$CompanyMap,
        [hashtable]$ArticleMap,
        [hashtable]$AssetMap,
        [hashtable]$PasswordBySourceId,
        [hashtable]$WebsiteBySourceId,
        [hashtable]$RackMap,
        [hashtable]$NetworkMap,
        [string]$MigrationMode,
        [int]$SelectedCompanyId
    )

    switch -Regex ($Type) {
        '^Asset$' {
            if ($AssetMap.ContainsKey([string]$SourceId)) { return [int]$AssetMap[[string]$SourceId] }
            return $null
        }
        '^Article$' {
            if ($ArticleMap.ContainsKey([string]$SourceId)) {
                $entry = $ArticleMap[[string]$SourceId]
                if ($entry.TargetId) { return [int]$entry.TargetId }
            }
            return $null
        }
        '^AssetPassword$' {
            if ($PasswordBySourceId.ContainsKey([string]$SourceId)) { return [int]$PasswordBySourceId[[string]$SourceId] }
            return $null
        }
        '^Company$' {
            if ($CompanyMap.ContainsKey([string]$SourceId)) { return [int]$CompanyMap[[string]$SourceId] }
            return $null
        }
        '^Website$' {
            if ($WebsiteBySourceId.ContainsKey([string]$SourceId)) { return [int]$WebsiteBySourceId[[string]$SourceId] }
            return $null
        }
        '^RackStorage$' {
            if ($RackMap.ContainsKey([string]$SourceId)) { return [int]$RackMap[[string]$SourceId] }
            return $null
        }
        '^Network$' {
            if ($NetworkMap.ContainsKey([string]$SourceId)) { return [int]$NetworkMap[[string]$SourceId] }
            return $null
        }
        default { return $null }
    }
}

function Build-MigrationPasswordSourceIdMap {
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
            -Username $(if ($sp.username) { $sp.username } else { $null }) `
            -Url (Get-MigrationPasswordLoginUrl -Password $sp)
        if ($targetLookup.ContainsKey($key)) {
            $map[[string]$sp.id] = [int]$targetLookup[$key].id
        }
    }
    return $map
}

function Build-MigrationWebsiteSourceIdMap {
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
        if ($MigrationMode -eq 'SINGLE' -and $site.company_id -and $site.company_id -ne 0 -and $site.company_id -ne $SelectedCompanyId) {
            continue
        }
        $targetCompanyId = $null
        if ($site.company_id -and $site.company_id -ne 0) {
            $targetCompanyId = $CompanyMap[[string]$site.company_id]
            if (-not $targetCompanyId) { continue }
        }
        $targetName = Get-MigrationName -Name $site.name
        $match = $targetSites | Where-Object {
            $_.name -eq $targetName -and [string]$_.company_id -eq [string]$targetCompanyId
        } | Select-Object -First 1
        if ($match) { $map[[string]$site.id] = [int]$match.id }
    }
    return $map
}

function Invoke-RelationMigration {
    param(
        [hashtable]$CompanyMap,
        [hashtable]$ArticleMap,
        [hashtable]$AssetMap,
        [hashtable]$RackMap,
        [hashtable]$NetworkMap,
        [System.Collections.IDictionary]$Stats,
        [string]$MigrationMode,
        [int]$SelectedCompanyId
    )

    Write-Log "========== STEP 13: MIGRATING RELATIONS =========="

    $passwordMap = Build-MigrationPasswordSourceIdMap -CompanyMap $CompanyMap `
        -MigrationMode $MigrationMode -SelectedCompanyId $SelectedCompanyId
    $websiteMap = Build-MigrationWebsiteSourceIdMap -CompanyMap $CompanyMap `
        -MigrationMode $MigrationMode -SelectedCompanyId $SelectedCompanyId

    Use-SourceHudu
    $relations = @()
    try {
        $relations = @(Get-HuduObjectList -Response (Get-HuduRelations) -CollectionNames @('relations'))
    } catch {
        Write-Log "Could not fetch relations from source: $_" "WARN"
        return
    }
    Write-Log "Found $($relations.Count) relation(s) in source."

    Use-TargetHudu
    $existingPairKeys = @{}
    try {
        foreach ($tr in @(Get-HuduObjectList -Response (Get-HuduRelations) -CollectionNames @('relations'))) {
            $pairKey = Get-MigrationRelationPairKey `
                -FromType ([string]$tr.fromable_type) -FromId ([int]$tr.fromable_id) `
                -ToType ([string]$tr.toable_type) -ToId ([int]$tr.toable_id)
            $existingPairKeys[$pairKey] = $true
        }
        Write-Log "Indexed $($existingPairKeys.Count) existing relation pair(s) on target for dedupe."
    } catch {
        Write-Log "Could not index target relations for dedupe: $_" "WARN"
    }

    foreach ($rel in $relations) {
        $fromType = [string]$rel.fromable_type
        $toType   = [string]$rel.toable_type
        $fromId   = Resolve-MigrationRelationEndpoint -Type $fromType -SourceId ([int]$rel.fromable_id) `
            -CompanyMap $CompanyMap -ArticleMap $ArticleMap -AssetMap $AssetMap `
            -PasswordBySourceId $passwordMap -WebsiteBySourceId $websiteMap `
            -RackMap $RackMap -NetworkMap $NetworkMap `
            -MigrationMode $MigrationMode -SelectedCompanyId $SelectedCompanyId
        $toId = Resolve-MigrationRelationEndpoint -Type $toType -SourceId ([int]$rel.toable_id) `
            -CompanyMap $CompanyMap -ArticleMap $ArticleMap -AssetMap $AssetMap `
            -PasswordBySourceId $passwordMap -WebsiteBySourceId $websiteMap `
            -RackMap $RackMap -NetworkMap $NetworkMap `
            -MigrationMode $MigrationMode -SelectedCompanyId $SelectedCompanyId

        if (-not $fromId -or -not $toId) {
            $Stats.RelationsSkipped++
            continue
        }

        $pairKey = Get-MigrationRelationPairKey -FromType $fromType -FromId $fromId -ToType $toType -ToId $toId
        if ($existingPairKeys[$pairKey]) {
            $Stats.RelationsSkipped++
            continue
        }

        try {
            Use-TargetHudu
            $params = @{
                FromableType = $fromType
                FromableID   = $fromId
                ToableType   = $toType
                ToableID     = $toId
            }
            if ($rel.PSObject.Properties['description'] -and $rel.description) {
                $params['Description'] = [string]$rel.description
            }

            $result = New-HuduRelation @params
            if (-not $result) {
                $existingPairKeys[$pairKey] = $true
                $Stats.RelationsSkipped++
                Write-Log "Relation $fromType $fromId -> $toType $toId skipped (already exists on target or API rejected duplicate)." "WARN"
                continue
            }

            $existingPairKeys[$pairKey] = $true
            $Stats.RelationsCreated++
        } catch {
            Write-Log "Failed to create relation $fromType $fromId -> $toType $toId : $_" "ERROR"
            $Stats.RelationsFailed++
        }
    }

    Write-Log "Relations - Created: $($Stats.RelationsCreated) | Skipped: $($Stats.RelationsSkipped) | Failed: $($Stats.RelationsFailed)"
}
