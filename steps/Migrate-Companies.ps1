# ============================================================================
# Migrate-Companies.ps1
# ============================================================================

function Get-CompanyMigrationParams {
    param(
        [object]$SourceCompany,
        [string]$TargetName,
        [hashtable]$CompanyMap = @{},
        [switch]$IncludeParent
    )

    $params = @{ Name = $TargetName }

    $fieldMap = @(
        @{ Param = 'Nickname';     Source = 'nickname' }
        @{ Param = 'CompanyType';  Source = 'company_type' }
        @{ Param = 'AddressLine1'; Source = 'address_line_1' }
        @{ Param = 'AddressLine2'; Source = 'address_line_2' }
        @{ Param = 'City';         Source = 'city' }
        @{ Param = 'State';        Source = 'state' }
        @{ Param = 'Zip';          Source = 'zip' }
        @{ Param = 'CountryName';  Source = 'country_name' }
        @{ Param = 'PhoneNumber';  Source = 'phone_number' }
        @{ Param = 'FaxNumber';    Source = 'fax_number' }
        @{ Param = 'Website';      Source = 'website' }
        @{ Param = 'IdNumber';     Source = 'id_number' }
        @{ Param = 'Notes';        Source = 'notes' }
    )

    foreach ($pair in $fieldMap) {
        if ($SourceCompany.PSObject.Properties[$pair.Source] -and -not [string]::IsNullOrWhiteSpace([string]$SourceCompany.($pair.Source))) {
            $params[$pair.Param] = $SourceCompany.($pair.Source)
        }
    }

    if ($IncludeParent -and $SourceCompany.PSObject.Properties['parent_company_id'] -and $SourceCompany.parent_company_id) {
        $parentKey = [string]$SourceCompany.parent_company_id
        if ($CompanyMap.ContainsKey($parentKey)) {
            $params['ParentCompanyId'] = [int]$CompanyMap[$parentKey]
        }
    }

    return $params
}

function Invoke-CompanyMigration {
    param(
        [object[]] $SourceCompanies,
        [System.Collections.IDictionary]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId
    )

    Write-Log "========== STEP 1: MIGRATING COMPANIES =========="

    $companyMap = @{}
    $parentLinkQueue = [System.Collections.Generic.List[object]]::new()

    Use-TargetHudu
    $targetCompanies = Get-HuduCompanies

    foreach ($co in $SourceCompanies) {
        if ($MigrationMode -eq "SINGLE" -and $co.id -ne $SelectedCompanyId) { continue }

        $targetName = Get-MigrationName -Name $co.name
        $existing = $targetCompanies | Where-Object { $_.name -eq $targetName } | Select-Object -First 1
        if ($existing) {
            Write-Log "Company '$targetName' already exists in target (ID $($existing.id)). Mapping." "WARN"
            $companyMap[[string]$co.id] = $existing.id
            $Stats.CompaniesSkipped++
            if ($co.parent_company_id) {
                $parentLinkQueue.Add([PSCustomObject]@{
                    SourceId       = $co.id
                    TargetId       = $existing.id
                    ParentSourceId = $co.parent_company_id
                })
            }
            continue
        }

        try {
            Use-TargetHudu
            $params = Get-CompanyMigrationParams -SourceCompany $co -TargetName $targetName -CompanyMap $companyMap

            $created = New-HuduCompany @params
            $newId   = $created.company.id ?? $created.id
            $companyMap[[string]$co.id] = $newId
            $Stats.CompaniesCreated++
            Write-Log "Created company '$targetName' => target ID $newId" "SUCCESS"

            if ($co.parent_company_id) {
                $parentLinkQueue.Add([PSCustomObject]@{
                    SourceId       = $co.id
                    TargetId       = $newId
                    ParentSourceId = $co.parent_company_id
                })
            }
        } catch {
            Write-Log "Failed to create company '$targetName': $_" "ERROR"
            $Stats.CompaniesFailed++
        }
    }

    foreach ($link in $parentLinkQueue) {
        $parentKey = [string]$link.ParentSourceId
        if (-not $companyMap.ContainsKey($parentKey)) {
            Write-Log "Company ID $($link.TargetId): parent source company $parentKey not in migration map; skipping parent link." "WARN"
            continue
        }

        $targetParentId = [int]$companyMap[$parentKey]
        if ($targetParentId -eq [int]$link.TargetId) {
            Write-Log "Company ID $($link.TargetId): cannot set self as parent; skipping." "WARN"
            continue
        }

        try {
            Use-TargetHudu
            Set-HuduCompany -Id ([int]$link.TargetId) -ParentCompanyId $targetParentId | Out-Null
            Write-Log "Linked company $($link.TargetId) => parent $targetParentId (source parent $($link.ParentSourceId))" "SUCCESS"
        } catch {
            Write-Log "Failed to set parent for company $($link.TargetId): $_" "WARN"
        }
    }

    Write-Log "Companies - Created: $($Stats.CompaniesCreated) | Matched: $($Stats.CompaniesSkipped) | Failed: $($Stats.CompaniesFailed)"
    return $companyMap
}
