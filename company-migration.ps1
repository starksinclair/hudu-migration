# ============================================================================
# Hudu-to-Hudu Migration — Main Orchestrator
#
# Requirements:
#   - PowerShell 7+
#   - HuduAPI module (min 2.4.5): Install-Module HuduAPI -MinimumVersion 2.4.5
#
# Usage:
#   . .\company-migration.ps1
#
# The script will:
#   1. Prompt for source and target credentials
#   2. Company selector: WinForms GUI on Windows, console menu on macOS/Linux
#   3. Let user choose: migrate ONE company (testing) or ALL companies (production)
#   4. Run each migration step in order
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
# DOT-SOURCE STEP FILES
# ============================================================================

$_stepsDir = Join-Path $PSScriptRoot 'steps'

. (Join-Path $_stepsDir 'Helpers.ps1')
. (Join-Path $_stepsDir 'CompanySelector.ps1')
. (Join-Path $_stepsDir 'Migrate-Companies.ps1')
. (Join-Path $_stepsDir 'Migrate-Folders.ps1')
. (Join-Path $_stepsDir 'Migrate-Articles.ps1')
. (Join-Path $_stepsDir 'Migrate-Passwords.ps1')
. (Join-Path $_stepsDir 'Migrate-Relink.ps1')
. (Join-Path $_stepsDir 'Migrate-Procedures.ps1')
. (Join-Path $_stepsDir 'Migrate-Websites.ps1')
. (Join-Path $_stepsDir 'Migrate-IPAM.ps1')
. (Join-Path $_stepsDir 'Migrate-CompanyPhotos.ps1')
. (Join-Path $_stepsDir 'Migrate-Racks.ps1')
. (Join-Path $_stepsDir 'Migrate-Flags.ps1')

# ============================================================================
# CONFIGURATION
# ============================================================================

$SourceHuduUrl = 'https://docs.msp4.com' ?? (Read-Host "Source Hudu URL (e.g. https://source.hudu.com)")
$TargetHuduUrl = 'https://naahia.huducloud.com' ?? (Read-Host "Target Hudu URL (e.g. https://target.hudu.com)")

$SourceHuduUrl = $SourceHuduUrl.TrimEnd('/')
$TargetHuduUrl = $TargetHuduUrl.TrimEnd('/')

if (-not $SourceHuduApiKeySecure) {
    $SourceHuduApiKeySecure = Read-Host "Source Hudu API Key" -AsSecureString
}
if (-not $TargetHuduApiKeySecure) {
    $TargetHuduApiKeySecure = Read-Host "Target Hudu API Key" -AsSecureString
}

if ($SourceHuduApiKeySecure -isnot [System.Security.SecureString] -or
    $TargetHuduApiKeySecure -isnot [System.Security.SecureString]) {
    Write-Host "API keys must be SecureString objects." -ForegroundColor Red
    return
}

[int]$MaxFileSizeMB = if ($MaxFileSizeMB) { $MaxFileSizeMB } else {
    $raw = Read-Host "Max file size to transfer in MB [default: 100]"
    if ($raw -match '^\d+$') { [int]$raw } else { 100 }
}

$MigrationRoot = Join-Path $HOME "HuduMigration"
$TempPath = $TempPath ?? (Join-Path $MigrationRoot "downloads")
$LogDir   = $LogDir   ?? (Join-Path $MigrationRoot "logs")
$LogFile  = Join-Path $LogDir "migration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# ============================================================================
# DIRECTORY SETUP
# ============================================================================

foreach ($dir in @($TempPath, $LogDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# ============================================================================
# MAIN MIGRATION
# ============================================================================

try {
    Set-HapiErrorsDirectory -Path $LogDir | Out-Null

    Write-Log "=== Hudu-to-Hudu Migration Started ==="
    Write-Log "Source : $SourceHuduUrl"
    Write-Log "Target : $TargetHuduUrl"

    # Pre-flight
    Write-Log "--- Pre-flight: verifying connectivity ---"
    Use-SourceHudu
    try {
        $srcInfo = Get-HuduAppInfo
        Write-Log "Source Hudu version: $($srcInfo.version)" "SUCCESS"
    } catch {
        Write-Log "Cannot connect to SOURCE Hudu. Check URL and API key. Error: $_" "ERROR"; return
    }
    Use-TargetHudu
    try {
        $tgtInfo = Get-HuduAppInfo
        Write-Log "Target Hudu version: $($tgtInfo.version)" "SUCCESS"
    } catch {
        Write-Log "Cannot connect to TARGET Hudu. Check URL and API key. Error: $_" "ERROR"; return
    }

    # Company selector
    Write-Log "--- Fetching companies from source ---"
    Use-SourceHudu
    $sourceCompanies = Get-HuduCompanies
    Write-Log "Found $($sourceCompanies.Count) companies" "SUCCESS"

    if ($sourceCompanies.Count -eq 0) {
        Write-Log "No companies found in source instance. Exiting." "ERROR"; return
    }

    Write-Host "`nLaunching company selector..." -ForegroundColor Cyan
    $selection = Show-CompanySelector -Companies $sourceCompanies

    if ($selection.Mode -eq "CANCEL") {
        Write-Log "Migration cancelled by user." "WARN"; return
    }

    $migrationMode      = $selection.Mode
    $selectedCompanyId  = $selection.CompanyId

    if ($migrationMode -eq "SINGLE") {
        $selectedCompany = $sourceCompanies | Where-Object { $_.id -eq $selectedCompanyId }
        Write-Log "=== SINGLE COMPANY MODE: $($selectedCompany.name) (ID: $selectedCompanyId) ===" "SUCCESS"
    } else {
        Write-Log "=== FULL MIGRATION MODE: ALL COMPANIES ===" "SUCCESS"
    }

    # Shared state — use [ordered] for stable summary order. Step functions must take
    # [System.Collections.IDictionary], not [hashtable]; binding [ordered] to [hashtable] copies it.
    $Stats = [ordered]@{
        CompaniesCreated   = 0; CompaniesSkipped  = 0; CompaniesFailed   = 0
        FoldersCreated     = 0; FoldersFailed     = 0
        ArticlesCreated    = 0; ArticlesFailed    = 0
        FilesUploaded      = 0; FilesSkipped      = 0; FilesFailed       = 0
        PasswordsCreated   = 0; PasswordsSkipped  = 0; PasswordsFailed   = 0
        ProceduresCreated  = 0; ProceduresSkipped = 0; ProceduresFailed  = 0
        TasksCreated       = 0; TasksFailed       = 0
        WebsitesCreated    = 0; WebsitesSkipped   = 0; WebsitesFailed    = 0
        NetworksCreated    = 0; NetworksSkipped   = 0; NetworksFailed    = 0
        IPsCreated         = 0; IPsFailed         = 0
        PhotoFoldersCreated = 0; PhotoFoldersSkipped = 0; PhotoFoldersFailed = 0
        PhotosUploaded     = 0; PhotosFailed      = 0
        RacksCreated       = 0; RacksSkipped      = 0; RacksFailed       = 0
        RackItemsCreated   = 0; RackItemsSkipped  = 0; RackItemsFailed   = 0
        FlagTypesCreated   = 0; FlagTypesSkipped  = 0; FlagTypesFailed   = 0
        FlagsCreated       = 0; FlagsSkipped      = 0; FlagsDuplicatesSkipped = 0; FlagsFailed = 0
    }
    $SkippedFileManifest = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --------------------------------------------------------------------------
    # Run each migration step
    # --------------------------------------------------------------------------

    $CompanyMap = Invoke-CompanyMigration `
        -SourceCompanies    $sourceCompanies `
        -Stats              $Stats `
        -MigrationMode      $migrationMode `
        -SelectedCompanyId  $selectedCompanyId

    $FolderMap = Invoke-FolderMigration `
        -CompanyMap         $CompanyMap `
        -Stats              $Stats `
        -MigrationMode      $migrationMode `
        -SelectedCompanyId  $selectedCompanyId

    $ArticleMap = Invoke-ArticleMigration `
        -CompanyMap          $CompanyMap `
        -FolderMap           $FolderMap `
        -Stats               $Stats `
        -SkippedFileManifest $SkippedFileManifest `
        -MigrationMode       $migrationMode `
        -SelectedCompanyId   $selectedCompanyId `
        -TempPath            $TempPath `
        -MaxFileSizeMB       $MaxFileSizeMB

    Invoke-PasswordMigration `
        -CompanyMap        $CompanyMap `
        -Stats             $Stats `
        -MigrationMode     $migrationMode `
        -SelectedCompanyId $selectedCompanyId

    if ($SkippedFileManifest.Count -gt 0) {
        $manifestPath = Join-Path $LogDir "skipped_files.csv"
        $SkippedFileManifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
        Write-Log "Skipped files manifest: $manifestPath" "WARN"
    }

    $relinkResult = Invoke-RelinkArticles -ArticleMap $ArticleMap

    Invoke-ProcedureMigration `
        -CompanyMap        $CompanyMap `
        -Stats             $Stats `
        -MigrationMode     $migrationMode `
        -SelectedCompanyId $selectedCompanyId

    Invoke-WebsiteMigration `
        -CompanyMap        $CompanyMap `
        -Stats             $Stats `
        -MigrationMode     $migrationMode `
        -SelectedCompanyId $selectedCompanyId

    $NetworkMap = Invoke-IPAMMigration `
        -CompanyMap        $CompanyMap `
        -Stats             $Stats `
        -MigrationMode     $migrationMode `
        -SelectedCompanyId $selectedCompanyId

    Invoke-CompanyPhotoMigration `
        -SourceCompanies   $sourceCompanies `
        -CompanyMap        $CompanyMap `
        -Stats             $Stats `
        -MigrationMode     $migrationMode `
        -SelectedCompanyId $selectedCompanyId `
        -TempPath          $TempPath `
        -MaxFileSizeMB     $MaxFileSizeMB

    $RackMap = Invoke-RackMigration `
        -CompanyMap        $CompanyMap `
        -Stats             $Stats `
        -MigrationMode     $migrationMode `
        -SelectedCompanyId $selectedCompanyId

    Invoke-FlagMigration `
        -CompanyMap        $CompanyMap `
        -ArticleMap       $ArticleMap `
        -RackMap           $RackMap `
        -Stats             $Stats `
        -MigrationMode     $migrationMode `
        -SelectedCompanyId $selectedCompanyId

    # --------------------------------------------------------------------------
    # Summary
    # --------------------------------------------------------------------------

    Write-Log "=========================================="
    Write-Log "=           MIGRATION COMPLETE           ="
    Write-Log "=========================================="
    Write-Log "Mode       : $migrationMode"
    Write-Log "Companies  - Created: $($Stats.CompaniesCreated) | Matched: $($Stats.CompaniesSkipped) | Failed: $($Stats.CompaniesFailed)"
    Write-Log "Folders    - Created: $($Stats.FoldersCreated) | Failed: $($Stats.FoldersFailed)"
    Write-Log "Articles   - Created: $($Stats.ArticlesCreated) | Failed: $($Stats.ArticlesFailed)"
    Write-Log "Passwords  - Created: $($Stats.PasswordsCreated) | Failed: $($Stats.PasswordsFailed)"
    Write-Log "Files      - Uploaded: $($Stats.FilesUploaded) | Skipped: $($Stats.FilesSkipped) | Failed: $($Stats.FilesFailed)"
    Write-Log "Relinking  - Updated: $($relinkResult.Updated) | Failed: $($relinkResult.Failed)"
    Write-Log "Procedures - Created: $($Stats.ProceduresCreated) | Skipped: $($Stats.ProceduresSkipped) | Failed: $($Stats.ProceduresFailed)"
    Write-Log "Tasks      - Created: $($Stats.TasksCreated) | Failed: $($Stats.TasksFailed)"
    Write-Log "Websites   - Created: $($Stats.WebsitesCreated) | Skipped: $($Stats.WebsitesSkipped) | Failed: $($Stats.WebsitesFailed)"
    Write-Log "Networks   - Created: $($Stats.NetworksCreated) | Skipped: $($Stats.NetworksSkipped) | Failed: $($Stats.NetworksFailed)"
    Write-Log "IPs        - Created: $($Stats.IPsCreated) | Failed: $($Stats.IPsFailed)"
    Write-Log "Photo flds - Created: $($Stats.PhotoFoldersCreated) | Skipped: $($Stats.PhotoFoldersSkipped) | Failed: $($Stats.PhotoFoldersFailed)"
    Write-Log "Photos     - Uploaded: $($Stats.PhotosUploaded) | Failed: $($Stats.PhotosFailed)"
    Write-Log "Racks      - Created: $($Stats.RacksCreated) | Skipped: $($Stats.RacksSkipped) | Failed: $($Stats.RacksFailed)"
    Write-Log "Rack items - Created: $($Stats.RackItemsCreated) | Skipped: $($Stats.RackItemsSkipped) | Failed: $($Stats.RackItemsFailed)"
    Write-Log "Flag types - Created: $($Stats.FlagTypesCreated) | Matched: $($Stats.FlagTypesSkipped) | Failed: $($Stats.FlagTypesFailed)"
    Write-Log "Flags      - Created: $($Stats.FlagsCreated) | Skipped: $($Stats.FlagsSkipped) | Duplicates: $($Stats.FlagsDuplicatesSkipped) | Failed: $($Stats.FlagsFailed)"
    Write-Log "Log        : $LogFile"
    Write-Log "Data       : $LogDir"

    Write-Host "`nMappings in session: `$CompanyMap, `$FolderMap, `$ArticleMap, `$NetworkMap, `$RackMap" -ForegroundColor Magenta

} finally {
    if ($SourceHuduApiKeySecure -is [System.Security.SecureString]) { $SourceHuduApiKeySecure.Dispose() }
    if ($TargetHuduApiKeySecure -is [System.Security.SecureString]) { $TargetHuduApiKeySecure.Dispose() }
    Remove-Variable -Name SourceHuduApiKeySecure, TargetHuduApiKeySecure -Scope Script -ErrorAction SilentlyContinue
    [System.GC]::Collect()
    Write-Host "API keys cleared from memory." -ForegroundColor DarkGray
}
