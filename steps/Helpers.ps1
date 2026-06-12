# ============================================================================
# Helpers.ps1 — shared utility functions
# Dot-sourced by company-migration.ps1 before any step is called.
# Functions here rely on these variables being set in the caller's scope:
#   $LogFile, $LogDir, $SourceHuduUrl, $TargetHuduUrl,
#   $SourceHuduApiKeySecure, $TargetHuduApiKeySecure
#   $script:MigrationInstanceCount (1 = same instance test, 2 = normal)
#   $script:MigrationTestNameSuffix (appended to names when instance count is 1)
# ============================================================================

# When MigrationInstanceCount is 1, source and target are the same Hudu tenant.
# New records use a suffix on the name so creates do not collide with existing rows.
function Get-MigrationAssetDisplayName {
    param([object]$Asset)

    if (-not $Asset -or -not $Asset.PSObject.Properties['name'] -or $null -eq $Asset.name) {
        return $null
    }
    if ($Asset.name -is [string]) {
        $n = $Asset.name.Trim()
        if ($n -and $n -notmatch '^System\.Collections\.') { return $n }
        return $null
    }
    return $null
}

function Get-MigrationName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }
    if ($script:MigrationInstanceCount -ne 1) { return $Name }

    $suffix = $script:MigrationTestNameSuffix
    if ([string]::IsNullOrWhiteSpace($suffix)) { $suffix = ' [MIG-TEST]' }
    if ($Name.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) { return $Name }
    return "$Name$suffix"
}

# company_id null/0 = Global KB, tenant-wide folders, etc.
function Test-HuduRecordIsGlobal {
    param(
        [object]$Record,
        [string]$PropertyName = 'company_id'
    )
    if (-not $Record) { return $true }
    if (-not $Record.PSObject.Properties[$PropertyName]) { return $true }
    $cid = $Record.$PropertyName
    return (-not $cid -or [int]$cid -eq 0)
}

function Test-MigrationScopeIncludesGlobal {
    param([string]$MigrationScope)
    return $MigrationScope -in @('All', 'Global')
}

function Test-MigrationScopeIncludesCompany {
    param([string]$MigrationScope)
    return $MigrationScope -in @('All', 'Company')
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"
    if ($script:LogFile -and (Test-Path (Split-Path $script:LogFile -Parent))) {
        Add-Content -Path $script:LogFile -Value $line
    }
    $color = switch ($Level) {
        "ERROR"   { "Red"    }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green"  }
        default   { "Cyan"   }
    }
    Write-Host $line -ForegroundColor $color
}

function Save-Phase {
    param([string]$Name, [object]$Data)
    $path = Join-Path $script:LogDir "$Name.json"
    $Data | ConvertTo-Json -Depth 20 | Set-Content -Path $path
    Write-Log "Phase '$Name' saved to $path"
}

function Read-Phase {
    param([string]$Name)
    $path = Join-Path $script:LogDir "$Name.json"
    if (Test-Path $path) {
        Write-Log "Resuming phase '$Name' from $path" "WARN"
        return Get-Content $path -Raw | ConvertFrom-Json
    }
    return $null
}

function Get-PlainText {
    param([System.Security.SecureString]$Secure)
    return [System.Net.NetworkCredential]::new('', $Secure).Password
}

function Use-SourceHudu {
    $plain = Get-PlainText $script:SourceHuduApiKeySecure
    Remove-HuduAPIKey  -ErrorAction SilentlyContinue
    Remove-HuduBaseURL -ErrorAction SilentlyContinue
    New-HuduAPIKey  $plain
    New-HuduBaseUrl $script:SourceHuduUrl
    $plain = $null
}

function Use-TargetHudu {
    $plain = Get-PlainText $script:TargetHuduApiKeySecure
    Remove-HuduAPIKey  -ErrorAction SilentlyContinue
    Remove-HuduBaseURL -ErrorAction SilentlyContinue
    New-HuduAPIKey  $plain
    New-HuduBaseUrl $script:TargetHuduUrl
    $plain = $null
}

function Get-HuduObjectList {
    param(
        [object]$Response,
        [string[]]$CollectionNames
    )
    if ($null -eq $Response) { return @() }

    $flattened = [System.Collections.Generic.List[object]]::new()
    $chunks = if ($Response -is [System.Array]) { @($Response) } else { @($Response) }

    foreach ($chunk in $chunks) {
        $added = $false
        foreach ($name in $CollectionNames) {
            if ($chunk.PSObject.Properties[$name] -and $chunk.$name) {
                foreach ($item in @($chunk.$name)) { $null = $flattened.Add($item) }
                $added = $true
                break
            }
        }
        if (-not $added -and $chunk.id) { $null = $flattened.Add($chunk) }
    }
    if ($flattened.Count -gt 0) { return @($flattened) }
    if ($Response -is [System.Array]) { return @($Response) }
    return @($Response)
}

function ConvertTo-HuduApiStringFlag {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text.ToLowerInvariant()
}

# Description fields in Hudu are plain text; strip HTML when source used rich-text markup.
function ConvertTo-HuduPlainDescription {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $plain = [string]$Text
    $plain = $plain -replace '<(br|p|div|li|tr|h[1-6])\s*/?\s*>', "`n"
    $plain = $plain -replace '</(p|div|li|tr|h[1-6])>', "`n"
    $plain = $plain -replace '<[^>]+>', ''
    $plain = $plain -replace '&nbsp;', ' '
    $plain = $plain -replace '&amp;', '&'
    $plain = $plain -replace '&lt;', '<'
    $plain = $plain -replace '&gt;', '>'
    $plain = $plain -replace '&quot;', '"'
    $plain = $plain -replace '&#39;', "'"
    $plain = ($plain -split "`n" | ForEach-Object { $_.Trim() }) -join "`n"
    $plain = $plain.Trim()
    if ([string]::IsNullOrWhiteSpace($plain)) { return $null }
    return $plain
}

# POST/PUT JSON to Hudu without HuduAPI's retry console spam (Invoke-HuduRequest is module-private).
function Invoke-HuduJsonApi {
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method = 'GET',
        [Parameter(Mandatory)]
        [string]$Resource,
        [hashtable]$Body = $null
    )

    $apiKeySecure = Get-HuduApiKey
    $baseUrl      = Get-HuduBaseURL
    if (-not $apiKeySecure -or -not $baseUrl) {
        throw 'Hudu API key or base URL is not configured. Call Use-SourceHudu or Use-TargetHudu first.'
    }
    # Get-HuduApiKey returns SecureString — same unwrap as Invoke-HuduRequest in HuduAPI.
    $apiKeyPlain = (New-Object PSCredential 'user', $apiKeySecure).GetNetworkCredential().Password

    $uri = '{0}{1}' -f ($baseUrl.TrimEnd('/')), $Resource
    $headers = @{ 'x-api-key' = $apiKeyPlain }
    $params = @{
        Method      = $Method
        Uri         = $uri
        Headers     = $headers
        ContentType = 'application/json; charset=utf-8'
    }
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 15 -Compress:$false)
    }

    try {
        return Invoke-RestMethod @params
    } catch {
        $summary = Get-HuduApiErrorSummary -ErrorRecord $_
        throw "Hudu API $Method $Resource failed: $summary"
    }
}

function Get-HuduApiErrorText {
    param([object]$ErrorRecord)

    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            return [string]$ErrorRecord.ErrorDetails.Message
        }
        if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
            return [string]$ErrorRecord.Exception.Message
        }
    }
    return [string]$ErrorRecord
}

function Test-HuduApiHtmlErrorBody {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $head = $Text.Trim()
    if ($head.Length -gt 800) { $head = $head.Substring(0, 800) }
    return $head -match '(?is)<!DOCTYPE\s+html|<html\b|<body\b|</html>|<svg\b'
}

function Get-HuduApiHttpStatusCode {
    param([object]$ErrorRecord)

    if ($ErrorRecord -isnot [System.Management.Automation.ErrorRecord]) { return $null }
    try {
        if ($ErrorRecord.Exception.Response) {
            return [int]$ErrorRecord.Exception.Response.StatusCode
        }
    } catch { }
    return $null
}

function Get-HuduApiErrorSummary {
    param([object]$ErrorRecord)

    $statusCode = Get-HuduApiHttpStatusCode -ErrorRecord $ErrorRecord
    $text       = Get-HuduApiErrorText -ErrorRecord $ErrorRecord

    if (Test-HuduCompanyScopedPermissionError $text) {
        return 'permissions scoped to company (API key cannot access this resource)'
    }

    if ($text -match '"error"\s*:\s*"([^"]+)"') {
        return [string]$Matches[1]
    }

    if ($statusCode -eq 404 -or $text -match '(?i)\b404\b|not found') {
        return 'HTTP 404 Not Found'
    }

    if (Test-HuduApiHtmlErrorBody $text) {
        if ($statusCode) {
            return "HTTP $statusCode (HTML error page returned instead of JSON)"
        }
        return 'HTTP error (HTML error page returned instead of JSON)'
    }

    $oneLine = ($text -replace '\s+', ' ').Trim()
    if ($oneLine.Length -gt 240) {
        $oneLine = $oneLine.Substring(0, 240) + '...'
    }
    if ($statusCode -and $oneLine) { return "HTTP $statusCode — $oneLine" }
    if ($statusCode)               { return "HTTP $statusCode" }
    if ($oneLine)                  { return $oneLine }
    return 'unknown API error'
}

# Company-scoped API keys cannot read resources outside allowed companies (no retry).
function Test-HuduCompanyScopedPermissionError {
    param([object]$ErrorRecord)

    return (Get-HuduApiErrorText -ErrorRecord $ErrorRecord) -match 'Permissions scoped to company'
}

function Test-HuduApiNotFoundError {
    param([object]$ErrorRecord)

    $summary = Get-HuduApiErrorSummary -ErrorRecord $ErrorRecord
    return $summary -match '(?i)404|not found'
}

function Get-HuduArticleByIdSafe {
    param([int]$Id)

    try {
        $raw = Invoke-HuduJsonApi -Method GET -Resource "/api/v1/articles/$Id"
        return $raw.article ?? $raw
    } catch {
        if (Test-HuduCompanyScopedPermissionError $_) {
            return 'CompanyScopeDenied'
        }
        throw
    }
}

# Download a file from a Hudu source URL and return a structured record,
# mirroring the Invoke-ConfluenceAttachDownload pattern from the Confluence migration.
# Tries unauthenticated first (public photos are publicly accessible), then
# falls back to x-api-key auth if the source instance requires login.
# Returns a PSCustomObject with: FileName, Extension, IsImage, SourceUrl,
#   LocalPath, SuccessDownload, AttachmentSize, AttachmentTooLarge
function Invoke-HuduAttachDownload {
    param(
        [string]$Url,
        [string]$FileName,
        [string]$OutDir,
        [int]   $MaxSizeMB = 100,
        [string]$PublicPhotoId,
        [int]$PublicPhotoNumericId
    )

    $localPath = Join-Path $OutDir $FileName
    $ext       = [IO.Path]::GetExtension($FileName).ToLower()
    $imgExts   = @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.svg', '.tiff', '.tif')

    $record = [PSCustomObject]@{
        FileName           = $FileName
        Extension          = $ext
        IsImage            = $imgExts -contains $ext
        SourceUrl          = $Url
        LocalPath          = $localPath
        SuccessDownload    = $false
        AttachmentSize     = 0
        AttachmentTooLarge = $false
        AttemptDiagnostics = ''
        FailureKind        = $null
    }

    function Invoke-DownloadWithAuthRedirect {
        param(
            [string]$StartUri,
            [hashtable]$Headers,
            [string]$OutFile
        )
        $nextUri = $StartUri
        $maxHops = 10
        for ($hop = 0; $hop -lt $maxHops; $hop++) {
            try {
                Invoke-WebRequest -Uri $nextUri -Headers $Headers -OutFile $OutFile `
                    -MaximumRedirection 0 -ErrorAction Stop | Out-Null
                return [PSCustomObject]@{ Success = $true; StatusCode = 200; FinalUri = $nextUri; Error = $null }
            } catch {
                $resp = $_.Exception.Response
                if ($resp -and $resp.StatusCode) {
                    $statusCode = [int]$resp.StatusCode
                    if ($statusCode -in @(301, 302, 303, 307, 308)) {
                        $location = $resp.Headers['Location']
                        if ([string]::IsNullOrWhiteSpace($location)) {
                            return [PSCustomObject]@{ Success = $false; StatusCode = $statusCode; FinalUri = $nextUri; Error = "Redirect without Location header" }
                        }
                        $baseUri = [System.Uri]$nextUri
                        $nextUri = ([System.Uri]::new($baseUri, $location)).AbsoluteUri
                        continue
                    }
                    return [PSCustomObject]@{ Success = $false; StatusCode = $statusCode; FinalUri = $nextUri; Error = $_.Exception.Message }
                }
                return [PSCustomObject]@{ Success = $false; StatusCode = $null; FinalUri = $nextUri; Error = $_.Exception.Message }
            }
        }
        return [PSCustomObject]@{ Success = $false; StatusCode = $null; FinalUri = $nextUri; Error = "Too many redirects (>$maxHops)" }
    }

    # Try auth methods in order until one succeeds:
    #   1. No auth
    #   2. x-api-key
    #   3. Bearer token
    #   4. ?api_key= (URL-encoded)
    $plain          = Get-PlainText $script:SourceHuduApiKeySecure
    $encodedApiKey  = [System.Uri]::EscapeDataString($plain)
    $urlWithParam   = if ($Url -match '\?') { "$Url&api_key=$encodedApiKey" } else { "$Url`?api_key=$encodedApiKey" }
    $attempts       = [System.Collections.Generic.List[hashtable]]::new()

    # Prefer API public photo endpoint for article embedded images.
    if (-not [string]::IsNullOrWhiteSpace($PublicPhotoId)) {
        $apiBySlug = "$($script:SourceHuduUrl.TrimEnd('/'))/api/v1/public_photos/$PublicPhotoId"
        $attempts.Add(@{ Name = "api-public-photo-slug";      Uri = $apiBySlug; Headers = @{ 'x-api-key' = $plain } })
    }
    if ($PublicPhotoNumericId -gt 0) {
        $apiByNumeric = "$($script:SourceHuduUrl.TrimEnd('/'))/api/v1/public_photos/$PublicPhotoNumericId"
        $attempts.Add(@{ Name = "api-public-photo-numeric";   Uri = $apiByNumeric; Headers = @{ 'x-api-key' = $plain } })
    }

    $attempts.Add(@{ Name = "no-auth";         Uri = $Url;          Headers = @{}                                   })
    $attempts.Add(@{ Name = "x-api-key";       Uri = $Url;          Headers = @{ 'x-api-key'     = $plain         } })
    $attempts.Add(@{ Name = "bearer";          Uri = $Url;          Headers = @{ 'Authorization' = "Bearer $plain" } })
    $attempts.Add(@{ Name = "api-key-param";   Uri = $urlWithParam; Headers = @{}                                   })
    $plain = $null

    $downloaded = $false
    $attemptDiagnostics = [System.Collections.Generic.List[string]]::new()
    foreach ($attempt in $attempts) {
        $result = Invoke-DownloadWithAuthRedirect -StartUri $attempt.Uri -Headers $attempt.Headers -OutFile $localPath
        if ($result.Success) {
            $attemptDiagnostics.Add("$($attempt.Name)=200")
            $downloaded = $true
            break
        }
        $codeLabel = if ($null -ne $result.StatusCode) { [string]$result.StatusCode } else { 'ERR' }
        $attemptDiagnostics.Add("$($attempt.Name)=$codeLabel")
    }

    if ($downloaded) {
        $record.SuccessDownload    = $true
        $record.AttachmentSize     = (Get-Item -LiteralPath $localPath).Length
        $record.AttachmentTooLarge = $record.AttachmentSize -gt ($MaxSizeMB * 1MB)
        $record.AttemptDiagnostics = ($attemptDiagnostics -join ', ')
    } else {
        if (Test-Path -LiteralPath $localPath) {
            Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
        }
        $diag = ($attemptDiagnostics -join ', ')
        $record.AttemptDiagnostics = $diag
        if ($diag -match '401') {
            $record.FailureKind = 'AUTH_OR_SCOPE'
        } elseif ($diag -match '404' -and -not ($diag -match '200')) {
            $record.FailureKind = 'MISSING_SOURCE_ASSET'
        } else {
            $record.FailureKind = 'DOWNLOAD_FAILED'
        }
        Write-Log "  Download failed for '$FileName' ($Url): $diag" "WARN"
    }

    return $record
}

# Route uploads by source type.
#   public photos -> New-HuduPublicPhoto (embeddable /public_photo/<slug>)
#   article uploads -> New-HuduUpload    (downloadable /file/<slug>)
# Returns a PSCustomObject with: IsPublicPhoto, Url, Slug, Id, Raw
function Upload-FileToHudu {
    param(
        [string]$FilePath,
        [int]$ArticleId,
        [bool]$AsPublicPhoto = $false
    )
    if (-not (Test-Path $FilePath)) {
        Write-Log "File not found for upload: $FilePath" "ERROR"
        return $null
    }
    Use-TargetHudu
    try {
        if ($AsPublicPhoto) {
            $result = New-HuduPublicPhoto -FilePath $FilePath -record_id $ArticleId -record_type 'Article'
            $upload = $result.public_photo ?? $result
            return [PSCustomObject]@{
                IsPublicPhoto = $true
                Url           = $upload.url
                Slug    = $upload.slug ?? $upload.id
                Id      = $upload.id
                Raw     = $upload
            }
        } else {
            $result = New-HuduUpload -FilePath $FilePath -record_id $ArticleId -record_type 'Article'
            $upload = $result.upload ?? $result
            $ref    = if (-not [string]::IsNullOrWhiteSpace($upload.slug)) { $upload.slug } else { $upload.id }
            return [PSCustomObject]@{
                IsPublicPhoto = $false
                Url           = "$($script:TargetHuduUrl)/file/$ref"
                Slug    = $ref
                Id      = $upload.id
                Raw     = $upload
            }
        }
    } catch {
        Write-Log "Upload failed for $FilePath => article $ArticleId : $_" "ERROR"
        return $null
    }
}

function Test-IsPhotoFolder {
    param([object]$Folder)
    if (-not $Folder) { return $false }
    foreach ($prop in @('folder_type', 'type')) {
        if ($Folder.PSObject.Properties[$prop] -and $Folder.$prop) {
            return [string]$Folder.$prop -match '^(?i)photo$'
        }
    }
    return $false
}

function Test-IsAssetLayoutSidebarFolder {
    param([object]$Folder)

    if (-not $Folder) { return $false }
    if (Test-IsPhotoFolder $Folder) { return $false }

    if ($script:MigrationAssetLayoutSidebarFolderIds -and $Folder.id) {
        if ($script:MigrationAssetLayoutSidebarFolderIds.ContainsKey([string]$Folder.id)) {
            return $true
        }
    }

    foreach ($prop in @('folder_type', 'type')) {
        if ($Folder.PSObject.Properties[$prop] -and $Folder.$prop) {
            return [string]$Folder.$prop -match '^(?i)(asset[_-]?layout|sidebar|layout)$'
        }
    }
    return $false
}

function Get-AssetLayoutSidebarFolderLookupKey {
    param([string]$Name, [object]$ParentFolderId)

    $p = if ($ParentFolderId) { [string]$ParentFolderId } else { '0' }
    $n = (Get-MigrationName -Name $Name).Trim().ToLowerInvariant()
    return ('sidebar|{0}|{1}' -f $n, $p)
}

function Get-MigrationAssetLayoutSidebarFolderId {
    param([object]$Layout)

    if (-not $Layout) { return $null }
    if ($Layout.PSObject.Properties['sidebar_folder_id'] -and $Layout.sidebar_folder_id) {
        $id = [int]$Layout.sidebar_folder_id
        if ($id -gt 0) { return $id }
    }
    return $null
}

function Get-MigrationAssetLayoutSidebarFolderClosure {
    param([int[]]$RootFolderIds)

    $byId = @{}
    $pending = [System.Collections.Generic.Queue[int]]::new()
    foreach ($id in $RootFolderIds) {
        if ($id -gt 0) { $pending.Enqueue($id) }
    }

    while ($pending.Count -gt 0) {
        $folderId = $pending.Dequeue()
        $key = [string]$folderId
        if ($byId.ContainsKey($key)) { continue }

        try {
            Use-SourceHudu
            $folder = Get-HuduFolders -Id $folderId
            if (-not $folder) { continue }
            $byId[$key] = $folder
            $parentId = Get-FolderParentFolderId $folder
            if ($parentId -and -not $byId.ContainsKey([string]$parentId)) {
                $pending.Enqueue($parentId)
            }
        } catch {
            Write-Log "Could not load asset layout sidebar folder ID $folderId : $_" "WARN"
        }
    }

    return $byId.Values
}

function New-MigrationAssetLayoutSidebarFolderApi {
    param(
        [string]$Name,
        [int]$ParentFolderId = 0,
        [object]$SourceFolder = $null
    )

    $folderPayload = @{ name = $Name }
    if ($ParentFolderId -gt 0) { $folderPayload['parent_folder_id'] = $ParentFolderId }

    if ($SourceFolder) {
        foreach ($prop in @('folder_type', 'type', 'description')) {
            if ($SourceFolder.PSObject.Properties[$prop] -and $SourceFolder.$prop) {
                if ($prop -eq 'description') {
                    $folderPayload['description'] = [string]$SourceFolder.$prop
                } else {
                    $folderPayload['folder_type'] = [string]$SourceFolder.$prop
                }
            }
        }
    }

    $attempts = [System.Collections.Generic.List[hashtable]]::new()
    $null = $attempts.Add(@{ folder = $folderPayload })

    if (-not $folderPayload.ContainsKey('folder_type')) {
        foreach ($guess in @('asset_layout', 'sidebar', 'layout')) {
            $copy = @{} + $folderPayload
            $copy['folder_type'] = $guess
            $null = $attempts.Add(@{ folder = $copy })
        }
    }

    $lastError = $null
    foreach ($body in $attempts) {
        try {
            $response = Invoke-HuduJsonApi -Method POST -Resource '/api/v1/folders' -Body $body
            $created = $response.folder ?? $response
            if ($created -and $created.id) { return $created }
        } catch {
            $lastError = $_
        }
    }

    if ($lastError) { throw $lastError }
    throw 'API returned no folder id for asset layout sidebar folder'
}

function Set-MigrationAssetLayoutSidebarFolder {
    param(
        [int]$TargetLayoutId,
        [int]$TargetSidebarFolderId
    )

    if ($TargetSidebarFolderId -le 0) { return $false }

    try {
        Use-TargetHudu
        $raw = Get-HuduAssetLayouts -LayoutId $TargetLayoutId
        $layout = if ($raw.PSObject.Properties['asset_layout'] -and $raw.asset_layout) { $raw.asset_layout } else { $raw }
        if (-not $layout) { return $false }

        $layout.sidebar_folder_id = $TargetSidebarFolderId
        Invoke-HuduJsonApi -Method PUT -Resource "/api/v1/asset_layouts/$TargetLayoutId" -Body @{
            asset_layout = $layout
        } | Out-Null
        return $true
    } catch {
        Write-Log "Could not set sidebar folder on asset layout target ID $TargetLayoutId : $_" "WARN"
        return $false
    }
}

# ---- Folder lookup helpers --------------------------------------------------

function Get-FolderCompanyId {
    param([object]$Folder)
    if ($Folder.PSObject.Properties['company_id'] -and $Folder.company_id) {
        return [int]$Folder.company_id
    }
    return $null
}

function Get-FolderParentFolderId {
    param([object]$Folder)
    foreach ($prop in @('parent_folder_id', 'parent_id')) {
        if ($Folder.PSObject.Properties[$prop] -and $Folder.$prop) {
            return [int]$Folder.$prop
        }
    }
    return $null
}

function Get-FolderLookupKey {
    param([string]$Name, [object]$CompanyId, [object]$ParentFolderId)
    $c = if ($CompanyId)      { [string]$CompanyId }      else { '0' }
    $p = if ($ParentFolderId) { [string]$ParentFolderId } else { '0' }
    $n = (Get-MigrationName -Name $Name).Trim().ToLowerInvariant()
    return ('{0}|{1}|{2}' -f $n, $c, $p)
}

function Add-FolderLookupEntry {
    param([hashtable]$Lookup, [object]$Folder)
    if (-not $Folder -or -not $Folder.name) { return }
    $key = Get-FolderLookupKey `
        -Name           $Folder.name `
        -CompanyId      (Get-FolderCompanyId $Folder) `
        -ParentFolderId (Get-FolderParentFolderId $Folder)
    if (-not $Lookup.ContainsKey($key)) { $Lookup[$key] = $Folder }
}

# ---- Password migration helpers --------------------------------------------------

function Test-IsHuduPasswordVaultUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try {
        $path = ([Uri]$Url).AbsolutePath.TrimEnd('/')
        return $path -match '/passwords/[^/]+$'
    } catch {
        return $false
    }
}

# Site/login URL for a password record — not the Hudu vault link in the API "url" field.
function Get-MigrationPasswordLoginUrl {
    param([object]$Password)

    $candidate = $null
    if ($Password.PSObject.Properties['login_url'] -and -not [string]::IsNullOrWhiteSpace([string]$Password.login_url)) {
        $candidate = [string]$Password.login_url
    } elseif ($Password.PSObject.Properties['url'] -and -not [string]::IsNullOrWhiteSpace([string]$Password.url)) {
        $candidate = [string]$Password.url
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }
    if (Test-IsHuduPasswordVaultUrl -Url $candidate) { return $null }

    if ($script:SourceHuduUrl -and $script:TargetHuduUrl) {
        try {
            $sourceHost = ([Uri]$script:SourceHuduUrl.TrimEnd('/')).Host
            $targetBase = $script:TargetHuduUrl.TrimEnd('/')
            $uri = [Uri]$candidate
            if ($uri.Host -eq $sourceHost -and -not (Test-IsHuduPasswordVaultUrl -Url $candidate)) {
                $candidate = '{0}{1}' -f $targetBase, $uri.PathAndQuery
            }
        } catch { }
    }

    return $candidate
}

function Get-PasswordFolderLookupKey {
    param(
        [string]$Name,
        [object]$CompanyId
    )

    $companyValue = ($null -ne $CompanyId) ? [string]$CompanyId : '0'
    $n = (Get-MigrationName -Name $Name).Trim().ToLowerInvariant()
    return ('{0}|{1}' -f $n, $companyValue)
}

function Add-PasswordFolderLookupEntry {
    param(
        [hashtable]$Lookup,
        [object]$Folder
    )

    if ($Folder -and $Folder.name) {
        $companyId = ($Folder.PSObject.Properties['company_id'] -and $Folder.company_id) ? [int]$Folder.company_id : $null
        $key = Get-PasswordFolderLookupKey -Name $Folder.name -CompanyId $companyId
        if (-not $Lookup.ContainsKey($key)) { $Lookup[$key] = $Folder }
    }
}

function Get-PasswordLookupKey {
    param(
        [string]$Name,
        [object]$CompanyId,
        [object]$PasswordFolderId,
        [string]$Username,
        [string]$Url
    )

    $companyValue = ($null -ne $CompanyId) ? [string]$CompanyId : '0'
    $folderValue  = ($null -ne $PasswordFolderId) ? [string]$PasswordFolderId : '0'
    $userValue    = if ($Username) { $Username.Trim().ToLowerInvariant() } else { '0' }
    $urlValue     = if ($Url) { $Url.Trim().ToLowerInvariant() } else { '0' }
    $n = (Get-MigrationName -Name $Name).Trim().ToLowerInvariant()
    return ('{0}|{1}|{2}|{3}|{4}' -f $n, $companyValue, $folderValue, $userValue, $urlValue)
}

function Add-PasswordLookupEntry {
    param(
        [hashtable]$Lookup,
        [object]$Password
    )

    if ($Password -and $Password.name) {
        $companyId = ($Password.PSObject.Properties['company_id'] -and $Password.company_id) ? [int]$Password.company_id : $null
        $folderId  = ($Password.PSObject.Properties['password_folder_id'] -and $Password.password_folder_id) ? [int]$Password.password_folder_id : $null
        $username  = ($Password.PSObject.Properties['username'] -and $Password.username) ? [string]$Password.username : $null
        $url       = Get-MigrationPasswordLoginUrl -Password $Password
        $key = Get-PasswordLookupKey -Name $Password.name -CompanyId $companyId -PasswordFolderId $folderId -Username $username -Url $url
        if (-not $Lookup.ContainsKey($key)) { $Lookup[$key] = $Password }
    }
}

function Get-HuduSingleAsset {
    param([int]$AssetId)

    try {
        $response = Invoke-HuduJsonApi -Method GET -Resource "/api/v1/assets/$AssetId"
    } catch {
        if (Test-HuduCompanyScopedPermissionError $_) {
            return 'CompanyScopeDenied'
        }
        if (Test-HuduApiNotFoundError $_) {
            return $null
        }
        throw
    }

    if ($null -eq $response) { return $null }

    if ($response.PSObject.Properties['asset'] -and $response.asset) {
        return $response.asset
    }
    if ($response.PSObject.Properties['id'] -and $response.id) {
        return $response
    }

    $list = @(Get-HuduObjectList -Response $response -CollectionNames @('assets'))
    if ($list.Count -eq 1) { return $list[0] }
    return $list | Where-Object { $_.id -eq $AssetId } | Select-Object -First 1
}

function Find-TargetAssetMatch {
    param(
        [object]$SourceAsset,
        [object[]]$TargetAssets
    )

    if (-not $SourceAsset) { return $null }
    if ($null -eq $TargetAssets) { return $null }

    $TargetAssets = @($TargetAssets | Where-Object { $_ })
    if ($TargetAssets.Count -eq 0) { return $null }

    if ($SourceAsset.name) {
        $name = [string]$SourceAsset.name.Trim()
        $migratedName = Get-MigrationName -Name $name
        $byName = $TargetAssets | Where-Object {
            if (-not $_.name) { return $false }
            $tn = [string]$_.name.Trim()
            $tn.Equals($name, [System.StringComparison]::OrdinalIgnoreCase) -or
                $tn.Equals($migratedName, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if ($byName) { return $byName }
    }

    if ($SourceAsset.PSObject.Properties['slug'] -and $SourceAsset.slug) {
        $slug = [string]$SourceAsset.slug
        $bySlug = $TargetAssets | Where-Object {
            $_.PSObject.Properties['slug'] -and [string]$_.slug -eq $slug
        } | Select-Object -First 1
        if ($bySlug) { return $bySlug }
    }

    if ($SourceAsset.PSObject.Properties['primary_serial'] -and $SourceAsset.primary_serial) {
        $serial = [string]$SourceAsset.primary_serial
        $bySerial = $TargetAssets | Where-Object {
            $_.PSObject.Properties['primary_serial'] -and [string]$_.primary_serial -eq $serial
        } | Select-Object -First 1
        if ($bySerial) { return $bySerial }
    }

    return $null
}

function Get-CompanyAssetMap {
    param(
        [int]$SourceCompanyId,
        [int]$TargetCompanyId,
        [hashtable]$Cache
    )
    $cacheKey = "${SourceCompanyId}:${TargetCompanyId}"
    if ($Cache.ContainsKey($cacheKey)) { return $Cache[$cacheKey] }

    $map = @{}
    Use-SourceHudu
    $sourceAssets = @(Get-HuduObjectList -Response (Get-HuduAssets -CompanyId $SourceCompanyId) -CollectionNames @('assets'))
    Use-TargetHudu
    $targetAssets = @(Get-HuduObjectList -Response (Get-HuduAssets -CompanyId $TargetCompanyId) -CollectionNames @('assets'))

    foreach ($sa in $sourceAssets) {
        if (-not $sa.id) { continue }
        $match = Find-TargetAssetMatch -SourceAsset $sa -TargetAssets $targetAssets
        if ($match) { $map[[string]$sa.id] = [int]($match.id) }
    }

    $Cache[$cacheKey] = $map
    return $map
}

function ConvertTo-AssetCustomFieldKey {
    param([string]$Label)
    # Match HuduAPI / Hudu asset API: spaces → underscores, then lowercase (other chars kept).
    if ([string]::IsNullOrWhiteSpace($Label)) { return $null }
    return $Label.Trim().Replace(' ', '_').ToLowerInvariant()
}

function ConvertTo-MigrationRelationType {
    param([string]$Type)
    if ([string]::IsNullOrWhiteSpace($Type)) { return $Type }
    $norm = $Type.Trim().ToLowerInvariant() -replace '[^a-z0-9]', ''
    switch ($norm) {
        'assetpassword' { return 'AssetPassword' }
        'rackstorage'   { return 'RackStorage' }
        'ipaddress'     { return 'IpAddress' }
        'vlanzone'      { return 'VlanZone' }
        'article'       { return 'Article' }
        'company'       { return 'Company' }
        'website'       { return 'Website' }
        'network'       { return 'Network' }
        'asset'         { return 'Asset' }
        'procedure'     { return 'Procedure' }
        'vlan'          { return 'Vlan' }
        default         { return $Type.Trim() }
    }
}

function Get-MigrationRelationPairKey {
    param(
        [string]$FromType,
        [int]$FromId,
        [string]$ToType,
        [int]$ToId
    )

    $fromKey = '{0}|{1}' -f (ConvertTo-MigrationRelationType -Type $FromType), $FromId
    $toKey   = '{0}|{1}' -f (ConvertTo-MigrationRelationType -Type $ToType), $ToId
    $sorted  = @($fromKey, $toKey) | Sort-Object
    return '{0}<>{1}' -f $sorted[0], $sorted[1]
}

function ConvertTo-HuduAssetCustomFieldsPayload {
    param([hashtable]$FieldValues)

    if (-not $FieldValues -or $FieldValues.Count -eq 0) { return @() }

    $payload = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $FieldValues.GetEnumerator()) {
        $null = $payload.Add(@{ $entry.Key = $entry.Value })
    }
    return @($payload.ToArray())
}

function Get-MigrationListItemNames {
    param([object]$List)

    $names = [System.Collections.Generic.List[string]]::new()
    if (-not $List) { return @() }

    foreach ($prop in @('items', 'list_items', 'list_item')) {
        if (-not $List.PSObject.Properties[$prop] -or -not $List.$prop) { continue }
        foreach ($item in @($List.$prop)) {
            $name = $null
            if ($item -is [string]) {
                $name = $item
            } elseif ($item.PSObject.Properties['name'] -and $item.name) {
                $name = [string]$item.name
            } elseif ($item.PSObject.Properties['label'] -and $item.label) {
                $name = [string]$item.label
            }
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $trimmed = $name.Trim()
            if (-not ($names -contains $trimmed)) { $null = $names.Add($trimmed) }
        }
    }

    return @($names.ToArray())
}

function Get-MigrationSourceListDetail {
    param([int]$ListId)

    if ($ListId -le 0) { return $null }

    Use-SourceHudu
    try {
        $raw = Get-HuduLists -Id $ListId
        if (-not $raw) { return $null }
        if ($raw.PSObject.Properties['list'] -and $raw.list) { return $raw.list }
        return $raw
    } catch {
        Write-Log "Could not load source list ID $ListId : $(Get-HuduApiErrorSummary $_)" "WARN"
        return $null
    }
}

function Get-MigrationListIdsFromAssetLayouts {
    param([object[]]$SourceLayouts)

    $ids = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($layout in @($SourceLayouts)) {
        if (-not $layout -or -not $layout.fields) { continue }
        foreach ($field in @($layout.fields)) {
            if ([string]$field.field_type -ne 'ListSelect') { continue }
            if ($field.list_id -and [int]$field.list_id -gt 0) {
                [void]$ids.Add([int]$field.list_id)
            }
        }
    }
    return @($ids)
}

function New-MigrationTargetList {
    param(
        [string]$Name,
        [string[]]$Items
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'List name is required.'
    }
    if (-not $Items -or $Items.Count -eq 0) {
        throw "List '$Name' has no items on source — Hudu requires at least one list option."
    }

    Use-TargetHudu
    $listItems = @($Items | ForEach-Object { @{ name = $_ } })
    try {
        $response = Invoke-HuduJsonApi -Method POST -Resource '/api/v1/lists' -Body @{
            list = @{
                name                  = $Name
                list_items_attributes = $listItems
            }
        }
        $created = $response.list ?? $response
        if ($created -and $created.id) { return $created }
    } catch {
        Write-Log "JSON create failed for list '$Name': $(Get-HuduApiErrorSummary $_)" "WARN"
    }

    $fallback = New-HuduList -Name $Name -Items $Items
    if (-not $fallback) { return $null }
    return $fallback.list ?? $fallback
}

function Get-MigrationListMap {
    param([object[]]$SourceLayouts = @())

    Write-Log "Migrating Hudu lists (required for ListSelect asset layout fields)..."

    Use-SourceHudu
    $sourceLists = @(Get-HuduObjectList -Response (Get-HuduLists) -CollectionNames @('lists'))
    $sourceById = @{}
    foreach ($sl in $sourceLists) {
        if ($sl.id) { $sourceById[[string]$sl.id] = $sl }
    }

    $requiredListIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($id in (Get-MigrationListIdsFromAssetLayouts -SourceLayouts $SourceLayouts)) {
        [void]$requiredListIds.Add($id)
    }

    foreach ($layout in @($SourceLayouts)) {
        if (-not $layout.id) { continue }
        try {
            $detail = Get-AssetLayoutDetail -LayoutId ([int]$layout.id)
            foreach ($id in (Get-MigrationListIdsFromAssetLayouts -SourceLayouts @($detail))) {
                [void]$requiredListIds.Add($id)
            }
        } catch {
            Write-Log "Could not load layout detail for list discovery on '$($layout.name)': $_" "WARN"
        }
    }

    $listsToProcess = [System.Collections.Generic.List[object]]::new()
    foreach ($sl in $sourceLists) {
        if ($sl.id) { $null = $listsToProcess.Add($sl) }
    }
    foreach ($listId in @($requiredListIds)) {
        $key = [string]$listId
        if (-not $sourceById.ContainsKey($key)) {
            Write-Log "ListSelect references source list ID $listId but it was not in GET /lists — fetching by ID." "WARN"
            $detail = Get-MigrationSourceListDetail -ListId $listId
            if ($detail) {
                $sourceById[$key] = $detail
                $null = $listsToProcess.Add($detail)
            }
        }
    }

    Use-TargetHudu
    $targetLists = @(Get-HuduObjectList -Response (Get-HuduLists) -CollectionNames @('lists'))
    $targetByName = @{}
    foreach ($tl in $targetLists) {
        if ($tl.name) { $targetByName[[string]$tl.name.Trim().ToLowerInvariant()] = $tl }
    }

    $map = @{}
    $created = 0
    $matched = 0
    $failed  = 0
    $seenSourceIds = @{}

    foreach ($sl in $listsToProcess) {
        if (-not $sl.id) { continue }
        $sourceIdKey = [string]$sl.id
        if ($seenSourceIds.ContainsKey($sourceIdKey)) { continue }
        $seenSourceIds[$sourceIdKey] = $true

        $listName = if ($sl.name) { [string]$sl.name } else { "List $sourceIdKey" }
        $norm = $listName.Trim().ToLowerInvariant()

        $detail = Get-MigrationSourceListDetail -ListId ([int]$sl.id)
        if (-not $detail) { $detail = $sl }

        $itemNames = @(Get-MigrationListItemNames -List $detail)
        if ($itemNames.Count -eq 0) {
            $itemNames = @(Get-MigrationListItemNames -List $sl)
        }

        if ($norm -and $targetByName.ContainsKey($norm)) {
            $targetList = $targetByName[$norm]
            $map[$sourceIdKey] = [int]$targetList.id
            $matched++
            $targetItemCount = @(Get-MigrationListItemNames -List $targetList).Count
            Write-Log "List '$listName' already on target (ID $($targetList.id), $targetItemCount option(s))." "INFO"
            if ($itemNames.Count -gt 0 -and $targetItemCount -eq 0) {
                Write-Log "  Target list '$listName' has no options but source has $($itemNames.Count) — layout ListSelect may not match source values." "WARN"
            }
            continue
        }

        if ($itemNames.Count -eq 0) {
            $failed++
            Write-Log "Cannot create list '$listName' (source ID $sourceIdKey): no list options on source (index and GET /lists/{id} were empty)." "WARN"
            continue
        }

        try {
            $targetName = Get-MigrationName -Name $listName
            $newList = New-MigrationTargetList -Name $targetName -Items $itemNames
            if ($newList -and $newList.id) {
                $map[$sourceIdKey] = [int]$newList.id
                $targetByName[$targetName.Trim().ToLowerInvariant()] = $newList
                $created++
                Write-Log "Created list '$targetName' => target ID $($newList.id) ($($itemNames.Count) option(s))" "SUCCESS"
            } else {
                $failed++
                Write-Log "Failed to create list '$targetName' — API returned no list id." "ERROR"
            }
        } catch {
            $failed++
            Write-Log "Could not create target list '$listName': $_" "ERROR"
        }
    }

    Write-Log "Lists - Created: $created | Matched: $matched | Failed: $failed | Mapped for layouts: $($map.Count)"
    if ($requiredListIds.Count -gt 0) {
        $missingForLayouts = @($requiredListIds | Where-Object { -not $map.ContainsKey([string]$_) })
        if ($missingForLayouts.Count -gt 0) {
            Write-Log "ListSelect fields reference $($missingForLayouts.Count) source list(s) that could not be mapped: $($missingForLayouts -join ', ')" "WARN"
        }
    }

    return $map
}

function Get-MigrationTargetListOptions {
    param(
        [int]$ListId,
        [hashtable]$Cache
    )

    if ($ListId -le 0) { return @() }
    if ($Cache.ContainsKey($ListId)) { return $Cache[$ListId] }

    $options = [System.Collections.Generic.List[string]]::new()
    try {
        Use-TargetHudu
        $raw = Get-HuduLists -Id $ListId
        $list = $raw.list ?? $raw
        if ($list -and $list.PSObject.Properties['items'] -and $list.items) {
            foreach ($item in @($list.items)) {
                if ($item -is [string] -and $item) {
                    $null = $options.Add($item)
                } elseif ($item.PSObject.Properties['name'] -and $item.name) {
                    $null = $options.Add([string]$item.name)
                } elseif ($item.PSObject.Properties['label'] -and $item.label) {
                    $null = $options.Add([string]$item.label)
                }
            }
        }
    } catch {
        Write-Log "Could not load target list $ListId options: $_" "WARN"
    }

    $arr = @($options.ToArray())
    $Cache[$ListId] = $arr
    return $arr
}

function Resolve-MigrationListSelectValue {
    param(
        [string]$SourceValue,
        [string[]]$ValidOptions
    )

    if ([string]::IsNullOrWhiteSpace($SourceValue) -or -not $ValidOptions -or $ValidOptions.Count -eq 0) {
        return $null
    }

    $src = $SourceValue.Trim()
    foreach ($opt in $ValidOptions) {
        if ($opt -eq $src) { return $opt }
    }
    foreach ($opt in $ValidOptions) {
        if ($opt.Equals($src, [System.StringComparison]::OrdinalIgnoreCase)) { return $opt }
    }

    $aliases = @{
        'SMB'                                      = 'SMB / CIFS'
        'Smartphone'                               = 'Phone'
        'SSL VPN'                                  = 'Client VPN'
        'Hyper-V'                                  = 'Microsoft Hyper-V'
        'Microsoft Defender for Endpoint (P2)'     = 'Microsoft Defender'
        'Cloud Access Control'                     = 'Other'
    }
    if ($aliases.ContainsKey($src) -and ($ValidOptions -contains $aliases[$src])) {
        return $aliases[$src]
    }

    foreach ($opt in $ValidOptions) {
        if ($opt -like "*$src*" -or $src -like "*$($opt.Split('/')[0].Trim())*") {
            return $opt
        }
    }

    if ($ValidOptions -contains 'Other') { return 'Other' }
    return $null
}

function ConvertTo-MigrationAssetLayoutField {
    param(
        [object]$Field,
        [hashtable]$ListMap,
        [hashtable]$LayoutMap
    )

    if ($Field.PSObject.Properties['is_destroyed'] -and $Field.is_destroyed) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$Field.label)) { return $null }

    $def = @{
        label        = [string]$Field.label
        field_type   = [string]$Field.field_type
        show_in_list = [bool]($Field.show_in_list ?? $false)
        required     = [bool]($Field.required ?? $false)
    }
    if ($Field.PSObject.Properties['hint'] -and $null -ne $Field.hint) { $def['hint'] = [string]$Field.hint }
    if ($Field.PSObject.Properties['position'] -and $null -ne $Field.position) { $def['position'] = [int]$Field.position }
    if ($Field.PSObject.Properties['min'] -and $null -ne $Field.min) { $def['min'] = $Field.min }
    if ($Field.PSObject.Properties['max'] -and $null -ne $Field.max) { $def['max'] = $Field.max }
    if ($Field.PSObject.Properties['expiration'] -and $null -ne $Field.expiration) { $def['expiration'] = [bool]$Field.expiration }
    if ($Field.PSObject.Properties['multiple_options'] -and $null -ne $Field.multiple_options) {
        $def['multiple_options'] = [bool]$Field.multiple_options
    }
    if ($Field.PSObject.Properties['options'] -and $Field.options) { $def['options'] = [string]$Field.options }

    if ($Field.field_type -eq 'ListSelect') {
        if (-not $Field.list_id) {
            Write-Log "ListSelect '$($Field.label)': source field has no list_id — skipping field." "WARN"
            return $null
        }
        if (-not $ListMap.ContainsKey([string]$Field.list_id)) {
            Write-Log "ListSelect '$($Field.label)': no target list for source list ID $($Field.list_id) — skipping field." "WARN"
            return $null
        }
        $def['list_id'] = [int]$ListMap[[string]$Field.list_id]
    }
    if ($Field.field_type -eq 'AssetTag' -and $Field.linkable_id -and $LayoutMap.ContainsKey([string]$Field.linkable_id)) {
        $def['linkable_id'] = [int]$LayoutMap[[string]$Field.linkable_id]
    }

    return $def
}

function ConvertTo-MigrationAssetFieldValues {
    param(
        [object]$SourceAsset,
        [object]$TargetLayoutDetail,
        [hashtable]$AssetMap = @{},
        [hashtable]$ListOptionsCache = @{}
    )

    $values = @{}
    if (-not $SourceAsset.fields) { return $values }

    $targetFieldByLabel = @{}
    if ($TargetLayoutDetail -and $TargetLayoutDetail.fields) {
        foreach ($tf in @($TargetLayoutDetail.fields)) {
            if ($tf.label) { $targetFieldByLabel[[string]$tf.label.Trim().ToLowerInvariant()] = $tf }
        }
    }

    foreach ($sf in @($SourceAsset.fields)) {
        if ($null -eq $sf.value) { continue }
        if ($sf.value -is [string] -and [string]::IsNullOrWhiteSpace([string]$sf.value)) { continue }

        $label = if ($sf.label) { [string]$sf.label } else { $null }
        if (-not $label) { continue }

        $targetField = $null
        $norm = $label.Trim().ToLowerInvariant()
        if ($targetFieldByLabel.ContainsKey($norm)) { $targetField = $targetFieldByLabel[$norm] }
        if (-not $targetField) { continue }

        $keyLabel = [string]$targetField.label
        $key = ConvertTo-AssetCustomFieldKey -Label $keyLabel
        if (-not $key) { continue }

        $fieldType = if ($targetField.field_type) { [string]$targetField.field_type } else { $null }

        if ($fieldType -eq 'AssetTag') {
            $mapped = @()
            foreach ($rawId in @($sf.value)) {
                $sid = [string]$rawId
                if ($AssetMap.ContainsKey($sid)) { $mapped += [int]$AssetMap[$sid] }
            }
            if ($mapped.Count -eq 0) { continue }
            $values[$key] = @($mapped)
            continue
        }

        if ($fieldType -eq 'ListSelect') {
            $listId = 0
            if ($targetField.PSObject.Properties['list_id'] -and $targetField.list_id) {
                $listId = [int]$targetField.list_id
            }
            $validOptions = if ($listId -gt 0) {
                Get-MigrationTargetListOptions -ListId $listId -Cache $ListOptionsCache
            } else {
                @()
            }

            $rawValues = if ($sf.value -is [System.Array]) {
                @($sf.value | ForEach-Object { [string]$_ })
            } else {
                @([string]$sf.value)
            }

            $mapped = [System.Collections.Generic.List[string]]::new()
            foreach ($rv in $rawValues) {
                $resolved = Resolve-MigrationListSelectValue -SourceValue $rv -ValidOptions $validOptions
                if ($resolved) { $null = $mapped.Add($resolved) }
                elseif ($validOptions.Count -eq 0) { $null = $mapped.Add($rv) }
                else {
                    Write-Log "ListSelect '$label': dropped value '$rv' (not in target list options)." "WARN"
                }
            }
            if ($mapped.Count -gt 0) { $values[$key] = @($mapped.ToArray()) }
            continue
        }

        if ($fieldType -eq 'CheckBox') {
            $values[$key] = if ($sf.value -is [bool]) { $(if ($sf.value) { 'true' } else { 'false' }) } else { [string]$sf.value }
            continue
        }

        if ($fieldType -eq 'Date') {
            $parsed = $null
            if ($sf.value -is [datetime]) {
                $parsed = $sf.value
            } elseif ([datetime]::TryParse([string]$sf.value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            } elseif ([datetime]::TryParse([string]$sf.value, [ref]$parsed)) {
            }
            if ($parsed) {
                $values[$key] = $parsed.ToString('yyyy/MM/dd')
            }
            continue
        }

        if ($fieldType -eq 'Number') {
            $values[$key] = [string]$sf.value
            continue
        }

        $values[$key] = $sf.value
    }

    return $values
}

function Get-FlagDedupeKey {
    param(
        [string]$FlagableType,
        [int]$FlagableId,
        [int]$FlagTypeId,
        [string]$Description
    )

    $desc = if ($Description) { [string]$Description } else { '' }
    $desc = ($desc -replace "`r`n", "`n").Trim().ToLowerInvariant()
    $type = if ($FlagableType) { [string]$FlagableType.Trim().ToLowerInvariant() } else { '' }
    return ('{0}|{1}|{2}|{3}' -f $type, $FlagableId, $FlagTypeId, $desc)
}

function Get-ArticleLookupKey {
    param(
        [string]$Name,
        [object]$CompanyId,
        [object]$FolderId
    )

    $companyValue = ($null -ne $CompanyId) ? [string]$CompanyId : '0'
    $folderValue  = ($null -ne $FolderId)  ? [string]$FolderId  : '0'
    $n            = (Get-MigrationName -Name $Name).Trim().ToLowerInvariant()
    return ('{0}|{1}|{2}' -f $n, $companyValue, $folderValue)
}

function Add-ArticleLookupEntry {
    param(
        [hashtable]$Lookup,
        [object]$Article
    )

    if (-not $Article -or -not $Article.name) { return }
    $companyId = ($Article.PSObject.Properties['company_id'] -and $Article.company_id) ? [int]$Article.company_id : 0
    $folderId  = ($Article.PSObject.Properties['folder_id'] -and $Article.folder_id) ? [int]$Article.folder_id : 0
    $key       = Get-ArticleLookupKey -Name $Article.name -CompanyId $companyId -FolderId $folderId
    if (-not $Lookup.ContainsKey($key)) { $Lookup[$key] = [int]$Article.id }
    if ($folderId -ne 0) {
        $keyAnyFolder = Get-ArticleLookupKey -Name $Article.name -CompanyId $companyId -FolderId 0
        if (-not $Lookup.ContainsKey($keyAnyFolder)) { $Lookup[$keyAnyFolder] = [int]$Article.id }
    }
}

function Find-ArticleTargetIdByMigratedName {
    param(
        [string]$SourceName,
        [int]$TargetCompanyId,
        [hashtable]$ArticleTargetLookup
    )

    $migrated = (Get-MigrationName -Name $SourceName).Trim().ToLowerInvariant()
    $prefix   = '{0}|{1}|' -f $migrated, $TargetCompanyId
    foreach ($kv in $ArticleTargetLookup.GetEnumerator()) {
        if ($kv.Key.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [int]$kv.Value
        }
    }
    return $null
}

function Resolve-MigrationArticleTargetId {
    param(
        [int]$SourceArticleId,
        [hashtable]$ArticleMap,
        [hashtable]$ArticleTargetLookup,
        [hashtable]$CompanyMap,
        [hashtable]$FolderMap,
        [hashtable]$Cache
    )

    $entry = $ArticleMap[[string]$SourceArticleId]
    if ($entry) { return [int]$entry.TargetId }

    $cacheKey = "article:$SourceArticleId"
    if ($Cache.ContainsKey($cacheKey)) {
        $cached = $Cache[$cacheKey]
        if ($cached) { return [int]$cached }
        return $null
    }

    $targetId = $null
    try {
        Use-SourceHudu
        $srcOrStatus = Get-HuduArticleByIdSafe -Id $SourceArticleId
        if ($srcOrStatus -eq 'CompanyScopeDenied') {
            $deniedKey = "article:denied:$SourceArticleId"
            if (-not $Cache.ContainsKey($deniedKey)) {
                Write-Log "Source article $SourceArticleId : API key cannot access this article (permissions scoped to company) — skipping." "WARN"
                $Cache[$deniedKey] = $true
            }
            $Cache[$cacheKey] = $null
            return $null
        }
        $src = $srcOrStatus
        if ($src -and $src.name) {
            foreach ($mapped in $ArticleMap.Values) {
                if ($mapped.Name -eq $src.name) {
                    $Cache[$cacheKey] = [int]$mapped.TargetId
                    return [int]$mapped.TargetId
                }
            }

            $targetCompanyId = 0
            if ($src.company_id -and $src.company_id -ne 0) {
                $targetCompanyId = $CompanyMap[[string]$src.company_id]
                if (-not $targetCompanyId) {
                    $Cache[$cacheKey] = $null
                    return $null
                }
            }
            $targetFolderId = 0
            if ($src.folder_id -and $src.folder_id -ne 0) {
                $targetFolderId = $FolderMap[[string]$src.folder_id]
                if (-not $targetFolderId) { $targetFolderId = 0 }
            }
            $key = Get-ArticleLookupKey -Name $src.name -CompanyId $targetCompanyId -FolderId $targetFolderId
            if ($ArticleTargetLookup.ContainsKey($key)) {
                $targetId = [int]$ArticleTargetLookup[$key]
            }
            if (-not $targetId -and $targetFolderId -ne 0) {
                $keyNoFolder = Get-ArticleLookupKey -Name $src.name -CompanyId $targetCompanyId -FolderId 0
                if ($ArticleTargetLookup.ContainsKey($keyNoFolder)) {
                    $targetId = [int]$ArticleTargetLookup[$keyNoFolder]
                }
            }
            if (-not $targetId -and $targetCompanyId) {
                $targetId = Find-ArticleTargetIdByMigratedName -SourceName $src.name `
                    -TargetCompanyId $targetCompanyId -ArticleTargetLookup $ArticleTargetLookup
            }
        }
    } catch {
        Write-Log "Could not resolve article flag target for source article $SourceArticleId : $(Get-HuduApiErrorSummary $_)" "WARN"
    }

    $Cache[$cacheKey] = $targetId
    return $targetId
}

function New-MigrationProcedureTask {
    param(
        [Parameter(Mandatory)]
        [int]$ProcedureId,
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Description,
        [int]$Position = 0,
        [int]$ParentTaskId = 0
    )

    $task = @{
        name         = $Name
        procedure_id = $ProcedureId
    }
    if ($Description) { $task['description'] = $Description }
    if ($Position)    { $task['position']    = $Position }
    if ($ParentTaskId -gt 0) { $task['parent_task_id'] = $ParentTaskId }

    $response = Invoke-HuduJsonApi -Method POST -Resource '/api/v1/procedure_tasks' -Body @{
        procedure_task = $task
    }
    return $response.procedure_task ?? $response
}

function Get-FlagTypeLookupKey {
    param([object]$FlagType)
    $rawName = if ($FlagType.name) { [string]$FlagType.name } else { '' }
    $name  = (Get-MigrationName -Name $rawName).Trim().ToLowerInvariant()
    $color = if ($FlagType.color) { [string]$FlagType.color.Trim().ToLowerInvariant() } else { '' }
    return '{0}|{1}' -f $name, $color
}

function Get-FileSignature {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) {
        return $null
    }

    $item = Get-Item $FilePath
    $hash = Get-FileHash -Algorithm SHA256 -Path $FilePath
    return '{0}|{1}' -f $item.Length, $hash.Hash
}

function Test-AndRegister-FileSignature {
    param(
        [hashtable]$Registry,
        [string]$FilePath,
        [string]$Context
    )

    $signature = Get-FileSignature -FilePath $FilePath
    if (-not $signature) {
        return $false
    }

    if ($Registry.ContainsKey($signature)) {
        Write-Log "SKIPPED duplicate file ($Context): $(Split-Path $FilePath -Leaf) matches '$($Registry[$signature])'" "WARN"
        return $true
    }

    $Registry[$signature] = $FilePath
    return $false
}