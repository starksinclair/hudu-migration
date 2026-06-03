# ============================================================================
# Migrate-Websites.ps1 — company websites (Hudu-to-Hudu)
#
# ITGlue-Hudu-Migration maps IT Glue domains → Hudu websites (name = https://domain).
# This step copies existing Hudu websites between tenants (name/URL as stored in source).
# confluence.ps1 does not migrate websites (Confluence → Hudu articles only).
# ============================================================================

function Get-HuduWebsiteDisplayName {
    param([object]$Site)
    foreach ($key in @('name', 'url', 'website_url')) {
        if ($Site.PSObject.Properties[$key] -and -not [string]::IsNullOrWhiteSpace([string]$Site.$key)) {
            return [string]$Site.$key.Trim()
        }
    }
    return $null
}

function Invoke-WebsiteMigration {
    param(
        [hashtable]$CompanyMap,
        [System.Collections.IDictionary]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId
    )

    Write-Log "========== STEP 6: MIGRATING WEBSITES =========="

    Use-SourceHudu
    $sourceWebsites = @(Get-HuduObjectList -Response (Get-HuduWebsites) -CollectionNames @('websites'))
    Write-Log "Found $($sourceWebsites.Count) websites in source."

    Use-TargetHudu
    $targetWebsites = @(Get-HuduObjectList -Response (Get-HuduWebsites) -CollectionNames @('websites'))

    foreach ($site in $sourceWebsites) {
        if ($MigrationMode -eq "SINGLE" -and $site.company_id -and $site.company_id -ne $SelectedCompanyId) {
            continue
        }

        $siteName = Get-HuduWebsiteDisplayName -Site $site
        if (-not $siteName) {
            $idLabel = if ($site.id) { $site.id } else { 'unknown' }
            Write-Log "Website (ID $idLabel) has no name or URL — skipping." "WARN"
            $Stats.WebsitesSkipped++
            continue
        }

        if (-not $site.company_id -or $site.company_id -eq 0) {
            Write-Log "Website '$siteName' has no company_id — skipping." "WARN"
            $Stats.WebsitesSkipped++
            continue
        }

        $targetCompanyId = $CompanyMap[[string]$site.company_id]
        if (-not $targetCompanyId) {
            Write-Log "No company mapping for website '$siteName'. Skipping." "WARN"
            $Stats.WebsitesSkipped++
            continue
        }

        $existing = $targetWebsites | Where-Object {
            $_.name -eq $siteName -and [string]$_.company_id -eq [string]$targetCompanyId
        } | Select-Object -First 1

        if ($existing) {
            Write-Log "Website '$siteName' already exists in target. Skipping." "WARN"
            $Stats.WebsitesSkipped++
            continue
        }

        try {
            Use-TargetHudu
            $params = @{
                Name      = $siteName
                CompanyId = [int]$targetCompanyId
            }
            if ($site.notes) { $params['Notes'] = $site.notes }

            foreach ($pair in @(
                @{ Param = 'Paused';       Source = 'paused' }
                @{ Param = 'DisableDNS';   Source = 'disable_dns' }
                @{ Param = 'DisableSSL';   Source = 'disable_ssl' }
                @{ Param = 'DisableWhois'; Source = 'disable_whois' }
                @{ Param = 'EnableDMARC';  Source = 'enable_dmarc_tracking' }
                @{ Param = 'EnableDKIM';   Source = 'enable_dkim_tracking' }
                @{ Param = 'EnableSPF';    Source = 'enable_spf_tracking' }
            )) {
                if ($site.PSObject.Properties[$pair.Source] -and $null -ne $site.($pair.Source)) {
                    $flag = ConvertTo-HuduApiStringFlag -Value $site.($pair.Source)
                    if ($null -ne $flag) { $params[$pair.Param] = $flag }
                }
            }
            if ($site.PSObject.Properties['slug'] -and $site.slug) {
                $params['Slug'] = $site.slug
            }

            $created = New-HuduWebsite @params
            $newSite = $created.website ?? $created
            $Stats.WebsitesCreated++
            Write-Log "Created website '$siteName' => target ID $($newSite.id)" "SUCCESS"
        } catch {
            Write-Log "Failed to create website '$siteName': $_" "ERROR"
            $Stats.WebsitesFailed++
        }
    }

    Write-Log "Websites - Created: $($Stats.WebsitesCreated) | Skipped: $($Stats.WebsitesSkipped) | Failed: $($Stats.WebsitesFailed)"
}
