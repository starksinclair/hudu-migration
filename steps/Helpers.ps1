# ============================================================================
# Helpers.ps1 — shared utility functions
# Dot-sourced by company-migration.ps1 before any step is called.
# Functions here rely on these variables being set in the caller's scope:
#   $LogFile, $LogDir, $SourceHuduUrl, $TargetHuduUrl,
#   $SourceHuduApiKeySecure, $TargetHuduApiKeySecure
# ============================================================================

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
        $detail = $_.ErrorDetails.Message
        if (-not $detail) { $detail = $_.Exception.Message }
        throw "Hudu API $Method $Resource failed: $detail"
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
    return ('{0}|{1}|{2}' -f $Name.Trim().ToLowerInvariant(), $c, $p)
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

function Get-PasswordFolderLookupKey {
    param(
        [string]$Name,
        [object]$CompanyId
    )

    $companyValue = ($null -ne $CompanyId) ? [string]$CompanyId : '0'
    return ('{0}|{1}' -f $Name.Trim().ToLowerInvariant(), $companyValue)
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
    return ('{0}|{1}|{2}|{3}|{4}' -f $Name.Trim().ToLowerInvariant(), $companyValue, $folderValue, $userValue, $urlValue)
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
        $url       = ($Password.PSObject.Properties['url'] -and $Password.url) ? [string]$Password.url : $null
        $key = Get-PasswordLookupKey -Name $Password.name -CompanyId $companyId -PasswordFolderId $folderId -Username $username -Url $url
        if (-not $Lookup.ContainsKey($key)) { $Lookup[$key] = $Password }
    }
}

function Get-HuduSingleAsset {
    param([int]$AssetId)

    $response = Get-HuduAssets -Id $AssetId
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

    if ($SourceAsset.name) {
        $name = [string]$SourceAsset.name.Trim()
        $byName = $TargetAssets | Where-Object {
            $_.name -and [string]$_.name.Trim().Equals($name, [System.StringComparison]::OrdinalIgnoreCase)
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

function Get-FlagTypeLookupKey {
    param([object]$FlagType)
    $name  = if ($FlagType.name)  { [string]$FlagType.name.Trim().ToLowerInvariant() }  else { '' }
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