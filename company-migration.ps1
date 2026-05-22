# ============================================================================
# Hudu-to-Hudu Knowledge Base Migration Script with Company Selector
# Purpose: Migrate KB articles, companies, and folders from one Hudu instance
#          to another using the HuduAPI PowerShell module.
#          NOW WITH COMPANY SELECTION GUI FOR TESTING!
#
# Requirements:
#   - PowerShell 7+
#   - HuduAPI module (min 2.4.5): Install-Module HuduAPI -MinimumVersion 2.4.5
#
# Usage (interactive CLI with company selector):
#   . .\migrate_with_company_selector.ps1
#
# The script will:
#   1. Prompt for source and target credentials
#   2. Display a GUI with all companies from source
#   3. Let user choose: migrate ONE company (testing) or ALL companies (production)
#   4. Perform the migration with resume capability
# ============================================================================

#Requires -Version 7.0

# ============================================================================
# MODULE BOOTSTRAP
# ============================================================================

if (-not (Get-Module -ListAvailable -Name HuduAPI | Where-Object { $_.Version -ge [version]'2.4.5' })) {
    Write-Host "HuduAPI module (>=2.4.5) not found. Installing..." -ForegroundColor Yellow
    Install-Module HuduAPI -MinimumVersion 2.4.5 -Scope CurrentUser -Force
}
Import-Module HuduAPI -Force

# ============================================================================
# CONFIGURATION
# ============================================================================

$SourceHuduUrl = $SourceHuduUrl ?? (Read-Host "Source Hudu URL (e.g. https://source.hudu.com)")
$TargetHuduUrl = $TargetHuduUrl ?? (Read-Host "Target Hudu URL (e.g. https://target.hudu.com)")

# Accept SecureStrings or prompt securely
if (-not $SourceHuduApiKeySecure) {
    $SourceHuduApiKeySecure = Read-Host "Source Hudu API Key" -AsSecureString
}
if (-not $TargetHuduApiKeySecure) {
    $TargetHuduApiKeySecure = Read-Host "Target Hudu API Key" -AsSecureString
}

# Validate both are SecureString
if ($SourceHuduApiKeySecure -isnot [System.Security.SecureString] -or
    $TargetHuduApiKeySecure -isnot [System.Security.SecureString]) {
    Write-Host "API keys must be SecureString objects. Use -AsSecureString or the GUI launcher." -ForegroundColor Red
    return
}

[int]$MaxFileSizeMB = if ($MaxFileSizeMB) { $MaxFileSizeMB } else {
    $raw = Read-Host "Max file size to transfer in MB [default: 100]"
    if ($raw -match '^\d+$') { [int]$raw } else { 100 }
}

$TempPath = $TempPath ?? "C:\Temp\HuduMigration\downloads"
$LogDir   = $LogDir   ?? "C:\Temp\HuduMigration\logs"
$LogFile  = Join-Path $LogDir "migration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# ============================================================================
# HELPERS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    $color = switch ($Level) {
        "ERROR"   { "Red"     }
        "WARN"    { "Yellow"  }
        "SUCCESS" { "Green"   }
        default   { "Cyan"    }
    }
    Write-Host $line -ForegroundColor $color
}

function Save-Phase {
    param([string]$Name, [object]$Data)
    $path = Join-Path $LogDir "$Name.json"
    $Data | ConvertTo-Json -Depth 15 | Out-File $path -Encoding UTF8
    Write-Log "Phase '$Name' saved to $path"
}

function Load-Phase {
    param([string]$Name)
    $path = Join-Path $LogDir "$Name.json"
    if (Test-Path $path) {
        Write-Log "Resuming phase '$Name' from $path" "WARN"
        return Get-Content $path -Raw | ConvertFrom-Json
    }
    return $null
}

# Decrypt a SecureString to plaintext only at the moment of use
function Get-PlainText {
    param([System.Security.SecureString]$Secure)
    return [System.Net.NetworkCredential]::new('', $Secure).Password
}

# Swap HuduAPI context to SOURCE
function Use-SourceHudu {
    $plain = Get-PlainText $SourceHuduApiKeySecure
    New-HuduAPIKey $plain
    New-HuduBaseUrl $SourceHuduUrl
    $plain = $null
}

# Swap HuduAPI context to TARGET
function Use-TargetHudu {
    $plain = Get-PlainText $TargetHuduApiKeySecure
    New-HuduAPIKey $plain
    New-HuduBaseUrl $TargetHuduUrl
    $plain = $null
}

# Upload file to Hudu (images vs. documents)
function Upload-FileToHudu {
    param(
        [string]$FilePath,
        [int]   $ArticleId
    )
    if (-not (Test-Path $FilePath)) {
        Write-Log "File not found for upload: $FilePath" "ERROR"
        return $null
    }
    $ext    = [IO.Path]::GetExtension($FilePath).ToLower()
    $images = @('.jpg','.jpeg','.png','.gif','.webp','.bmp','.svg','.tiff','.tif')
    Use-TargetHudu
    try {
        if ($ext -in $images) {
            $result = New-HuduPublicPhoto -FilePath $FilePath -record_id $ArticleId -record_type 'Article'
            return $result.public_photo ?? $result
        } else {
            $result = New-HuduUpload -FilePath $FilePath -record_id $ArticleId -record_type 'Article'
            return $result.upload ?? $result
        }
    } catch {
        Write-Log "Upload failed for $FilePath => article $ArticleId : $_" "ERROR"
        return $null
    }
}

# ============================================================================
# COMPANY SELECTION GUI
# ============================================================================

function Show-CompanySelector {
    param([object[]]$Companies)
    
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Hudu Migration - Company Selector"
    $form.Size = New-Object System.Drawing.Size(600, 500)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    # Title
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Select Migration Mode"
    $titleLabel.Location = New-Object System.Drawing.Point(20, 20)
    $titleLabel.Size = New-Object System.Drawing.Size(550, 30)
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)

    # Instructions
    $instructionLabel = New-Object System.Windows.Forms.Label
    $instructionLabel.Text = "Choose a single company to test, or migrate all companies at once."
    $instructionLabel.Location = New-Object System.Drawing.Point(20, 55)
    $instructionLabel.Size = New-Object System.Drawing.Size(550, 25)
    $instructionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
    $form.Controls.Add($instructionLabel)

    # Company ListBox
    $companyLabel = New-Object System.Windows.Forms.Label
    $companyLabel.Text = "Companies in Source Instance:"
    $companyLabel.Location = New-Object System.Drawing.Point(20, 85)
    $companyLabel.Size = New-Object System.Drawing.Size(550, 20)
    $companyLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($companyLabel)

    $listBox = New-Object System.Windows.Forms.ListBox
    $listBox.Location = New-Object System.Drawing.Point(20, 110)
    $listBox.Size = New-Object System.Drawing.Size(550, 250)
    $listBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $listBox.SelectionMode = "One"
    
    foreach ($company in $Companies) {
        $displayText = "$($company.name) (ID: $($company.id))"
        $listBox.Items.Add($displayText) | Out-Null
    }
    
    $form.Controls.Add($listBox)

    # Info Label
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "✓ Tip: Start with a small company for testing before running full migration"
    $infoLabel.Location = New-Object System.Drawing.Point(20, 365)
    $infoLabel.Size = New-Object System.Drawing.Size(550, 35)
    $infoLabel.AutoSize = $false
    $infoLabel.WordWrap = $true
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
    $infoLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
    $form.Controls.Add($infoLabel)

    # Buttons
    $migrateOneButton = New-Object System.Windows.Forms.Button
    $migrateOneButton.Text = "Migrate This Company"
    $migrateOneButton.Location = New-Object System.Drawing.Point(20, 410)
    $migrateOneButton.Size = New-Object System.Drawing.Size(170, 40)
    $migrateOneButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $migrateOneButton.ForeColor = [System.Drawing.Color]::White
    $migrateOneButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($migrateOneButton)

    $migrateAllButton = New-Object System.Windows.Forms.Button
    $migrateAllButton.Text = "Migrate All Companies"
    $migrateAllButton.Location = New-Object System.Drawing.Point(205, 410)
    $migrateAllButton.Size = New-Object System.Drawing.Size(170, 40)
    $migrateAllButton.BackColor = [System.Drawing.Color]::FromArgb(0, 176, 80)
    $migrateAllButton.ForeColor = [System.Drawing.Color]::White
    $migrateAllButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($migrateAllButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(390, 410)
    $cancelButton.Size = New-Object System.Drawing.Size(180, 40)
    $cancelButton.BackColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $cancelButton.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($cancelButton)

    $script:migrationMode = $null
    $script:selectedCompanyId = $null

    $migrateOneButton.Add_Click({
        if ($listBox.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show("Please select a company first", "Selection Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        $script:migrationMode = "SINGLE"
        $script:selectedCompanyId = $Companies[$listBox.SelectedIndex].id
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $migrateAllButton.Add_Click({
        $script:migrationMode = "ALL"
        $script:selectedCompanyId = $null
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $cancelButton.Add_Click({
        $script:migrationMode = "CANCEL"
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })

    $form.ShowDialog() | Out-Null
    
    return @{
        Mode = $script:migrationMode
        CompanyId = $script:selectedCompanyId
    }
}

# ============================================================================
# DIRECTORY SETUP
# ============================================================================

foreach ($dir in @($TempPath, $LogDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ============================================================================
# MAIN MIGRATION
# ============================================================================

try {

    Write-Log "=== Hudu-to-Hudu Migration Started ==="
    Write-Log "Source : $SourceHuduUrl"
    Write-Log "Target : $TargetHuduUrl"

    # --------------------------------------------------------------------------
    # PRE-FLIGHT: VERIFY CONNECTIVITY
    # --------------------------------------------------------------------------

    Write-Log "--- Pre-flight: verifying connectivity ---"

    Use-SourceHudu
    try {
        $srcInfo = Get-HuduAppInfo
        Write-Log "Source Hudu version: $($srcInfo.version)" "SUCCESS"
    } catch {
        Write-Log "Cannot connect to SOURCE Hudu. Check URL and API key. Error: $_" "ERROR"
        return
    }

    Use-TargetHudu
    try {
        $tgtInfo = Get-HuduAppInfo
        Write-Log "Target Hudu version: $($tgtInfo.version)" "SUCCESS"
    } catch {
        Write-Log "Cannot connect to TARGET Hudu. Check URL and API key. Error: $_" "ERROR"
        return
    }

    # --------------------------------------------------------------------------
    # FETCH COMPANIES AND SHOW SELECTOR
    # --------------------------------------------------------------------------

    Write-Log "--- Fetching companies from source ---"
    Use-SourceHudu
    $sourceCompanies = Get-HuduCompanies
    Write-Log "Found $($sourceCompanies.Count) companies" "SUCCESS"

    if ($sourceCompanies.Count -eq 0) {
        Write-Log "No companies found in source instance. Exiting." "ERROR"
        return
    }

    # Show company selector GUI
    Write-Host "`nLaunching company selector GUI..." -ForegroundColor Cyan
    $selection = Show-CompanySelector -Companies $sourceCompanies

    if ($selection.Mode -eq "CANCEL") {
        Write-Log "Migration cancelled by user." "WARN"
        return
    }

    $migrationMode = $selection.Mode
    $selectedCompanyId = $selection.CompanyId

    if ($migrationMode -eq "SINGLE") {
        $selectedCompany = $sourceCompanies | Where-Object { $_.id -eq $selectedCompanyId }
        Write-Log "=== SINGLE COMPANY MODE: $($selectedCompany.name) (ID: $selectedCompanyId) ===" "SUCCESS"
    } else {
        Write-Log "=== FULL MIGRATION MODE: ALL COMPANIES ===" "SUCCESS"
    }

    # --------------------------------------------------------------------------
    # COUNTERS & MAPPINGS
    # --------------------------------------------------------------------------

    $Stats = [ordered]@{
        CompaniesCreated = 0
        CompaniesSkipped = 0
        CompaniesFailed  = 0
        FoldersCreated   = 0
        FoldersFailed    = 0
        ArticlesCreated  = 0
        ArticlesFailed   = 0
        FilesUploaded    = 0
        FilesSkipped     = 0
        FilesFailed      = 0
    }

    $CompanyMap = @{}
    $FolderMap  = @{}
    $ArticleMap = @{}

    # ==========================================================================
    # STEP 1: MIGRATE COMPANIES
    # ==========================================================================

    Write-Log "========== STEP 1: MIGRATING COMPANIES =========="

    Use-TargetHudu
    $targetCompanies = Get-HuduCompanies

    foreach ($co in $sourceCompanies) {
        # If SINGLE mode, skip companies that aren't selected
        if ($migrationMode -eq "SINGLE" -and $co.id -ne $selectedCompanyId) {
            continue
        }

        $existing = $targetCompanies | Where-Object { $_.name -eq $co.name } | Select-Object -First 1
        if ($existing) {
            Write-Log "Company '$($co.name)' already exists in target (ID $($existing.id)). Mapping." "WARN"
            $CompanyMap[[string]$co.id] = $existing.id
            $Stats.CompaniesSkipped++
            continue
        }
        try {
            Use-TargetHudu
            $created = New-HuduCompany -Name $co.name `
                -Nickname     ($co.nickname       ?? '') `
                -PhoneNumber  ($co.phone_number   ?? '') `
                -Website      ($co.website        ?? '') `
                -City         ($co.city           ?? '') `
                -State        ($co.state          ?? '') `
                -Zip          ($co.zip            ?? '') `
                -CountryName  ($co.country_name   ?? '') `
                -AddressLine1 ($co.address_line_1 ?? '') `
                -Notes        ($co.notes          ?? '')
            $newId = $created.id ?? $created.company.id
            $CompanyMap[[string]$co.id] = $newId
            $Stats.CompaniesCreated++
            Write-Log "Created company '$($co.name)' => target ID $newId" "SUCCESS"
        } catch {
            Write-Log "Failed to create company '$($co.name)': $_" "ERROR"
            $Stats.CompaniesFailed++
        }
    }

    Write-Log "Companies - Created: $($Stats.CompaniesCreated) | Matched: $($Stats.CompaniesSkipped) | Failed: $($Stats.CompaniesFailed)"

    # ==========================================================================
    # STEP 2: MIGRATE FOLDERS
    # ==========================================================================

    Write-Log "========== STEP 2: MIGRATING FOLDERS =========="

    Use-SourceHudu
    $sourceFolders = Get-HuduFolders
    Write-Log "Found $($sourceFolders.Count) folders in source."

    Use-TargetHudu
    $targetFolders = Get-HuduFolders

    foreach ($folder in $sourceFolders) {
        # If SINGLE mode, skip folders not associated with selected company
        if ($migrationMode -eq "SINGLE") {
            if ($folder.company_id -and $folder.company_id -ne 0 -and $folder.company_id -ne $selectedCompanyId) {
                continue
            }
        }

        $targetCompanyId = $null
        if ($folder.company_id -and $folder.company_id -ne 0) {
            $targetCompanyId = $CompanyMap[[string]$folder.company_id]
            if (-not $targetCompanyId) {
                Write-Log "No company mapping for folder '$($folder.name)'. Skipping." "WARN"
                continue
            }
        }

        $existing = $targetFolders | Where-Object {
            $_.name -eq $folder.name -and
            (($targetCompanyId -and $_.company_id -eq $targetCompanyId) -or
             (-not $targetCompanyId -and -not $_.company_id))
        } | Select-Object -First 1

        if ($existing) {
            Write-Log "Folder '$($folder.name)' already exists in target. Mapping." "WARN"
            $FolderMap[[string]$folder.id] = $existing.id
            continue
        }

        try {
            Use-TargetHudu
            $params = @{ Name = $folder.name }
            if ($targetCompanyId)    { $params.CompanyId   = $targetCompanyId    }
            if ($folder.description) { $params.Description = $folder.description }
            $created = New-HuduFolder @params
            $newId   = $created.id ?? $created.folder.id
            $FolderMap[[string]$folder.id] = $newId
            $Stats.FoldersCreated++
            Write-Log "Created folder '$($folder.name)' => target ID $newId" "SUCCESS"
        } catch {
            Write-Log "Failed to create folder '$($folder.name)': $_" "ERROR"
            $Stats.FoldersFailed++
        }
    }

    Write-Log "Folders - Created: $($Stats.FoldersCreated) | Failed: $($Stats.FoldersFailed)"

    # ==========================================================================
    # STEP 3: MIGRATE ARTICLES (paginated, with attachments)
    # ==========================================================================

    Write-Log "========== STEP 3: MIGRATING ARTICLES =========="

    Use-SourceHudu
    $allSourceArticles = [System.Collections.ArrayList]@()
    $page = 1; $pageSize = 50
    Write-Log "Fetching all source articles (page size $pageSize)..."
    do {
        try {
            $batch = Get-HuduArticles -PageSize $pageSize -Page $page
            if ($batch -and $batch.Count -gt 0) {
                $allSourceArticles.AddRange($batch) | Out-Null
                Write-Log "  Page $page : $($batch.Count) articles (total: $($allSourceArticles.Count))"
                $page++
            } else { break }
        } catch {
            Write-Log "Error fetching articles page $page : $_" "ERROR"
            break
        }
    } while ($true)
    Write-Log "Total source articles: $($allSourceArticles.Count)"

    # If SINGLE mode, filter to only articles in selected company
    if ($migrationMode -eq "SINGLE") {
        $articlesToMigrate = $allSourceArticles | Where-Object { $_.company_id -eq $selectedCompanyId }
        Write-Log "SINGLE MODE: Filtering to $($articlesToMigrate.Count) articles in selected company"
    } else {
        $articlesToMigrate = $allSourceArticles
    }

    $idx = 0
    foreach ($article in $articlesToMigrate) {
        $idx++
        $pct = [math]::Round(($idx / $articlesToMigrate.Count) * 100)
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
                Content       = $article.content ?? ''
                EnableSharing = [bool]($article.enable_sharing)
            }
            if ($targetCompanyId) { $params.CompanyId = $targetCompanyId }
            if ($targetFolderId)  { $params.FolderId  = $targetFolderId  }

            $created    = New-HuduArticle @params
            $newArticle = $created.article ?? $created
            $newId      = $newArticle.id
            $newUrl     = $newArticle.url

            $entry = [PSCustomObject]@{
                SourceId  = $article.id
                TargetId  = $newId
                TargetUrl = $newUrl
                Name      = $article.name
            }
            $ArticleMap[[string]$article.id] = $entry
            $Stats.ArticlesCreated++
            Write-Log "Created article '$($article.name)' => target ID $newId" "SUCCESS"

            # -- Attachments --
            $filesToProcess = @()
            if ($article.public_photos -and $article.public_photos.Count -gt 0) {
                $filesToProcess += $article.public_photos
            }
            if ($article.uploads -and $article.uploads.Count -gt 0) {
                $filesToProcess += $article.uploads | ForEach-Object { $_.url }
            }

            foreach ($fileUrl in $filesToProcess) {
                if (-not $fileUrl) { continue }
                try {
                    $rawName   = [IO.Path]::GetFileName($fileUrl.Split('?')[0])
                    $safeName  = $rawName -replace '[^\w\.\-]', '_'
                    $localPath = Join-Path $TempPath $safeName

                    # Download
                    $srcKey = Get-PlainText $SourceHuduApiKeySecure
                    Invoke-WebRequest -Uri $fileUrl -OutFile $localPath `
                        -Headers @{ "x-api-key" = $srcKey } -ErrorAction Stop
                    $srcKey = $null

                    $fileSizeMB = (Get-Item $localPath).Length / 1MB
                    if ($fileSizeMB -gt $MaxFileSizeMB) {
                        Write-Log "SKIPPED (too large $([math]::Round($fileSizeMB,1))MB > ${MaxFileSizeMB}MB): $safeName" "WARN"
                        $Stats.FilesSkipped++
                        Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                        continue
                    }

                    $uploaded = Upload-FileToHudu -FilePath $localPath -ArticleId $newId
                    if ($uploaded) { $Stats.FilesUploaded++; Write-Log "  Uploaded '$safeName'" "SUCCESS" }
                    else           { $Stats.FilesFailed++ }
                    Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Log "  File transfer failed for '$fileUrl': $_" "ERROR"
                    $Stats.FilesFailed++
                }
            }
        } catch {
            Write-Log "Failed to create article '$($article.name)': $_" "ERROR"
            $Stats.ArticlesFailed++
        }
    }

    Write-Progress -Activity "Migrating Articles" -Completed
    Write-Log "Articles - Created: $($Stats.ArticlesCreated) | Failed: $($Stats.ArticlesFailed)"
    Write-Log "Files    - Uploaded: $($Stats.FilesUploaded) | Skipped: $($Stats.FilesSkipped) | Failed: $($Stats.FilesFailed)"

    # ==========================================================================
    # STEP 4: RELINK - rewrite source URLs to target URLs in article content
    # ==========================================================================

    Write-Log "========== STEP 4: RELINKING INTERNAL URLS =========="

    $relinkedCount = 0; $relinkFailed = 0

    foreach ($entry in $ArticleMap.Values) {
        Use-SourceHudu
        try {
            $srcArticle = Get-HuduArticles -Id $entry.SourceId
            $srcArticle = $srcArticle.article ?? $srcArticle
        } catch {
            Write-Log "Could not fetch source article ID $($entry.SourceId): $_" "ERROR"
            $relinkFailed++
            continue
        }

        $html = $srcArticle.content
        if (-not $html) { continue }

        # Replace source article URLs with target URLs
        foreach ($map in $ArticleMap.Values) {
            if (-not $map.TargetUrl) { continue }
            $srcPattern = [regex]::Escape("$SourceHuduUrl") + '[^"''<>\s]*' + [regex]::Escape($map.SourceId.ToString())
            $html = [regex]::Replace($html, $srcPattern, $map.TargetUrl, 'IgnoreCase')
        }

        # Swap base-URL references
        $html = $html -replace [regex]::Escape($SourceHuduUrl), $TargetHuduUrl

        if ($html -ne $srcArticle.content) {
            Use-TargetHudu
            try {
                Set-HuduArticle -ArticleId $entry.TargetId -Name $entry.Name -Content $html | Out-Null
                $relinkedCount++
                Write-Log "Relinked '$($entry.Name)'" "SUCCESS"
            } catch {
                Write-Log "Relink update failed for '$($entry.Name)': $_" "ERROR"
                $relinkFailed++
            }
        }
    }

    Write-Log "Relinking - Updated: $relinkedCount | Failed: $relinkFailed"

    # ==========================================================================
    # SUMMARY
    # ==========================================================================

    Write-Log "=========================================="
    Write-Log "=           MIGRATION COMPLETE           ="
    Write-Log "=========================================="
    Write-Log "Mode: $migrationMode"
    Write-Log "Companies  - Created: $($Stats.CompaniesCreated) | Matched: $($Stats.CompaniesSkipped) | Failed: $($Stats.CompaniesFailed)"
    Write-Log "Folders    - Created: $($Stats.FoldersCreated) | Failed: $($Stats.FoldersFailed)"
    Write-Log "Articles   - Created: $($Stats.ArticlesCreated) | Failed: $($Stats.ArticlesFailed)"
    Write-Log "Files      - Uploaded: $($Stats.FilesUploaded) | Skipped: $($Stats.FilesSkipped) | Failed: $($Stats.FilesFailed)"
    Write-Log "Relinking  - Updated: $relinkedCount | Failed: $relinkFailed"
    Write-Log "Log  : $LogFile"
    Write-Log "Data : $LogDir"

    Write-Host "`nMappings available: `$CompanyMap, `$FolderMap, `$ArticleMap" -ForegroundColor Magenta

} finally {
    # ----------------------------------------------------------
    # SECURE CLEANUP
    # ----------------------------------------------------------
    if ($SourceHuduApiKeySecure -is [System.Security.SecureString]) {
        $SourceHuduApiKeySecure.Dispose()
    }
    if ($TargetHuduApiKeySecure -is [System.Security.SecureString]) {
        $TargetHuduApiKeySecure.Dispose()
    }
    Remove-Variable -Name SourceHuduApiKeySecure, TargetHuduApiKeySecure `
        -Scope Script -ErrorAction SilentlyContinue
    [System.GC]::Collect()
    Write-Host "API keys cleared from memory." -ForegroundColor DarkGray
}