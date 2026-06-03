# ============================================================================
# Migrate-Articles.ps1 — articles, embedded images, and attachments
# ============================================================================

function Invoke-ArticleMigration {
    param(
        [hashtable]  $CompanyMap,
        [hashtable]  $FolderMap,
        [System.Collections.IDictionary]$Stats,
        [System.Collections.Generic.List[PSCustomObject]]$SkippedFileManifest,
        [string]     $MigrationMode,
        [int]        $SelectedCompanyId,
        [string]     $TempPath,
        [int]        $MaxFileSizeMB
    )

    Write-Log "========== STEP 2b: MIGRATING ARTICLES =========="

    $articleMap = @{}

    Use-SourceHudu
    Write-Log "Fetching source articles..."
    try {
        if ($MigrationMode -eq "SINGLE") {
            $companyArticles   = @(Get-HuduArticles -company_id $SelectedCompanyId)
            $allSourceArticles = @(Get-HuduArticles)
            $globalArticles    = @($allSourceArticles | Where-Object { -not $_.company_id -or $_.company_id -eq 0 })
            $articles          = $companyArticles + $globalArticles
            Write-Log "SINGLE MODE: $($companyArticles.Count) company + $($globalArticles.Count) global KB articles"
        } else {
            $articles = @(Get-HuduArticles)
            Write-Log "ALL MODE: $($articles.Count) total articles"
        }
    } catch {
        Write-Log "Error fetching articles: $($_.Exception.Message)" "ERROR"
        $articles = @()
    }

    $idx   = 0
    $total = $articles.Count

    foreach ($article in $articles) {
        $idx++
        $pct = [math]::Round(($idx / $total) * 100)
        Write-Progress -Activity "Migrating Articles" -Status "$pct% - $($article.name)" -PercentComplete $pct

        $targetCompanyId = $null
        if ($article.company_id -and $article.company_id -ne 0) {
            $targetCompanyId = $CompanyMap[[string]$article.company_id]
            if (-not $targetCompanyId) {
                Write-Log "No company mapping for article '$($article.name)'. Creating as Global KB." "WARN"
            }
        }

        $targetFolderId = $null
        if ($article.folder_id -and $article.folder_id -ne 0) {
            $targetFolderId = $FolderMap[[string]$article.folder_id]
        }

        try {
            Use-TargetHudu
            $params = @{
                Name          = $article.name
                Content       = ($article.content ?? '')
                EnableSharing = [bool]($article.enable_sharing)
            }
            if ($targetCompanyId) { $params['CompanyId'] = $targetCompanyId }
            if ($targetFolderId)  { $params['FolderId']  = $targetFolderId  }

            $created    = New-HuduArticle @params
            $newArticle = $created.article ?? $created
            $newId      = $newArticle.id
            $newUrl     = $newArticle.url

            $entry = [PSCustomObject]@{
                SourceId  = $article.id
                TargetId  = $newId
                TargetUrl = $newUrl
                Name      = $article.name
                PhotoMap  = @{}   # /public_photo/{old_slug} -> /public_photo/{new_slug}
                FileMap   = @{}   # /file/{old_slug} -> /file/{new_slug}
            }
            $articleMap[[string]$article.id] = $entry
            $Stats.ArticlesCreated++
            Write-Log "Created article '$($article.name)' => target ID $newId" "SUCCESS"

            $articleTempPath = Join-Path $TempPath "article_$($article.id)"
            if (-not (Test-Path $articleTempPath)) {
                New-Item -ItemType Directory -Path $articleTempPath -Force | Out-Null
            }

            # Build a unified list of files to download + upload, matching the
            # Confluence migration's "process attachments" loop structure.
            # Each entry carries: Url, FileName, IsPublicPhoto, OldSlug
            $filesToProcess = [System.Collections.Generic.List[PSCustomObject]]::new()

            if ($article.public_photos -and $article.public_photos.Count -gt 0) {
                foreach ($photo in $article.public_photos) {
                    $photoUrl = $photo.url
                    $filesToProcess.Add([PSCustomObject]@{
                        Url           = if ($photoUrl -match '^https?://') { $photoUrl } else { "$($script:SourceHuduUrl)$photoUrl" }
                        FileName      = if ($photo.file_name) { [IO.Path]::GetFileName($photo.file_name) } else { "photo_$($photo.id).bin" }
                        IsPublicPhoto = $true
                        OldSlug       = if ($photo.slug) { $photo.slug } else { $photo.id }
                        PublicPhotoId = [string]($photo.id)
                        PublicPhotoNumericId = if ($photo.numeric_id) { [int]$photo.numeric_id } else { 0 }
                        OldPath       = if ($photoUrl) {
                            if ($photoUrl -match '^https?://') { ([uri]$photoUrl).PathAndQuery } else { $photoUrl }
                        } else { $null }
                    })
                }
            }

            if ($article.uploads -and $article.uploads.Count -gt 0) {
                foreach ($upload in $article.uploads) {
                    if (-not $upload.id) { continue }
                    $uploadUrl = $upload.url ?? $upload.file_url
                    if ([string]::IsNullOrWhiteSpace($uploadUrl)) { continue }
                    $filesToProcess.Add([PSCustomObject]@{
                        Url           = if ($uploadUrl -match '^https?://') { $uploadUrl } else { "$($script:SourceHuduUrl)$uploadUrl" }
                        FileName      = if ($upload.file_name) { [IO.Path]::GetFileName($upload.file_name) } else { "upload_$($upload.id).bin" }
                        IsPublicPhoto = $false
                        OldSlug       = $null
                        PublicPhotoId = $null
                        PublicPhotoNumericId = 0
                        OldPath       = if ($uploadUrl -match '^https?://') { ([uri]$uploadUrl).PathAndQuery } else { $uploadUrl }
                    })
                }
            }

            # Process each file: download from source, check size, upload to target
            foreach ($fileEntry in $filesToProcess) {
                $record = Invoke-HuduAttachDownload `
                    -Url       $fileEntry.Url `
                    -FileName  $fileEntry.FileName `
                    -OutDir    $articleTempPath `
                    -MaxSizeMB $MaxFileSizeMB `
                    -PublicPhotoId $fileEntry.PublicPhotoId `
                    -PublicPhotoNumericId $fileEntry.PublicPhotoNumericId

                if (-not $record.SuccessDownload) {
                    if ($record.FailureKind -eq 'MISSING_SOURCE_ASSET' -or $record.FailureKind -eq 'AUTH_OR_SCOPE') {
                        Write-Log "  Skipping source file '$($fileEntry.FileName)' due to $($record.FailureKind): $($record.AttemptDiagnostics)" "WARN"
                        $Stats.FilesSkipped++
                        $SkippedFileManifest.Add([PSCustomObject]@{
                            Article   = $article.name
                            ArticleId = $article.id
                            File      = $fileEntry.FileName
                            SizeMB    = $null
                            LimitMB   = $MaxFileSizeMB
                            Reason    = $record.FailureKind
                            SourceUrl = $fileEntry.Url
                            Attempts  = $record.AttemptDiagnostics
                        })
                    } else {
                        Write-Log "  Failed to download '$($fileEntry.FileName)' ($($fileEntry.Url))" "ERROR"
                        $Stats.FilesFailed++
                    }
                    continue
                }

                if ($record.AttachmentTooLarge) {
                    Write-Log "SKIPPED (too large $([math]::Round($record.AttachmentSize / 1MB, 1))MB > ${MaxFileSizeMB}MB): $($record.FileName)" "WARN"
                    $Stats.FilesSkipped++
                    $SkippedFileManifest.Add([PSCustomObject]@{
                        Article   = $article.name
                        ArticleId = $article.id
                        File      = $record.FileName
                        SizeMB    = [math]::Round($record.AttachmentSize / 1MB, 1)
                        LimitMB   = $MaxFileSizeMB
                        Reason    = 'TOO_LARGE'
                        SourceUrl = $fileEntry.Url
                        Attempts  = $record.AttemptDiagnostics
                    })
                    Remove-Item $record.LocalPath -Force -ErrorAction SilentlyContinue
                    continue
                }

                $uploaded = Upload-FileToHudu -FilePath $record.LocalPath -ArticleId $newId -AsPublicPhoto $fileEntry.IsPublicPhoto
                if ($uploaded -and $uploaded.Url) {
                    $Stats.FilesUploaded++
                    Write-Log "  Uploaded '$($record.FileName)' => $($uploaded.Url)" "SUCCESS"

                    # For public photos, map old slug -> new relative path for Step 4 relinking
                    if ($fileEntry.IsPublicPhoto -and $fileEntry.OldSlug) {
                        $newPhotoRelative = ([uri]$uploaded.Url).PathAndQuery
                        $entry.PhotoMap["/public_photo/$($fileEntry.OldSlug)"] = $newPhotoRelative
                        if ($fileEntry.OldPath) {
                            $entry.PhotoMap[$fileEntry.OldPath] = $newPhotoRelative
                        }
                    }

                    # For uploads (including image attachments), map source /file URLs
                    # to the new target /file URL so inline <img src="/file/..."> is fixed.
                    if (-not $fileEntry.IsPublicPhoto -and $fileEntry.OldPath) {
                        $newUploadRelative = ([uri]$uploaded.Url).PathAndQuery
                        $entry.FileMap[$fileEntry.OldPath] = $newUploadRelative
                    }
                } else {
                    $Stats.FilesFailed++
                    Write-Log "  Upload failed for '$($record.FileName)'" "ERROR"
                }

                Remove-Item $record.LocalPath -Force -ErrorAction SilentlyContinue
            }

            Remove-Item $articleTempPath -Recurse -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log "Failed to create article '$($article.name)': $_" "ERROR"
            $Stats.ArticlesFailed++
        }
    }

    Write-Progress -Activity "Migrating Articles" -Completed
    Write-Log "Articles - Created: $($Stats.ArticlesCreated) | Failed: $($Stats.ArticlesFailed)"
    Write-Log "Files    - Uploaded: $($Stats.FilesUploaded) | Skipped: $($Stats.FilesSkipped) | Failed: $($Stats.FilesFailed)"
    return $articleMap
}
