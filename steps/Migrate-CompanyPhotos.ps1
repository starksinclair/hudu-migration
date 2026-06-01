# ============================================================================
# Migrate-CompanyPhotos.ps1 — public photos attached to companies
# ============================================================================

function Invoke-CompanyPhotoMigration {
    param(
        [object[]] $SourceCompanies,
        [hashtable]$CompanyMap,
        [hashtable]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId,
        [string]   $TempPath
    )

    Write-Log "========== STEP 8: MIGRATING COMPANY PHOTOS =========="

    foreach ($co in $SourceCompanies) {
        if ($MigrationMode -eq "SINGLE" -and $co.id -ne $SelectedCompanyId) { continue }

        $targetCompanyId = $CompanyMap[[string]$co.id]
        if (-not $targetCompanyId) {
            Write-Log "No target mapping for company '$($co.name)'. Skipping photos." "WARN"
            continue
        }

        Use-SourceHudu
        $coDetail = $null
        try {
            $raw      = Get-HuduCompanies -Id $co.id
            $coDetail = $raw.company ?? $raw
        } catch {
            Write-Log "Could not fetch detail for company '$($co.name)': $_" "WARN"
            continue
        }

        if (-not $coDetail.public_photos -or $coDetail.public_photos.Count -eq 0) { continue }

        $coPhotoTemp = Join-Path $TempPath "company_$($co.id)_photos"
        if (-not (Test-Path $coPhotoTemp)) { New-Item -ItemType Directory -Path $coPhotoTemp -Force | Out-Null }

        foreach ($photo in $coDetail.public_photos) {
            $photoUrl  = if ($photo.url -match '^https?://') { $photo.url } else { "$($script:SourceHuduUrl)$($photo.url)" }
            $photoName = if ($photo.file_name) { $photo.file_name } else { "photo_$($photo.id).bin" }
            $photoPath = Join-Path $coPhotoTemp $photoName

            try {
                Use-SourceHudu
                $plain   = Get-PlainText $script:SourceHuduApiKeySecure
                $headers = @{ 'x-api-key' = $plain }
                $plain   = $null
                Invoke-WebRequest -Uri $photoUrl -Headers $headers -OutFile $photoPath -ErrorAction Stop

                Use-TargetHudu
                $result = New-HuduPublicPhoto -FilePath $photoPath -record_id $targetCompanyId -record_type 'Company'
                if ($result.public_photo ?? $result) {
                    $Stats.PhotosUploaded++
                    Write-Log "  Uploaded photo '$photoName' for company '$($co.name)'" "SUCCESS"
                } else {
                    $Stats.PhotosFailed++
                }
                Remove-Item $photoPath -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Log "  Photo migration failed for '$photoName' (company '$($co.name)'): $_" "WARN"
                $Stats.PhotosFailed++
            }
        }

        Remove-Item $coPhotoTemp -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Photos - Uploaded: $($Stats.PhotosUploaded) | Failed: $($Stats.PhotosFailed)"
}
