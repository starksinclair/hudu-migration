# ============================================================================
# Migrate-IPAM.ps1 — VLAN zones, VLANs, networks, and IP addresses
# ============================================================================

function Test-IPAMCompanyInScope {
    param(
        [object]$Record,
        [string]$MigrationMode,
        [int]$SelectedCompanyId
    )
    if ($MigrationMode -ne 'SINGLE') { return $true }
    if (-not $Record.company_id -or $Record.company_id -eq 0) { return $true }
    return $Record.company_id -eq $SelectedCompanyId
}

function Get-IPAMTargetCompanyId {
    param(
        [object]$Record,
        [hashtable]$CompanyMap,
        [System.Collections.IDictionary]$Stats,
        [string]$EntityLabel
    )
    if (-not $Record.company_id -or $Record.company_id -eq 0) { return $null }
    $targetCompanyId = $CompanyMap[[string]$Record.company_id]
    if (-not $targetCompanyId) {
        Write-Log "No company mapping for $EntityLabel '$($Record.name)'. Skipping." "WARN"
        return -1
    }
    return $targetCompanyId
}

function Get-MigrationIPAddresses {
    param(
        [int]$CompanyId = 0,
        [int]$NetworkId = 0
    )

    $query = [System.Collections.Generic.List[string]]::new()
    if ($NetworkId) { [void]$query.Add("network_id=$NetworkId") }
    if ($CompanyId) { [void]$query.Add("company_id=$CompanyId") }

    $resource = '/api/v1/ip_addresses'
    if ($query.Count -gt 0) {
        $resource += '?' + ($query -join '&')
    }

    $resp = Invoke-HuduJsonApi -Method GET -Resource $resource
    if ($resp -is [System.Array]) { return @($resp) }
    foreach ($key in @('ip_addresses', 'ip_address')) {
        if ($resp.PSObject.Properties[$key] -and $resp.$key) {
            return @($resp.$key)
        }
    }
    if ($resp.PSObject.Properties['id'] -and $resp.address) { return @($resp) }
    return @()
}

function Get-IPAMIpLookupKey {
    param(
        [int]$CompanyId,
        [int]$NetworkId,
        [string]$Address
    )
    return "$CompanyId|$NetworkId|$Address"
}

function New-MigrationTargetIPAddress {
    param(
        [object]$Ip,
        [int]$TargetNetworkId,
        [int]$TargetCompanyId
    )

    $plainDescription = ConvertTo-HuduPlainDescription -Text $ip.description
    $ipBody = @{
        address    = [string]$ip.address
        network_id = $TargetNetworkId
        company_id = $TargetCompanyId
    }
    if ($plainDescription) { $ipBody['description'] = $plainDescription }
    if ($ip.notes) { $ipBody['notes'] = $ip.notes }
    if ($ip.status) { $ipBody['status'] = $ip.status }
    if ($ip.fqdn) { $ipBody['fqdn'] = $ip.fqdn }
    if ($ip.PSObject.Properties['skip_dns_validation'] -and $null -ne $ip.skip_dns_validation) {
        $ipBody['skip_dns_validation'] = [bool]$ip.skip_dns_validation
    }

    $resp = Invoke-HuduJsonApi -Method POST -Resource '/api/v1/ip_addresses' -Body @{ ip_address = $ipBody }
    return ($resp.ip_address ?? $resp)
}

function Invoke-IPAMMigration {
    param(
        [hashtable]$CompanyMap,
        [System.Collections.IDictionary]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId
    )

    Write-Log "========== STEP 7: MIGRATING IPAM =========="

    $networkMap   = @{}
    $vlanZoneMap  = @{}

    # --- VLAN zones (before VLANs that reference them) ---
    Use-SourceHudu
    $sourceVlanZones = @(Get-HuduVLANZones)
    Write-Log "Found $($sourceVlanZones.Count) VLAN zones in source."

    Use-TargetHudu
    $targetVlanZones = @(Get-HuduVLANZones)

    foreach ($zone in $sourceVlanZones) {
        if (-not (Test-IPAMCompanyInScope -Record $zone -MigrationMode $MigrationMode -SelectedCompanyId $SelectedCompanyId)) {
            continue
        }

        $targetCompanyId = Get-IPAMTargetCompanyId -Record $zone -CompanyMap $CompanyMap -Stats $Stats -EntityLabel 'VLAN zone'
        if ($targetCompanyId -eq -1) {
            $Stats.VlanZonesSkipped++
            continue
        }

        $targetZoneName = Get-MigrationName -Name $zone.name
        $existing = $targetVlanZones | Where-Object {
            $_.name -eq $targetZoneName -and $_.company_id -eq $targetCompanyId
        } | Select-Object -First 1

        if ($existing) {
            Write-Log "VLAN zone '$($zone.name)' already exists in target. Mapping." "WARN"
            $vlanZoneMap[[string]$zone.id] = $existing.id
            $Stats.VlanZonesSkipped++
            continue
        }

        try {
            Use-TargetHudu
            $params = @{ Name = $targetZoneName }
            if ($targetCompanyId) { $params['CompanyId'] = $targetCompanyId }
            if ($zone.description) { $params['Description'] = $zone.description }
            if ($zone.vlan_id_ranges) { $params['VLANIdRanges'] = $zone.vlan_id_ranges }

            $created = New-HuduVLANZone @params
            $newZone = $created.vlan_zone ?? $created
            $newId   = $newZone.id
            $vlanZoneMap[[string]$zone.id] = $newId
            $Stats.VlanZonesCreated++
            Write-Log "Created VLAN zone '$($zone.name)' => target ID $newId" "SUCCESS"
            $targetVlanZones += $newZone
        } catch {
            Write-Log "Failed to create VLAN zone '$($zone.name)': $_" "ERROR"
            $Stats.VlanZonesFailed++
        }
    }

    # --- VLANs ---
    Use-SourceHudu
    $sourceVlans = @(Get-HuduVLANs)
    Write-Log "Found $($sourceVlans.Count) VLANs in source."

    Use-TargetHudu
    $targetVlans = @(Get-HuduVLANs)

    foreach ($vlan in $sourceVlans) {
        if (-not (Test-IPAMCompanyInScope -Record $vlan -MigrationMode $MigrationMode -SelectedCompanyId $SelectedCompanyId)) {
            continue
        }

        $targetCompanyId = Get-IPAMTargetCompanyId -Record $vlan -CompanyMap $CompanyMap -Stats $Stats -EntityLabel 'VLAN'
        if ($targetCompanyId -eq -1) {
            $Stats.VlansSkipped++
            continue
        }

        $targetVlanName = Get-MigrationName -Name $vlan.name
        $existing = $targetVlans | Where-Object {
            $_.name -eq $targetVlanName -and $_.company_id -eq $targetCompanyId
        } | Select-Object -First 1

        if ($existing) {
            Write-Log "VLAN '$($vlan.name)' already exists in target. Skipping." "WARN"
            $Stats.VlansSkipped++
            continue
        }

        try {
            Use-TargetHudu
            $vlanNumber = [int]$vlan.vlan_id
            if ($vlanNumber -lt 4 -or $vlanNumber -gt 4094) {
                throw "VLAN ID $vlanNumber is outside the allowed range 4-4094."
            }

            $targetVlanZoneId = $null
            if ($vlan.vlan_zone_id) {
                $targetVlanZoneId = $vlanZoneMap[[string]$vlan.vlan_zone_id]
                if (-not $targetVlanZoneId) {
                    Write-Log "No VLAN zone mapping for VLAN '$($vlan.name)' (source zone $($vlan.vlan_zone_id)). Creating without zone." "WARN"
                }
            }

            $newId = $null
            if ($vlan.notes) {
                $vlanBody = @{
                    name       = $targetVlanName
                    vlan_id    = $vlanNumber
                    company_id = $targetCompanyId
                }
                if ($vlan.description) { $vlanBody['description'] = $vlan.description }
                if ($vlan.notes) { $vlanBody['notes'] = $vlan.notes }
                if ($targetVlanZoneId) { $vlanBody['vlan_zone_id'] = $targetVlanZoneId }
                if ($vlan.status_list_item_id) { $vlanBody['status_list_item_id'] = $vlan.status_list_item_id }
                if ($vlan.role_list_item_id) { $vlanBody['role_list_item_id'] = $vlan.role_list_item_id }

                $resp = Invoke-HuduJsonApi -Method POST -Resource '/api/v1/vlans' -Body @{ vlan = $vlanBody }
                $newVlan = $resp.vlan ?? $resp
                $newId = $newVlan.id
            } else {
                $params = @{
                    Name    = $targetVlanName
                    VLANId  = $vlanNumber
                }
                if ($targetCompanyId) { $params['CompanyId'] = $targetCompanyId }
                if ($vlan.description) { $params['Description'] = $vlan.description }
                if ($targetVlanZoneId) { $params['VLANZoneId'] = $targetVlanZoneId }
                if ($vlan.status_list_item_id) { $params['StatusListItemID'] = $vlan.status_list_item_id }
                if ($vlan.role_list_item_id) { $params['RoleListItemID'] = $vlan.role_list_item_id }

                $created = New-HuduVLAN @params
                $newVlan = $created.vlan ?? $created
                $newId   = $newVlan.id
            }

            $Stats.VlansCreated++
            Write-Log "Created VLAN '$($vlan.name)' (ID $vlanNumber) => target ID $newId" "SUCCESS"
            $targetVlans += [PSCustomObject]@{ id = $newId; name = $targetVlanName; company_id = $targetCompanyId }
        } catch {
            Write-Log "Failed to create VLAN '$($vlan.name)': $_" "ERROR"
            $Stats.VlansFailed++
        }
    }

    # --- Networks ---
    Use-SourceHudu
    $sourceNetworks = @(Get-HuduNetworks)
    Write-Log "Found $($sourceNetworks.Count) networks in source."

    Use-TargetHudu
    $targetNetworks = @(Get-HuduNetworks)

    foreach ($net in $sourceNetworks) {
        if (-not (Test-IPAMCompanyInScope -Record $net -MigrationMode $MigrationMode -SelectedCompanyId $SelectedCompanyId)) {
            continue
        }

        $targetCompanyId = Get-IPAMTargetCompanyId -Record $net -CompanyMap $CompanyMap -Stats $Stats -EntityLabel 'network'
        if ($targetCompanyId -eq -1) {
            $Stats.NetworksSkipped++
            continue
        }

        $targetNetName = Get-MigrationName -Name $net.name
        $existing = $targetNetworks | Where-Object {
            $_.name -eq $targetNetName -and $_.company_id -eq $targetCompanyId
        } | Select-Object -First 1

        if ($existing) {
            Write-Log "Network '$($net.name)' already exists in target. Mapping." "WARN"
            $networkMap[[string]$net.id] = $existing.id
            $Stats.NetworksSkipped++
            continue
        }

        try {
            Use-TargetHudu
            $plainDescription = ConvertTo-HuduPlainDescription -Text $net.description
            $newNetId = $null

            if ($net.notes) {
                $networkBody = @{
                    name       = $targetNetName
                    company_id = $targetCompanyId
                }
                if ($net.address) { $networkBody['address'] = $net.address }
                if ($plainDescription) { $networkBody['description'] = $plainDescription }
                $networkBody['notes'] = $net.notes
                if ($net.location_id) { $networkBody['location_id'] = $net.location_id }

                $resp = Invoke-HuduJsonApi -Method POST -Resource '/api/v1/networks' -Body @{ network = $networkBody }
                $newNet = $resp.network ?? $resp
                $newNetId = $newNet.id
            } else {
                $params = @{ Name = $targetNetName }
                if ($targetCompanyId) { $params['CompanyId'] = $targetCompanyId }
                if ($net.address) { $params['Address'] = $net.address }
                if ($plainDescription) { $params['Description'] = $plainDescription }
                if ($net.location_id) { $params['LocationId'] = $net.location_id }

                $created = New-HuduNetwork @params
                $newNet = $created.network ?? $created
                $newNetId = $newNet.id
            }
            $networkMap[[string]$net.id] = $newNetId
            $Stats.NetworksCreated++
            Write-Log "Created network '$($net.name)' => target ID $newNetId" "SUCCESS"
        } catch {
            Write-Log "Failed to create network '$($net.name)': $_" "ERROR"
            $Stats.NetworksFailed++
        }
    }

    # --- IP addresses (after all networks are mapped; GET supports network_id / company_id) ---
    Write-Log "Migrating IP addresses for $($networkMap.Count) mapped network(s)..."

    Use-TargetHudu
    $targetIpLookup = @{}
    foreach ($targetNetworkId in @($networkMap.Values | Select-Object -Unique)) {
        $tgtNetId = [int]$targetNetworkId
        foreach ($tip in (Get-MigrationIPAddresses -NetworkId $tgtNetId)) {
            $tgtCoId = 0
            if ($tip.PSObject.Properties['company_id'] -and $tip.company_id) {
                $tgtCoId = [int]$tip.company_id
            }
            $key = Get-IPAMIpLookupKey -CompanyId $tgtCoId -NetworkId $tgtNetId -Address ([string]$tip.address)
            $targetIpLookup[$key] = $true
        }
    }

    $migratedSourceIpKeys = @{}

    foreach ($srcNetworkKey in @($networkMap.Keys)) {
        $targetNetworkId = [int]$networkMap[$srcNetworkKey]
        $sourceNetworkId = [int]$srcNetworkKey

        Use-SourceHudu
        $srcIPs = @(Get-MigrationIPAddresses -NetworkId $sourceNetworkId)
        if ($srcIPs.Count -eq 0) { continue }

        $sourceNet = $sourceNetworks | Where-Object { $_.id -eq $sourceNetworkId } | Select-Object -First 1
        $targetCompanyId = $null
        if ($sourceNet -and $sourceNet.company_id) {
            $targetCompanyId = $CompanyMap[[string]$sourceNet.company_id]
        }

        foreach ($ip in $srcIPs) {
            if (-not (Test-IPAMCompanyInScope -Record $ip -MigrationMode $MigrationMode -SelectedCompanyId $SelectedCompanyId)) {
                continue
            }

            if ($ip.company_id -and $ip.company_id -ne 0) {
                $mappedCo = $CompanyMap[[string]$ip.company_id]
                if (-not $mappedCo) {
                    Write-Log "No company mapping for IP '$($ip.address)'. Skipping." "WARN"
                    $Stats.IPsSkipped++
                    continue
                }
                $targetCompanyId = $mappedCo
            }
            if (-not $targetCompanyId) {
                Write-Log "IP '$($ip.address)' has no company; skipping." "WARN"
                $Stats.IPsSkipped++
                continue
            }

            $sourceIpKey = "$sourceNetworkId|$($ip.address)"
            if ($migratedSourceIpKeys[$sourceIpKey]) { continue }
            $migratedSourceIpKeys[$sourceIpKey] = $true

            $dedupeKey = Get-IPAMIpLookupKey -CompanyId ([int]$targetCompanyId) -NetworkId $targetNetworkId -Address ([string]$ip.address)
            if ($targetIpLookup[$dedupeKey]) {
                Write-Log "IP '$($ip.address)' already exists on target network. Skipping." "WARN"
                $Stats.IPsSkipped++
                continue
            }

            try {
                Use-TargetHudu
                $newIp = New-MigrationTargetIPAddress -Ip $ip -TargetNetworkId $targetNetworkId -TargetCompanyId ([int]$targetCompanyId)
                $targetIpLookup[$dedupeKey] = $true
                $Stats.IPsCreated++
                Write-Log "Created IP '$($ip.address)' on network ID $targetNetworkId" "SUCCESS"
            } catch {
                Write-Log "Failed to create IP '$($ip.address)' on network ID $targetNetworkId : $_" "ERROR"
                $Stats.IPsFailed++
            }
        }
    }

    Write-Log "Vlan zones - Created: $($Stats.VlanZonesCreated) | Skipped: $($Stats.VlanZonesSkipped) | Failed: $($Stats.VlanZonesFailed)"
    Write-Log "Vlans      - Created: $($Stats.VlansCreated) | Skipped: $($Stats.VlansSkipped) | Failed: $($Stats.VlansFailed)"
    Write-Log "Networks   - Created: $($Stats.NetworksCreated) | Skipped: $($Stats.NetworksSkipped) | Failed: $($Stats.NetworksFailed)"
    Write-Log "IPs        - Created: $($Stats.IPsCreated) | Skipped: $($Stats.IPsSkipped) | Failed: $($Stats.IPsFailed)"
    return $networkMap
}
