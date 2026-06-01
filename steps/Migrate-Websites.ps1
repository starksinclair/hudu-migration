# ============================================================================
# Migrate-Websites.ps1
# ============================================================================

function Invoke-WebsiteMigration {
    param(
        [hashtable]$CompanyMap,
        [hashtable]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId
    )

    Write-Log "========== STEP 6: MIGRATING WEBSITES =========="

    Use-SourceHudu
    $sourceWebsites = @(Get-HuduWebsites)
    Write-Log "Found $($sourceWebsites.Count) websites in source."

    Use-TargetHudu
    $targetWebsites = @(Get-HuduWebsites)

    foreach ($site in $sourceWebsites) {
        if ($MigrationMode -eq "SINGLE" -and $site.company_id -and $site.company_id -ne $SelectedCompanyId) { continue }

        $targetCompanyId = $null
        if ($site.company_id -and $site.company_id -ne 0) {
            $targetCompanyId = $CompanyMap[[string]$site.company_id]
            if (-not $targetCompanyId) {
                Write-Log "No company mapping for website '$($site.name)'. Skipping." "WARN"
                $Stats.WebsitesSkipped++
                continue
            }
        }

        $existing = $targetWebsites | Where-Object {
            $_.name -eq $site.name -and $_.company_id -eq $targetCompanyId
        } | Select-Object -First 1

        if ($existing) {
            Write-Log "Website '$($site.name)' already exists in target. Skipping." "WARN"
            $Stats.WebsitesSkipped++
            continue
        }

        try {
            Use-TargetHudu
            $params = @{ name = $site.name }
            if ($targetCompanyId)              { $params['companyid']    = $targetCompanyId             }
            if ($site.notes)                   { $params['notes']        = $site.notes                  }
            if ($null -ne $site.paused)        { $params['paused']       = $site.paused                 }
            if ($null -ne $site.disable_dns)   { $params['DisableDNS']   = [string]$site.disable_dns   }
            if ($null -ne $site.disable_ssl)   { $params['DisableSSL']   = [string]$site.disable_ssl   }
            if ($null -ne $site.disable_whois) { $params['DisableWhois'] = [string]$site.disable_whois }

            $created = New-HuduWebsite @params
            $newSite = $created.website ?? $created
            $Stats.WebsitesCreated++
            Write-Log "Created website '$($site.name)' => target ID $($newSite.id)" "SUCCESS"
        } catch {
            Write-Log "Failed to create website '$($site.name)': $_" "ERROR"
            $Stats.WebsitesFailed++
        }
    }

    Write-Log "Websites - Created: $($Stats.WebsitesCreated) | Skipped: $($Stats.WebsitesSkipped) | Failed: $($Stats.WebsitesFailed)"
}
