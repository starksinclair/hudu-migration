# ============================================================================
# Migrate-Folders.ps1 — hierarchy-aware folder migration
# ============================================================================

function Invoke-FolderMigration {
    param(
        [hashtable]$CompanyMap,
        [System.Collections.IDictionary]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId
    )

    Write-Log "========== STEP 2a: MIGRATING FOLDERS =========="

    $folderMap = @{}

    Use-SourceHudu
    $sourceFolders = Get-HuduFolders
    Write-Log "Found $($sourceFolders.Count) folders in source."

    $sourceFolderById = @{}
    foreach ($f in $sourceFolders) { $sourceFolderById[[string]$f.id] = $f }

    Use-TargetHudu
    $targetFolders = Get-HuduFolders
    $folderLookup  = @{}
    foreach ($f in $targetFolders) { Add-FolderLookupEntry -Lookup $folderLookup -Folder $f }

    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $sourceFolders) { $null = $pending.Add($f) }

    while ($pending.Count -gt 0) {
        $progressThisPass = 0

        for ($i = $pending.Count - 1; $i -ge 0; $i--) {
            $folder = $pending[$i]

            if ($MigrationMode -eq "SINGLE" -and
                $folder.company_id -and $folder.company_id -ne 0 -and
                $folder.company_id -ne $SelectedCompanyId) {
                $pending.RemoveAt($i); continue
            }

            if (Test-IsPhotoFolder $folder) {
                $pending.RemoveAt($i)
                continue
            }

            $targetCompanyId = $null
            if ($folder.company_id -and $folder.company_id -ne 0) {
                $targetCompanyId = $CompanyMap[[string]$folder.company_id]
                if (-not $targetCompanyId) {
                    Write-Log "No company mapping for folder '$($folder.name)'. Skipping." "WARN"
                    $pending.RemoveAt($i); continue
                }
            }

            $sourceParentId = Get-FolderParentFolderId $folder
            $targetParentId = $null
            if ($sourceParentId) {
                if (-not $folderMap.ContainsKey([string]$sourceParentId)) {
                    $parent = $sourceFolderById[[string]$sourceParentId]
                    if ($parent) {
                        if ($MigrationMode -eq "SINGLE" -and
                            $parent.company_id -and $parent.company_id -ne 0 -and
                            $parent.company_id -ne $SelectedCompanyId) {
                            Write-Log "Skipping child folder '$($folder.name)' — parent is outside SINGLE scope." "WARN"
                            $pending.RemoveAt($i); continue
                        }
                        continue  # parent not yet created; retry next pass
                    }
                }
                $targetParentId = $folderMap[[string]$sourceParentId]
                if (-not $targetParentId) { continue }
            }

            $key      = Get-FolderLookupKey -Name $folder.name -CompanyId $targetCompanyId -ParentFolderId $targetParentId
            $existing = $folderLookup[$key]
            if ($existing) {
                Write-Log "Folder '$($folder.name)' already exists in target. Mapping." "WARN"
                $folderMap[[string]$folder.id] = $existing.id
                $pending.RemoveAt($i); $progressThisPass++; continue
            }

            try {
                Use-TargetHudu
                $params = @{ Name = $folder.name }
                if ($targetCompanyId)    { $params['CompanyId']      = $targetCompanyId    }
                if ($targetParentId)     { $params['ParentFolderId'] = $targetParentId     }
                if ($folder.description) { $params['Description']    = $folder.description }

                $created = New-HuduFolder @params
                $newId   = $created.id ?? $created.folder.id
                $folderMap[[string]$folder.id] = $newId

                Add-FolderLookupEntry -Lookup $folderLookup -Folder ([PSCustomObject]@{
                    id               = $newId
                    name             = $folder.name
                    company_id       = $targetCompanyId
                    parent_folder_id = $targetParentId
                })

                $Stats.FoldersCreated++
                Write-Log "Created folder '$($folder.name)' => target ID $newId" "SUCCESS"
                $pending.RemoveAt($i); $progressThisPass++
            } catch {
                Write-Log "Failed to create folder '$($folder.name)': $_" "ERROR"
                $Stats.FoldersFailed++
                $pending.RemoveAt($i)
            }
        }

        if ($progressThisPass -eq 0) {
            foreach ($f in @($pending)) {
                Write-Log "Unable to resolve parent for folder '$($f.name)'; skipping." "WARN"
            }
            break
        }
    }

    Write-Log "Folders - Created: $($Stats.FoldersCreated) | Failed: $($Stats.FoldersFailed)"
    return $folderMap
}
