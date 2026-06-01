# ============================================================================
# Migrate-IPAM.ps1 — networks and IP addresses
# ============================================================================

function Invoke-IPAMMigration {
    param(
        [hashtable]$CompanyMap,
        [hashtable]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId
    )

    Write-Log "========== STEP 7: MIGRATING IPAM =========="

    $networkMap = @{}

    Use-SourceHudu
    $sourceNetworks = @(Get-HuduNetworks)
    Write-Log "Found $($sourceNetworks.Count) networks in source."

    Use-TargetHudu
    $targetNetworks = @(Get-HuduNetworks)

    foreach ($net in $sourceNetworks) {
        if ($MigrationMode -eq "SINGLE" -and $net.company_id -and $net.company_id -ne $SelectedCompanyId) { continue }

        $targetCompanyId = $null
        if ($net.company_id -and $net.company_id -ne 0) {
            $targetCompanyId = $CompanyMap[[string]$net.company_id]
            if (-not $targetCompanyId) {
                Write-Log "No company mapping for network '$($net.name)'. Skipping." "WARN"
                $Stats.NetworksSkipped++
                continue
            }
        }

        $existing = $targetNetworks | Where-Object {
            $_.name -eq $net.name -and $_.company_id -eq $targetCompanyId
        } | Select-Object -First 1

        if ($existing) {
            Write-Log "Network '$($net.name)' already exists in target. Mapping." "WARN"
            $networkMap[[string]$net.id] = $existing.id
            $Stats.NetworksSkipped++
            continue
        }

        try {
            Use-TargetHudu
            $params = @{ Name = $net.name }
            if ($targetCompanyId) { $params['CompanyId']   = $targetCompanyId  }
            if ($net.address)     { $params['Address']      = $net.address      }
            if ($net.description) { $params['Description']  = $net.description  }
            if ($net.notes)       { $params['Notes']         = $net.notes        }
            if ($net.location_id) { $params['LocationId']   = $net.location_id  }

            $created  = New-HuduNetwork @params
            $newNet   = $created.network ?? $created
            $newNetId = $newNet.id
            $networkMap[[string]$net.id] = $newNetId
            $Stats.NetworksCreated++
            Write-Log "Created network '$($net.name)' => target ID $newNetId" "SUCCESS"

            # Migrate IP addresses within this network
            Use-SourceHudu
            $srcIPs = @()
            try { $srcIPs = @(Get-HuduIPAddresses -NetworkId $net.id) } catch {
                Write-Log "  Could not fetch IP addresses for network '$($net.name)': $_" "WARN"
            }

            foreach ($ip in $srcIPs) {
                try {
                    Use-TargetHudu
                    $ipParams = @{ NetworkId = $newNetId; Address = $ip.address }
                    if ($ip.name)        { $ipParams['Name']        = $ip.name        }
                    if ($ip.description) { $ipParams['Description'] = $ip.description }
                    if ($ip.notes)       { $ipParams['Notes']       = $ip.notes       }
                    if ($ip.status)      { $ipParams['Status']      = $ip.status      }

                    New-HuduIPAddress @ipParams | Out-Null
                    $Stats.IPsCreated++
                    Write-Log "  Created IP '$($ip.address)' in network '$($net.name)'" "SUCCESS"
                } catch {
                    Write-Log "  Failed to create IP '$($ip.address)' in '$($net.name)': $_" "ERROR"
                    $Stats.IPsFailed++
                }
            }
        } catch {
            Write-Log "Failed to create network '$($net.name)': $_" "ERROR"
            $Stats.NetworksFailed++
        }
    }

    Write-Log "Networks - Created: $($Stats.NetworksCreated) | Skipped: $($Stats.NetworksSkipped) | Failed: $($Stats.NetworksFailed)"
    Write-Log "IPs      - Created: $($Stats.IPsCreated) | Failed: $($Stats.IPsFailed)"
    return $networkMap
}
