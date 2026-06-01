# ============================================================================
# Migrate-Articles.ps1 — articles, embedded images, and attachments
# ============================================================================

function Invoke-ArticleMigration {
    param(
        [hashtable]  $CompanyMap,
        [hashtable]  $FolderMap,
        [hashtable]  $Stats,
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
            }
            $articleMap[[string]$article.id] = $entry
            $Stats.ArticlesCreated++
            Write-Log "Created article '$($article.name)' => target ID $newId" "SUCCESS"

            $articleTempPath = Join-Path $TempPath "article_$($article.id)"
            if (-not (Test-Path $articleTempPath)) {
                New-Item -ItemType Directory -Path $articleTempPath -Force | Out-Null
            }

            # -- Public photos (embedded images) --
            if ($article.public_photos -and $article.public_photos.Count -gt 0) {
                foreach ($photo in $article.public_photos) {
                    $photoUrl  = if ($photo.url -match '^https?://') { $photo.url } else { "$($script:SourceHuduUrl)$($photo.url)" }
                    $photoName = if ($photo.file_name) { [System.IO.Path]::GetFileName($photo.file_name) } else { "photo_$($photo.id).bin" }
                    $photoPath = Join-Path $articleTempPath $photoName
                    $oldSlug   = if ($photo.slug) { $photo.slug } else { $photo.id }

                    try {
                        Use-SourceHudu
                        $plain   = Get-PlainText $script:SourceHuduApiKeySecure
                        $headers = @{ 'x-api-key' = $plain }
                        $plain   = $null
                        Invoke-WebRequest -Uri $photoUrl -Headers $headers -OutFile $photoPath -ErrorAction Stop

                        $uploaded = Upload-FileToHudu -FilePath $photoPath -ArticleId $newId
                        if ($uploaded) {
                            $newPhotoUrl      = $uploaded.url ?? $uploaded.file_url
                            if ($newPhotoUrl) {
                                $newPhotoRelative = ([uri]$newPhotoUrl).PathAndQuery
                                $entry.PhotoMap["/public_photo/$oldSlug"] = $newPhotoRelative
                                Write-Log "  Uploaded public photo '$photoName' => $newPhotoRelative" "SUCCESS"
                            } else {
                                Write-Log "  Uploaded '$photoName' but could not determine new URL — PhotoMap entry skipped." "WARN"
                            }
                            $Stats.FilesUploaded++
                        } else {
                            $Stats.FilesFailed++
                        }
                        Remove-Item $photoPath -Force -ErrorAction SilentlyContinue
                    } catch {
                        Write-Log "  Public photo download failed for '$photoName': $_" "WARN"
                        $Stats.FilesFailed++
                    }
                }
            }

            # -- Named uploads (non-image attachments) --
            if ($article.uploads -and $article.uploads.Count -gt 0) {
                foreach ($upload in $article.uploads) {
                    if (-not $upload.id) { continue }
                    Use-SourceHudu
                    try {
                        $downloaded = @(Get-HuduUploads -Id $upload.id -Download -OutDir $articleTempPath)
                    } catch {
                        Write-Log "  Upload download failed for article '$($article.name)' upload ID $($upload.id): $_" "ERROR"
                        continue
                    }

                    foreach ($attachment in $downloaded) {
                        $localPath = $attachment.localPath
                        if (-not $localPath -or -not (Test-Path $localPath)) { continue }
                        try {
                            $fileSizeMB = (Get-Item $localPath).Length / 1MB
                            $safeName   = Split-Path $localPath -Leaf

                            if ($fileSizeMB -gt $MaxFileSizeMB) {
                                Write-Log "SKIPPED (too large $([math]::Round($fileSizeMB,1))MB > ${MaxFileSizeMB}MB): $safeName" "WARN"
                                $Stats.FilesSkipped++
                                $SkippedFileManifest.Add([PSCustomObject]@{
                                    Article   = $article.name
                                    ArticleId = $article.id
                                    File      = $safeName
                                    SizeMB    = [math]::Round($fileSizeMB, 1)
                                    LimitMB   = $MaxFileSizeMB
                                })
                                Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                                continue
                            }

                            $up = Upload-FileToHudu -FilePath $localPath -ArticleId $newId
                            if ($up) { $Stats.FilesUploaded++; Write-Log "  Uploaded '$safeName'" "SUCCESS" }
                            else     { $Stats.FilesFailed++ }
                            Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                        } catch {
                            Write-Log "  File transfer failed for '$localPath': $_" "ERROR"
                            $Stats.FilesFailed++
                        }
                    }
                }
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
