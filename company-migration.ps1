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

# Strip trailing slashes — the HuduAPI module adds its own
$SourceHuduUrl = $SourceHuduUrl.TrimEnd('/')
$TargetHuduUrl = $TargetHuduUrl.TrimEnd('/')

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

# Cross-platform paths (works on macOS, Linux, and Windows)
$MigrationRoot = Join-Path $HOME "HuduMigration"
$TempPath = $TempPath ?? (Join-Path $MigrationRoot "downloads")
$LogDir   = $LogDir   ?? (Join-Path $MigrationRoot "logs")
$LogFile  = Join-Path $LogDir "migration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# ============================================================================
# DIRECTORY SETUP (must happen before Write-Log is called)
# ============================================================================

foreach ($dir in @($TempPath, $LogDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ============================================================================
# HELPERS
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    # Guard against null $LogFile (e.g. if directory setup hasn't run yet)
    if ($script:LogFile -and (Test-Path (Split-Path $script:LogFile -Parent))) {
        Add-Content -Path $script:LogFile -Value $line
    }
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        default    { "Cyan" }
    }
    Write-Host $line -ForegroundColor $color
}

function Save-Phase {
    param(
        [string]$Name,
        [object]$Data
    )

    $path = Join-Path $LogDir "$Name.json"
    $Data | ConvertTo-Json -Depth 20 | Set-Content -Path $path
    Write-Log "Phase '$Name' saved to $path"
}

function Read-Phase {
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

function Get-FolderCompanyId {
    param([object]$Folder)

    if ($Folder.PSObject.Properties['company_id'] -and $Folder.company_id) {
        return [int]$Folder.company_id
    }

    return $null
}

function Get-FolderParentFolderId {
    param([object]$Folder)

    foreach ($propertyName in @('parent_folder_id', 'parent_id')) {
        if ($Folder.PSObject.Properties[$propertyName] -and $Folder.$propertyName) {
            return [int]$Folder.$propertyName
        }
    }

    return $null
}

function Get-FolderLookupKey {
    param(
        [string]$Name,
        [object]$CompanyId,
        [object]$ParentFolderId
    )

    $companyValue = if ($CompanyId) { [string]$CompanyId } else { '0' }
    $parentValue  = if ($ParentFolderId) { [string]$ParentFolderId } else { '0' }
    return ('{0}|{1}|{2}' -f $Name.Trim().ToLowerInvariant(), $companyValue, $parentValue)
}

function Add-FolderLookupEntry {
    param(
        [hashtable]$Lookup,
        [object]$Folder
    )

    if (-not $Folder -or -not $Folder.name) {
        return
    }

    $companyId = Get-FolderCompanyId $Folder
    $parentId  = Get-FolderParentFolderId $Folder
    $key       = Get-FolderLookupKey -Name $Folder.name -CompanyId $companyId -ParentFolderId $parentId
    if (-not $Lookup.ContainsKey($key)) {
        $Lookup[$key] = $Folder
    }
}

# Swap HuduAPI context to SOURCE
function Use-SourceHudu {
    $plain = Get-PlainText $SourceHuduApiKeySecure
    Remove-HuduAPIKey -ErrorAction SilentlyContinue
    Remove-HuduBaseURL -ErrorAction SilentlyContinue
    New-HuduAPIKey $plain
    New-HuduBaseUrl $SourceHuduUrl
    $plain = $null
}

# Swap HuduAPI context to TARGET
function Use-TargetHudu {
    $plain = Get-PlainText $TargetHuduApiKeySecure
    Remove-HuduAPIKey -ErrorAction SilentlyContinue
    Remove-HuduBaseURL -ErrorAction SilentlyContinue
    New-HuduAPIKey $plain
    New-HuduBaseUrl $TargetHuduUrl
    $plain = $null
}

# Upload file to Hudu
function Send-FileToHudu {
    param(
        [string]$FilePath,
        [int]   $ArticleId,
        [string]$Caption
    )
    if (-not (Test-Path $FilePath)) {
        Write-Log "File not found for upload: $FilePath" "ERROR"
        return $null
    }
    Use-TargetHudu
    try {
        $result = New-HuduUpload -FilePath $FilePath -uploadable_id $ArticleId -uploadable_type Article
        $upload = $result.upload ?? $result
        return [PSCustomObject]@{
            Kind = 'Upload'
            Id   = $upload.id ?? $result.id
            Raw  = $upload
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

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "Select Migration Mode"
    $titleLabel.Location = New-Object System.Drawing.Point(20, 20)
    $titleLabel.Size = New-Object System.Drawing.Size(550, 30)
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)

    $instructionLabel = New-Object System.Windows.Forms.Label
    $instructionLabel.Text = "Choose a single company to test, or migrate all companies at once."
    $instructionLabel.Location = New-Object System.Drawing.Point(20, 55)
    $instructionLabel.Size = New-Object System.Drawing.Size(550, 25)
    $instructionLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
    $form.Controls.Add($instructionLabel)

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

    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Text = "✓ Tip: Start with a small company for testing before running full migration"
    $infoLabel.Location = New-Object System.Drawing.Point(20, 365)
    $infoLabel.Size = New-Object System.Drawing.Size(550, 35)
    $infoLabel.AutoSize = $false
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
    $infoLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
    $form.Controls.Add($infoLabel)

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

    # REQUIRED: configure the HuduAPI error log directory before any API calls
    # Without this, every write operation (POST/PUT) throws "Cannot bind parameter Path"
    Set-HapiErrorsDirectory -Path $LogDir | Out-Null

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
            # Splat only non-null params — passing empty strings causes bind errors
            $coParams = @{ Name = $co.name }
            if ($co.nickname)       { $coParams['Nickname']     = $co.nickname       }
            if ($co.phone_number)   { $coParams['PhoneNumber']  = $co.phone_number   }
            if ($co.website)        { $coParams['Website']      = $co.website        }
            if ($co.city)           { $coParams['City']         = $co.city           }
            if ($co.state)          { $coParams['State']        = $co.state          }
            if ($co.zip)            { $coParams['Zip']          = $co.zip            }
            if ($co.country_name)   { $coParams['CountryName']  = $co.country_name   }
            if ($co.address_line_1) { $coParams['AddressLine1'] = $co.address_line_1 }
            if ($co.notes)          { $coParams['Notes']        = $co.notes          }
            $created = New-HuduCompany @coParams
            $newId   = $created.company.id ?? $created.id
            $CompanyMap[[string]$co.id] = $newId
            $Stats.CompaniesCreated++
            Write-Log "Created company '$($co.name)' => target ID $newId" "SUCCESS"
        } catch {
            Write-Log "Failed to create company '$($co.name)': $_" "ERROR"
            $Stats.CompaniesFailed++
        }
    }

    Write-Log "Companies - Created: $($Stats.CompaniesCreated) | Matched: $($Stats.CompaniesSkipped) | Failed: $($Stats.CompaniesFailed)"

    # ============================================================================
    # STEP 2: MIGRATE KNOWLEDGE BASE
    # ============================================================================

    # --------------------------------------------------------------------------
    # STEP 2a: MIGRATE FOLDERS (hierarchy-aware, with company mapping)
    # --------------------------------------------------------------------------

    Write-Log "========== STEP 2a: MIGRATING FOLDERS =========="

    Use-SourceHudu
    $sourceFolders = Get-HuduFolders
    Write-Log "Found $($sourceFolders.Count) folders in source."

    $sourceFolderById = @{}
    foreach ($folder in $sourceFolders) {
        $sourceFolderById[[string]$folder.id] = $folder
    }

    Use-TargetHudu
    $targetFolders = Get-HuduFolders
    $FolderLookup = @{}

    foreach ($targetFolder in $targetFolders) {
        Add-FolderLookupEntry -Lookup $FolderLookup -Folder $targetFolder
    }

    $pendingFolders = [System.Collections.Generic.List[object]]::new()
    foreach ($folder in $sourceFolders) {
        $null = $pendingFolders.Add($folder)
    }

    while ($pendingFolders.Count -gt 0) {
        $progressThisPass = 0

        for ($index = $pendingFolders.Count - 1; $index -ge 0; $index--) {
            $folder = $pendingFolders[$index]

            # If SINGLE mode, skip folders not associated with selected company
            if ($migrationMode -eq "SINGLE") {
                if ($folder.company_id -and $folder.company_id -ne 0 -and $folder.company_id -ne $selectedCompanyId) {
                    $pendingFolders.RemoveAt($index)
                    continue
                }
            }

            $targetCompanyId = $null
            if ($folder.company_id -and $folder.company_id -ne 0) {
                $targetCompanyId = $CompanyMap[[string]$folder.company_id]
                if (-not $targetCompanyId) {
                    Write-Log "No company mapping for folder '$($folder.name)'. Skipping." "WARN"
                    $pendingFolders.RemoveAt($index)
                    continue
                }
            }

            $sourceParentId = Get-FolderParentFolderId $folder
            $targetParentId = $null
            if ($sourceParentId) {
                if (-not $FolderMap.ContainsKey([string]$sourceParentId)) {
                    $sourceParent = $sourceFolderById[[string]$sourceParentId]
                    if ($sourceParent) {
                        if ($migrationMode -eq "SINGLE" -and $sourceParent.company_id -and $sourceParent.company_id -ne 0 -and $sourceParent.company_id -ne $selectedCompanyId) {
                            Write-Log "Skipping child folder '$($folder.name)' because its parent is outside SINGLE mode scope." "WARN"
                            $pendingFolders.RemoveAt($index)
                            continue
                        }
                        continue
                    }
                }

                $targetParentId = $FolderMap[[string]$sourceParentId]
                if (-not $targetParentId) {
                    continue
                }
            }

            $folderKey = Get-FolderLookupKey -Name $folder.name -CompanyId $targetCompanyId -ParentFolderId $targetParentId
            $existing = $FolderLookup[$folderKey]

            if ($existing) {
                Write-Log "Folder '$($folder.name)' already exists in target. Mapping." "WARN"
                $FolderMap[[string]$folder.id] = $existing.id
                $pendingFolders.RemoveAt($index)
                $progressThisPass++
                continue
            }

            try {
                Use-TargetHudu
                $params = @{ Name = $folder.name }
                if ($targetCompanyId)    { $params.CompanyId      = $targetCompanyId    }
                if ($targetParentId)     { $params.ParentFolderId = $targetParentId     }
                if ($folder.description) { $params.Description    = $folder.description }
                $created = New-HuduFolder @params
                $newId   = $created.id ?? $created.folder.id
                $FolderMap[[string]$folder.id] = $newId

                $createdFolder = [PSCustomObject]@{
                    id               = $newId
                    name             = $folder.name
                    company_id       = $targetCompanyId
                    parent_folder_id = $targetParentId
                }
                Add-FolderLookupEntry -Lookup $FolderLookup -Folder $createdFolder

                $Stats.FoldersCreated++
                Write-Log "Created folder '$($folder.name)' => target ID $newId" "SUCCESS"
                $pendingFolders.RemoveAt($index)
                $progressThisPass++
            } catch {
                Write-Log "Failed to create folder '$($folder.name)': $_" "ERROR"
                $Stats.FoldersFailed++
                $pendingFolders.RemoveAt($index)
            }
        }

        if ($progressThisPass -eq 0) {
            foreach ($folder in @($pendingFolders)) {
                Write-Log "Unable to resolve parent mapping for folder '$($folder.name)'; skipping to avoid an incorrect hierarchy." "WARN"
            }
            break
        }
    }

    Write-Log "Folders - Created: $($Stats.FoldersCreated) | Failed: $($Stats.FoldersFailed)"

    # --------------------------------------------------------------------------
    # STEP 2b: MIGRATE ARTICLES (with company and folder mapping, plus attachments)
    # --------------------------------------------------------------------------

    Write-Log "========== STEP 2b: MIGRATING ARTICLES =========="

    Use-SourceHudu
    Write-Log "Fetching source articles..."
    # Get-HuduArticles fetches all at once; -PageSize/-Page params do not exist in this module version
    try {
        if ($migrationMode -eq "SINGLE") {
            $articlesToMigrate = @(Get-HuduArticles -company_id $selectedCompanyId)
            Write-Log "SINGLE MODE: Found $($articlesToMigrate.Count) articles for selected company"
        } else {
            $articlesToMigrate = @(Get-HuduArticles)
            Write-Log "ALL MODE: Found $($articlesToMigrate.Count) total articles"
        }
    } catch {
        Write-Log "Error fetching articles: $($_.Exception.Message)" "ERROR"
        $articlesToMigrate = @()
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
            $articleHtml = $article.content ?? ''
            $params = @{
                Name          = $article.name
                Content       = $articleHtml
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
            $articleTempPath = Join-Path $TempPath "article_$($article.id)"
            if (-not (Test-Path $articleTempPath)) {
                New-Item -ItemType Directory -Path $articleTempPath -Force | Out-Null
            }

            $downloadedAttachments = @()

            if ($article.uploads -and $article.uploads.Count -gt 0) {
                foreach ($upload in $article.uploads) {
                    if (-not $upload.id) { continue }
                    try {
                        $downloadedAttachments += @(Get-HuduUploads -Id $upload.id -Download -OutDir $articleTempPath)
                    } catch {
                        Write-Log "  Upload download failed for article '$($article.name)' upload ID $($upload.id): $_" "ERROR"
                    }
                }
            }

            foreach ($attachment in $downloadedAttachments) {
                $localPath = $attachment.localPath
                if (-not $localPath -or -not (Test-Path $localPath)) { continue }

                try {
                    $fileSizeMB = (Get-Item $localPath).Length / 1MB
                    $safeName = Split-Path $localPath -Leaf

                    if ($fileSizeMB -gt $MaxFileSizeMB) {
                        Write-Log "SKIPPED (too large $([math]::Round($fileSizeMB,1))MB > ${MaxFileSizeMB}MB): $safeName" "WARN"
                        $Stats.FilesSkipped++
                        Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                        continue
                    }

                    $attachmentCaption = $attachment.caption
                    if (-not $attachmentCaption -and $attachment.name) { $attachmentCaption = $attachment.name }
                    if (-not $attachmentCaption) { $attachmentCaption = [IO.Path]::GetFileNameWithoutExtension($localPath) }

                    $uploaded = Send-FileToHudu -FilePath $localPath -Caption $attachmentCaption -ArticleId $newId
                    if ($uploaded) { $Stats.FilesUploaded++; Write-Log "  Uploaded '$safeName'" "SUCCESS" }
                    else           { $Stats.FilesFailed++ }
                    Remove-Item $localPath -Force -ErrorAction SilentlyContinue
                } catch {
                    Write-Log "  File transfer failed for '$localPath': $_" "ERROR"
                    $Stats.FilesFailed++
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