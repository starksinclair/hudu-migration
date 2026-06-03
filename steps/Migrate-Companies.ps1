# ============================================================================
# Migrate-Companies.ps1
# ============================================================================

function Invoke-CompanyMigration {
    param(
        [object[]] $SourceCompanies,
        [System.Collections.IDictionary]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId
    )

    Write-Log "========== STEP 1: MIGRATING COMPANIES =========="

    $companyMap = @{}

    Use-TargetHudu
    $targetCompanies = Get-HuduCompanies

    foreach ($co in $SourceCompanies) {
        if ($MigrationMode -eq "SINGLE" -and $co.id -ne $SelectedCompanyId) { continue }

        $existing = $targetCompanies | Where-Object { $_.name -eq $co.name } | Select-Object -First 1
        if ($existing) {
            Write-Log "Company '$($co.name)' already exists in target (ID $($existing.id)). Mapping." "WARN"
            $companyMap[[string]$co.id] = $existing.id
            $Stats.CompaniesSkipped++
            continue
        }

        try {
            Use-TargetHudu
            $params = @{ Name = $co.name }
            if ($co.nickname)       { $params['Nickname']     = $co.nickname       }
            if ($co.phone_number)   { $params['PhoneNumber']  = $co.phone_number   }
            if ($co.website)        { $params['Website']      = $co.website        }
            if ($co.city)           { $params['City']         = $co.city           }
            if ($co.state)          { $params['State']        = $co.state          }
            if ($co.zip)            { $params['Zip']          = $co.zip            }
            if ($co.country_name)   { $params['CountryName']  = $co.country_name   }
            if ($co.address_line_1) { $params['AddressLine1'] = $co.address_line_1 }
            if ($co.notes)          { $params['Notes']        = $co.notes          }

            $created = New-HuduCompany @params
            $newId   = $created.company.id ?? $created.id
            $companyMap[[string]$co.id] = $newId
            $Stats.CompaniesCreated++
            Write-Log "Created company '$($co.name)' => target ID $newId" "SUCCESS"
        } catch {
            Write-Log "Failed to create company '$($co.name)': $_" "ERROR"
            $Stats.CompaniesFailed++
        }
    }

    Write-Log "Companies - Created: $($Stats.CompaniesCreated) | Matched: $($Stats.CompaniesSkipped) | Failed: $($Stats.CompaniesFailed)"
    return $companyMap
}
