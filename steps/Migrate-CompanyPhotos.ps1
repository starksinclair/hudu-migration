# ============================================================================
# Migrate-CompanyPhotos.ps1 — Photo Gallery (/api/v1/photos) + photo folders
#
# Distinct from:
#   - public_photos on companies/articles (embeddable /public_photo/* for rich text)
#   - KB folders (Migrate-Folders.ps1, folder_type article)
#
# Uses Get-HuduPhotos / New-HuduPhoto (Hudu >= 2.41). Photo folders use /api/v1/folders
# with folder_type photo (see folder_id on each photo).
# ============================================================================

function New-HuduPhotoFolderApi {
    param(
        [string]$Name,
        [int]$CompanyId,
        [int]$ParentFolderId = 0,
        [string]$Description = $null
    )

    $folderPayload = @{
        name        = $Name
        company_id  = $CompanyId
        folder_type = 'photo'
    }
    if ($ParentFolderId -gt 0) { $folderPayload['parent_folder_id'] = $ParentFolderId }
    if ($Description)          { $folderPayload['description'] = $Description }

    $response = Invoke-HuduJsonApi -Method POST -Resource '/api/v1/folders' -Body @{
        folder = $folderPayload
    }
    $created = $response.folder ?? $response
    if (-not $created -or -not $created.id) {
        throw 'API returned no folder id'
    }
    return $created
}

function Invoke-PhotoFolderMigration {
    param(
        [object[]]$SourceFolders,
        [int]$TargetCompanyId,
        [hashtable]$PhotoFolderMap,
        [System.Collections.IDictionary]$Stats
    )

    $sourceById = @{}
    foreach ($f in $SourceFolders) { $sourceById[[string]$f.id] = $f }

    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $SourceFolders) { $null = $pending.Add($f) }

    while ($pending.Count -gt 0) {
        $progress = 0
        for ($i = $pending.Count - 1; $i -ge 0; $i--) {
            $folder = $pending[$i]
            $sourceParentId = Get-FolderParentFolderId $folder
            if ($sourceParentId -and -not $PhotoFolderMap.ContainsKey([string]$sourceParentId)) {
                if ($sourceById.ContainsKey([string]$sourceParentId)) { continue }
            }

            $targetParentId = 0
            if ($sourceParentId) {
                $targetParentId = $PhotoFolderMap[[string]$sourceParentId]
                if (-not $targetParentId) { continue }
            }

            try {
                Use-TargetHudu
                $created = New-HuduPhotoFolderApi `
                    -Name           $folder.name `
                    -CompanyId      $TargetCompanyId `
                    -ParentFolderId ([int]$targetParentId) `
                    -Description    $(if ($folder.description) { $folder.description } else { $null })
                $PhotoFolderMap[[string]$folder.id] = [int]($created.id)
                $Stats.PhotoFoldersCreated++
                Write-Log "  Created photo folder '$($folder.name)' => target ID $($created.id)" "SUCCESS"
                $pending.RemoveAt($i)
                $progress++
            } catch {
                Write-Log "  Failed to create photo folder '$($folder.name)': $_" "ERROR"
                $Stats.PhotoFoldersFailed++
                $pending.RemoveAt($i)
            }
        }
        if ($progress -eq 0) {
            foreach ($f in @($pending)) {
                Write-Log "  Unable to resolve parent for photo folder '$($f.name)'; skipping." "WARN"
                $Stats.PhotoFoldersSkipped++
            }
            break
        }
    }
}

function Invoke-CompanyPhotoMigration {
    param(
        [object[]] $SourceCompanies,
        [hashtable]$CompanyMap,
        [System.Collections.IDictionary]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId,
        [string]   $TempPath,
        [int]      $MaxFileSizeMB = 100
    )

    Write-Log "========== STEP 8: MIGRATING COMPANY PHOTOS (GALLERY) =========="

    if (-not (Get-Command Get-HuduPhotos -ErrorAction SilentlyContinue)) {
        Write-Log "Get-HuduPhotos not available (Hudu >= 2.41 / HuduAPI 4.x). Skipping photo gallery." "WARN"
        return
    }

    Use-SourceHudu
    $allSourceFolders = @(Get-HuduObjectList -Response (Get-HuduFolders) -CollectionNames @('folders'))

    foreach ($co in $SourceCompanies) {
        if ($MigrationMode -eq "SINGLE" -and $co.id -ne $SelectedCompanyId) { continue }

        $targetCompanyId = $CompanyMap[[string]$co.id]
        if (-not $targetCompanyId) {
            Write-Log "No target mapping for company '$($co.name)'. Skipping photos." "WARN"
            continue
        }

        $sourceCompanyId = [int]($co.id)
        Use-SourceHudu
        $sourcePhotos = @()
        try {
            $rawPhotos = Get-HuduPhotos -CompanyId $sourceCompanyId
            $sourcePhotos = @(Get-HuduObjectList -Response $rawPhotos -CollectionNames @('photos'))
        } catch {
            Write-Log "Could not list photos for '$($co.name)': $_" "WARN"
            continue
        }

        if ($sourcePhotos.Count -eq 0) {
            Write-Log "No gallery photos for company '$($co.name)'." "INFO"
            continue
        }

        Write-Log "Found $($sourcePhotos.Count) gallery photo(s) for '$($co.name)'."

        $referencedFolderIds = @{}
        foreach ($p in $sourcePhotos) {
            if ($p.folder_id) { $referencedFolderIds[[string]$p.folder_id] = $true }
        }

        $photoFoldersForCompany = @($allSourceFolders | Where-Object {
            $_.company_id -eq $sourceCompanyId -and (
                (Test-IsPhotoFolder $_) -or $referencedFolderIds.ContainsKey([string]$_.id)
            )
        })

        $photoFolderMap = @{}
        if ($photoFoldersForCompany.Count -gt 0) {
            Write-Log "  Migrating $($photoFoldersForCompany.Count) photo folder(s) for '$($co.name)'..."
            Invoke-PhotoFolderMigration `
                -SourceFolders     $photoFoldersForCompany `
                -TargetCompanyId   ([int]$targetCompanyId) `
                -PhotoFolderMap    $photoFolderMap `
                -Stats             $Stats
        }

        $coPhotoTemp = Join-Path $TempPath "company_$($co.id)_gallery"
        if (Test-Path $coPhotoTemp) { Remove-Item $coPhotoTemp -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $coPhotoTemp -Force | Out-Null

        Use-SourceHudu
        $downloaded = @()
        try {
            $downloaded = @(Get-HuduPhotos -CompanyId $sourceCompanyId -Download -OutDir $coPhotoTemp)
        } catch {
            Write-Log "  Photo download batch failed for '$($co.name)': $_" "WARN"
            $downloaded = @($sourcePhotos)
        }

        $bySourceId = @{}
        foreach ($p in $downloaded) { if ($p.id) { $bySourceId[[string]$p.id] = $p } }

        foreach ($photo in $sourcePhotos) {
            if ($photo.archived) { continue }
            if ($photo.photoable_type -and $photo.photoable_type -notmatch '^(?i)company$') {
                Write-Log "  Skipping photo id $($photo.id): photoable_type '$($photo.photoable_type)' (asset/article photos not migrated)" "WARN"
                $Stats.PhotosFailed++
                continue
            }

            $dl = $bySourceId[[string]$photo.id]
            $localPath = $null
            if ($dl -and $dl.PSObject.Properties['localPath'] -and $dl.localPath -and (Test-Path -LiteralPath $dl.localPath)) {
                $localPath = $dl.localPath
            }

            if (-not $localPath) {
                Write-Log "  Skipping gallery photo id $($photo.id): download failed or missing file" "WARN"
                $Stats.PhotosFailed++
                continue
            }

            $caption = $photo.caption
            if ([string]::IsNullOrWhiteSpace($caption)) {
                $caption = [IO.Path]::GetFileNameWithoutExtension($localPath)
            }

            $targetFolderId = 0
            if ($photo.folder_id -and $photoFolderMap.ContainsKey([string]$photo.folder_id)) {
                $targetFolderId = $photoFolderMap[[string]$photo.folder_id]
            }

            try {
                Use-TargetHudu
                $params = @{
                    Path           = $localPath
                    Caption        = $caption
                    CompanyId      = [int]$targetCompanyId
                    Photoable_Type = 'Company'
                    Photoable_Id   = [int]$targetCompanyId
                }
                if ($targetFolderId -gt 0) { $params['FolderId'] = $targetFolderId }
                if ($photo.pinned)         { $params['Pinned'] = [bool]$photo.pinned }

                $result = New-HuduPhoto @params
                $created = $result.photo ?? $result
                if ($created -and $created.id) {
                    $Stats.PhotosUploaded++
                    $folderNote = if ($targetFolderId -gt 0) { " (folder $targetFolderId)" } else { '' }
                    Write-Log "  Uploaded gallery photo '$caption' => target ID $($created.id)$folderNote" "SUCCESS"
                } else {
                    $Stats.PhotosFailed++
                    Write-Log "  Upload returned no photo id for '$caption'" "WARN"
                }
            } catch {
                Write-Log "  Failed to upload gallery photo '$caption': $_" "ERROR"
                $Stats.PhotosFailed++
            }
        }

        Remove-Item $coPhotoTemp -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Photo folders - Created: $($Stats.PhotoFoldersCreated) | Skipped: $($Stats.PhotoFoldersSkipped) | Failed: $($Stats.PhotoFoldersFailed)"
    Write-Log "Gallery photos - Uploaded: $($Stats.PhotosUploaded) | Failed: $($Stats.PhotosFailed)"
}
