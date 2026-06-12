# ============================================================================
# Hudu-to-Hudu Migration — Main Orchestrator
#
# Requirements:
#   - PowerShell 7+
#   - HuduAPI module (min 2.4.5): Install-Module HuduAPI -MinimumVersion 2.4.5
#
# Usage:
#   . .\company-migration.ps1
#   . .\company-migration.ps1 -SkipAssetMigration
#   . .\company-migration.ps1 -MigrationScope Global
#   . .\company-migration.ps1 -MigrationScope Company
#
# Migration scope (run once globally, then per company):
#   All     — full migration (default)
#   Global  — tenant-wide: asset layouts, central KB, flag types (+ global passwords)
#   Company — one or all companies: KB, passwords, assets, racks, etc. (no layouts / no central KB)
#
# Skip asset layouts (Global/All) and assets/relations (Company/All):
#   . .\company-migration.ps1 -SkipAssetMigration
#
# The script will:
#   1. Prompt for source and target credentials
#   2. Ask whether to skip asset layouts, assets, and relations (unless -SkipAssetMigration)
#   3. Company selector: WinForms GUI on Windows, console menu on macOS/Linux
#   4. Let user choose: migrate ONE company (testing) or ALL companies (production)
#   5. Run each migration step in order
# ============================================================================

#Requires -Version 7.0

param(
    [switch]$SkipAssetMigration,
    [ValidateSet('All', 'Global', 'Company')]
    [string]$MigrationScope
)

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
. (Join-Path $_stepsDir 'Migrate-AssetLayouts.ps1')
. (Join-Path $_stepsDir 'Migrate-Folders.ps1')
. (Join-Path $_stepsDir 'Migrate-Articles.ps1')
. (Join-Path $_stepsDir 'Migrate-Passwords.ps1')
. (Join-Path $_stepsDir 'Migrate-Relink.ps1')
. (Join-Path $_stepsDir 'Migrate-Procedures.ps1')
. (Join-Path $_stepsDir 'Migrate-Websites.ps1')
. (Join-Path $_stepsDir 'Migrate-IPAM.ps1')
. (Join-Path $_stepsDir 'Migrate-CompanyPhotos.ps1')
. (Join-Path $_stepsDir 'Migrate-Assets.ps1')
. (Join-Path $_stepsDir 'Migrate-Racks.ps1')
. (Join-Path $_stepsDir 'Migrate-Relations.ps1')
. (Join-Path $_stepsDir 'Migrate-Flags.ps1')

# ============================================================================
# CONFIGURATION
# ============================================================================

do {
    $instanceInput = Read-Host "How many Hudu instances? Enter 1 (same instance — test mode) or 2 (source and target) [2]"
    if ([string]::IsNullOrWhiteSpace($instanceInput)) { $instanceInput = '2' }
} while ($instanceInput -notin @('1', '2'))

$script:MigrationInstanceCount = [int]$instanceInput
$script:MigrationTestNameSuffix = if ($MigrationTestNameSuffix) { $MigrationTestNameSuffix } else { ' [MIG-TEST]' }

if ($script:MigrationInstanceCount -eq 1) {
    Write-Host "`nSingle-instance test mode: source and target are the same tenant." -ForegroundColor Yellow
    Write-Host "New records are created with name suffix '$($script:MigrationTestNameSuffix)' to avoid duplicate-name errors.`n" -ForegroundColor Yellow

    if (-not $SourceHuduUrl) {
        $SourceHuduUrl = Read-Host "Hudu URL (e.g. https://your.hudu.com)"
    }
    $SourceHuduUrl = $SourceHuduUrl.TrimEnd('/')
    $TargetHuduUrl   = $SourceHuduUrl

    if (-not $SourceHuduApiKeySecure) {
        $SourceHuduApiKeySecure = Read-Host "Hudu API Key" -AsSecureString
    }
    $TargetHuduApiKeySecure = $SourceHuduApiKeySecure
} else {
    $SourceHuduUrl = $SourceHuduUrl ?? (Read-Host "Source Hudu URL (e.g. https://source.hudu.com)")
    $TargetHuduUrl = $TargetHuduUrl ?? (Read-Host "Target Hudu URL (e.g. https://target.hudu.com)")

    $SourceHuduUrl = $SourceHuduUrl.TrimEnd('/')
    $TargetHuduUrl = $TargetHuduUrl.TrimEnd('/')

    if (-not $SourceHuduApiKeySecure) {
        $SourceHuduApiKeySecure = Read-Host "Source Hudu API Key" -AsSecureString
    }
    if (-not $TargetHuduApiKeySecure) {
        $TargetHuduApiKeySecure = Read-Host "Target Hudu API Key" -AsSecureString
    }
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

if (-not $PSBoundParameters.ContainsKey('MigrationScope')) {
    do {
        $scopeInput = Read-Host "Migration scope? [A]ll (default) | [G]lobal tenant only | [C]ompany only"
        if ([string]::IsNullOrWhiteSpace($scopeInput)) { $scopeInput = 'a' }
        $scopeInput = $scopeInput.Trim().ToLowerInvariant()
    } while ($scopeInput -notmatch '^(a|all|g|global|c|company)$')
    $MigrationScope = switch -Regex ($scopeInput) {
        '^(g|global)$'   { 'Global' }
        '^(c|company)$'  { 'Company' }
        default          { 'All' }
    }
}
if (-not $MigrationScope) { $MigrationScope = 'All' }

$runGlobalSteps  = Test-MigrationScopeIncludesGlobal -MigrationScope $MigrationScope
$runCompanySteps = Test-MigrationScopeIncludesCompany -MigrationScope $MigrationScope
$runLayouts      = (-not $SkipAssetMigration) -and $runGlobalSteps
$runAssets       = (-not $SkipAssetMigration) -and $runCompanySteps

if (-not $PSBoundParameters.ContainsKey('SkipAssetMigration') -and ($runLayouts -or $runAssets)) {
    do {
        $skipInput = Read-Host "Skip asset layouts$(if ($runAssets) { ', assets, and relations' })? (y/N)"
        if ([string]::IsNullOrWhiteSpace($skipInput)) { $skipInput = 'n' }
    } while ($skipInput -notmatch '^(?i)(y|yes|n|no)$')
    $SkipAssetMigration = $skipInput -match '^(?i)(y|yes)$'
    if ($SkipAssetMigration) {
        $runLayouts = $false
        $runAssets  = $false
        Write-Host "Asset layouts$(if ($runCompanySteps) { ', assets, and relations' }) will be skipped." -ForegroundColor Yellow
    }
} elseif ($SkipAssetMigration) {
    $runLayouts = $false
    $runAssets  = $false
}

$scopeDescription = switch ($MigrationScope) {
    'Global'  { 'GLOBAL — tenant-wide resources (layouts, central KB, flag types)' }
    'Company' { 'COMPANY — per-company data (no layouts, no central KB import)' }
    default   { 'ALL — global + company resources in one run' }
}
Write-Host "`n$scopeDescription`n" -ForegroundColor Cyan

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
    Write-Log "Instances: $script:MigrationInstanceCount $(if ($script:MigrationInstanceCount -eq 1) { "(same-tenant test; suffix '$script:MigrationTestNameSuffix')" } else { '(source → target)' })"
    Write-Log "Scope  : $MigrationScope"
    Write-Log "Source : $SourceHuduUrl"
    Write-Log "Target : $TargetHuduUrl"
    if ($SkipAssetMigration) {
        Write-Log "SkipAssetMigration: asset layouts$(if ($runCompanySteps) { ', assets, and relations' }) will NOT be created." "WARN"
    }

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

    if ($MigrationScope -eq 'Global') {
        $migrationMode     = 'ALL'
        $selectedCompanyId = 0
        Write-Log "=== GLOBAL SCOPE — company selector skipped (tenant-wide resources only) ===" "SUCCESS"
    } else {
        Write-Host "`nLaunching company selector..." -ForegroundColor Cyan
        $selection = Show-CompanySelector -Companies $sourceCompanies

        if ($selection.Mode -eq "CANCEL") {
            Write-Log "Migration cancelled by user." "WARN"; return
        }

        $migrationMode     = $selection.Mode
        $selectedCompanyId = $selection.CompanyId

        if ($migrationMode -eq "SINGLE") {
            $selectedCompany = $sourceCompanies | Where-Object { $_.id -eq $selectedCompanyId }
            Write-Log "=== SINGLE COMPANY MODE: $($selectedCompany.name) (ID: $selectedCompanyId) ===" "SUCCESS"
        } else {
            Write-Log "=== FULL MIGRATION MODE: ALL COMPANIES ===" "SUCCESS"
        }
    }

    # Shared state — use [ordered] for stable summary order. Step functions must take
    # [System.Collections.IDictionary], not [hashtable]; binding [ordered] to [hashtable] copies it.
    $Stats = [ordered]@{
        CompaniesCreated   = 0; CompaniesSkipped  = 0; CompaniesFailed   = 0
        AssetLayoutsCreated = 0; AssetLayoutsSkipped = 0; AssetLayoutsFailed = 0
        FoldersCreated     = 0; FoldersFailed     = 0
        ArticlesCreated    = 0; ArticlesSkipped   = 0; ArticlesFailed    = 0
        FilesUploaded      = 0; FilesSkipped      = 0; FilesFailed       = 0
        PasswordsCreated   = 0; PasswordsSkipped  = 0; PasswordsFailed   = 0
        ProceduresCreated  = 0; ProceduresSkipped = 0; ProceduresFailed  = 0
        TasksCreated       = 0; TasksFailed       = 0
        WebsitesCreated    = 0; WebsitesSkipped   = 0; WebsitesFailed    = 0
        NetworksCreated    = 0; NetworksSkipped   = 0; NetworksFailed    = 0
        VlanZonesCreated   = 0; VlanZonesSkipped  = 0; VlanZonesFailed   = 0
        VlansCreated       = 0; VlansSkipped      = 0; VlansFailed       = 0
        IPsCreated         = 0; IPsSkipped        = 0; IPsFailed         = 0
        PhotoFoldersCreated = 0; PhotoFoldersSkipped = 0; PhotoFoldersFailed = 0
        PhotosUploaded     = 0; PhotosFailed      = 0
        RacksCreated       = 0; RacksSkipped      = 0; RacksFailed       = 0
        RackItemsCreated   = 0; RackItemsSkipped  = 0; RackItemsFailed   = 0
        AssetsCreated      = 0; AssetsSkipped     = 0; AssetsFailed      = 0
        RelationsCreated   = 0; RelationsSkipped  = 0; RelationsFailed   = 0
        FlagTypesCreated   = 0; FlagTypesSkipped  = 0; FlagTypesFailed   = 0
        FlagsCreated       = 0; FlagsSkipped      = 0; FlagsDuplicatesSkipped = 0; FlagsFailed = 0
    }
    $SkippedFileManifest = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --------------------------------------------------------------------------
    # Run each migration step
    # --------------------------------------------------------------------------

    $CompanyMap = @{}
    if ($runCompanySteps) {
        $CompanyMap = Invoke-CompanyMigration `
            -SourceCompanies    $sourceCompanies `
            -Stats              $Stats `
            -MigrationMode      $migrationMode `
            -SelectedCompanyId  $selectedCompanyId
    } else {
        Write-Log "========== SKIPPED: COMPANIES (Global scope) ==========" "WARN"
    }

    $LayoutMap = @{}
    $layoutMigration = @{
        LayoutMap      = @{}
        LayoutFieldMap = @{}
        ListMap        = @{}
    }
    if (-not $runLayouts) {
        Write-Log "========== SKIPPED: ASSET LAYOUTS ==========" "WARN"
    } else {
        $layoutMigration = Invoke-AssetLayoutMigration `
            -Stats              $Stats `
            -MigrationMode      $migrationMode `
            -SelectedCompanyId  $selectedCompanyId
        $LayoutMap = $layoutMigration.LayoutMap
    }

    $FolderMap = @{}
    if ($runGlobalSteps -or $runCompanySteps) {
        $FolderMap = Invoke-FolderMigration `
            -CompanyMap         $CompanyMap `
            -Stats              $Stats `
            -MigrationMode      $migrationMode `
            -SelectedCompanyId  $selectedCompanyId `
            -MigrationScope     $MigrationScope
    }

    $ArticleMap = @{}
    if ($runGlobalSteps -or $runCompanySteps) {
        $ArticleMap = Invoke-ArticleMigration `
            -CompanyMap          $CompanyMap `
            -FolderMap           $FolderMap `
            -Stats               $Stats `
            -SkippedFileManifest $SkippedFileManifest `
            -MigrationMode       $migrationMode `
            -SelectedCompanyId   $selectedCompanyId `
            -TempPath            $TempPath `
            -MaxFileSizeMB       $MaxFileSizeMB `
            -MigrationScope      $MigrationScope
    }

    if ($runGlobalSteps -or $runCompanySteps) {
        Invoke-PasswordMigration `
            -CompanyMap        $CompanyMap `
            -Stats             $Stats `
            -MigrationMode     $migrationMode `
            -SelectedCompanyId $selectedCompanyId `
            -MigrationScope    $MigrationScope
    } else {
        Write-Log "========== SKIPPED: PASSWORDS ==========" "WARN"
    }

    if ($SkippedFileManifest.Count -gt 0) {
        $manifestPath = Join-Path $LogDir "skipped_files.csv"
        $SkippedFileManifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
        Write-Log "Skipped files manifest: $manifestPath" "WARN"
    }

    $relinkResult = @{ Updated = 0; Failed = 0 }
    if ($ArticleMap.Count -gt 0) {
        $relinkResult = Invoke-RelinkArticles -ArticleMap $ArticleMap
    } else {
        Write-Log "========== SKIPPED: RELINKING (no articles in ArticleMap) ==========" "WARN"
    }

    if ($runCompanySteps) {
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
    } else {
        Write-Log "========== SKIPPED: PROCEDURES, WEBSITES, IPAM, PHOTOS (Global scope) ==========" "WARN"
        $NetworkMap = @{}
    }

    $AssetMap = @{}
    if (-not $runAssets) {
        Write-Log "========== SKIPPED: ASSETS ==========" "WARN"
    } else {
        $AssetMap = Invoke-AssetMigration `
            -CompanyMap        $CompanyMap `
            -LayoutMap         $LayoutMap `
            -LayoutFieldMap    $layoutMigration.LayoutFieldMap `
            -Stats             $Stats `
            -MigrationMode     $migrationMode `
            -SelectedCompanyId $selectedCompanyId
    }

    $RackMap = @{}
    if ($runCompanySteps) {
        $RackMap = Invoke-RackMigration `
            -CompanyMap        $CompanyMap `
            -AssetMap          $AssetMap `
            -Stats             $Stats `
            -MigrationMode     $migrationMode `
            -SelectedCompanyId $selectedCompanyId
    } else {
        Write-Log "========== SKIPPED: RACKS (Global scope) ==========" "WARN"
    }

    if (-not $runAssets) {
        Write-Log "========== SKIPPED: RELATIONS ==========" "WARN"
    } elseif ($runCompanySteps) {
        Invoke-RelationMigration `
            -CompanyMap        $CompanyMap `
            -ArticleMap        $ArticleMap `
            -AssetMap          $AssetMap `
            -RackMap           $RackMap `
            -NetworkMap        $NetworkMap `
            -Stats             $Stats `
            -MigrationMode     $migrationMode `
            -SelectedCompanyId $selectedCompanyId
    } else {
        Write-Log "========== SKIPPED: RELATIONS (Global scope — no company relations) ==========" "WARN"
    }

    if ($runGlobalSteps -or $runCompanySteps) {
        Invoke-FlagMigration `
            -CompanyMap        $CompanyMap `
            -ArticleMap        $ArticleMap `
            -FolderMap         $FolderMap `
            -RackMap           $RackMap `
            -AssetMap          $AssetMap `
            -Stats             $Stats `
            -MigrationMode     $migrationMode `
            -SelectedCompanyId $selectedCompanyId `
            -MigrationScope    $MigrationScope
    }

    # --------------------------------------------------------------------------
    # Summary
    # --------------------------------------------------------------------------

    Write-Log "=========================================="
    Write-Log "=           MIGRATION COMPLETE           ="
    Write-Log "=========================================="
    Write-Log "Scope      : $MigrationScope"
    Write-Log "Mode       : $migrationMode"
    if ($runCompanySteps) {
        Write-Log "Companies  - Created: $($Stats.CompaniesCreated) | Matched: $($Stats.CompaniesSkipped) | Failed: $($Stats.CompaniesFailed)"
    } else {
        Write-Log "Companies  - SKIPPED (Global scope)"
    }
    if (-not $runLayouts) {
        Write-Log "Layouts    - SKIPPED"
    } else {
        Write-Log "Layouts    - Created: $($Stats.AssetLayoutsCreated) | Skipped: $($Stats.AssetLayoutsSkipped) | Failed: $($Stats.AssetLayoutsFailed)"
    }
    Write-Log "Folders    - Created: $($Stats.FoldersCreated) | Failed: $($Stats.FoldersFailed)"
    Write-Log "Articles   - Created: $($Stats.ArticlesCreated) | Matched: $($Stats.ArticlesSkipped) | Failed: $($Stats.ArticlesFailed)"
    Write-Log "Passwords  - Created: $($Stats.PasswordsCreated) | Failed: $($Stats.PasswordsFailed)"
    Write-Log "Files      - Uploaded: $($Stats.FilesUploaded) | Skipped: $($Stats.FilesSkipped) | Failed: $($Stats.FilesFailed)"
    Write-Log "Relinking  - Updated: $($relinkResult.Updated) | Failed: $($relinkResult.Failed)"
    Write-Log "Procedures - Created: $($Stats.ProceduresCreated) | Skipped: $($Stats.ProceduresSkipped) | Failed: $($Stats.ProceduresFailed)"
    Write-Log "Tasks      - Created: $($Stats.TasksCreated) | Failed: $($Stats.TasksFailed)"
    Write-Log "Websites   - Created: $($Stats.WebsitesCreated) | Skipped: $($Stats.WebsitesSkipped) | Failed: $($Stats.WebsitesFailed)"
    Write-Log "Networks   - Created: $($Stats.NetworksCreated) | Skipped: $($Stats.NetworksSkipped) | Failed: $($Stats.NetworksFailed)"
    Write-Log "Vlan zones - Created: $($Stats.VlanZonesCreated) | Skipped: $($Stats.VlanZonesSkipped) | Failed: $($Stats.VlanZonesFailed)"
    Write-Log "Vlans      - Created: $($Stats.VlansCreated) | Skipped: $($Stats.VlansSkipped) | Failed: $($Stats.VlansFailed)"
    Write-Log "IPs        - Created: $($Stats.IPsCreated) | Skipped: $($Stats.IPsSkipped) | Failed: $($Stats.IPsFailed)"
    Write-Log "Photo flds - Created: $($Stats.PhotoFoldersCreated) | Skipped: $($Stats.PhotoFoldersSkipped) | Failed: $($Stats.PhotoFoldersFailed)"
    Write-Log "Photos     - Uploaded: $($Stats.PhotosUploaded) | Failed: $($Stats.PhotosFailed)"
    Write-Log "Racks      - Created: $($Stats.RacksCreated) | Skipped: $($Stats.RacksSkipped) | Failed: $($Stats.RacksFailed)"
    Write-Log "Rack items - Created: $($Stats.RackItemsCreated) | Skipped: $($Stats.RackItemsSkipped) | Failed: $($Stats.RackItemsFailed)"
    if ($runAssets) {
        Write-Log "Assets     - Created: $($Stats.AssetsCreated) | Skipped: $($Stats.AssetsSkipped) | Failed: $($Stats.AssetsFailed)"
        Write-Log "Relations  - Created: $($Stats.RelationsCreated) | Skipped: $($Stats.RelationsSkipped) | Failed: $($Stats.RelationsFailed)"
    } else {
        Write-Log "Assets     - SKIPPED"
        Write-Log "Relations  - SKIPPED"
    }
    Write-Log "Flag types - Created: $($Stats.FlagTypesCreated) | Matched: $($Stats.FlagTypesSkipped) | Failed: $($Stats.FlagTypesFailed)"
    Write-Log "Flags      - Created: $($Stats.FlagsCreated) | Skipped: $($Stats.FlagsSkipped) | Duplicates: $($Stats.FlagsDuplicatesSkipped) | Failed: $($Stats.FlagsFailed)"
    Write-Log "Log        : $LogFile"
    Write-Log "Data       : $LogDir"

    Write-Host "`nMappings in session: `$CompanyMap, `$LayoutMap, `$FolderMap, `$ArticleMap, `$AssetMap, `$NetworkMap, `$RackMap" -ForegroundColor Magenta

} finally {
    if ($SourceHuduApiKeySecure -is [System.Security.SecureString]) { $SourceHuduApiKeySecure.Dispose() }
    if ($TargetHuduApiKeySecure -is [System.Security.SecureString]) { $TargetHuduApiKeySecure.Dispose() }
    Remove-Variable -Name SourceHuduApiKeySecure, TargetHuduApiKeySecure -Scope Script -ErrorAction SilentlyContinue
    [System.GC]::Collect()
    Write-Host "API keys cleared from memory." -ForegroundColor DarkGray
}
