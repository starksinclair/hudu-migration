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

# Route uploads by extension:
#   images  -> New-HuduPublicPhoto  (embeddable /public_photo/<slug>)
#   others  -> New-HuduUpload       (downloadable attachment)
function Upload-FileToHudu {
    param([string]$FilePath, [int]$ArticleId)
    if (-not (Test-Path $FilePath)) {
        Write-Log "File not found for upload: $FilePath" "ERROR"
        return $null
    }
    $ext    = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $images = @('.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp', '.svg', '.tiff', '.tif')
    Use-TargetHudu
    try {
        if ($images -contains $ext) {
            $result = New-HuduPublicPhoto -FilePath $FilePath -record_id $ArticleId -record_type 'Article'
            return ($result.public_photo ?? $result)
        } else {
            $result = New-HuduUpload -FilePath $FilePath -uploadable_id $ArticleId -uploadable_type Article
            return ($result.upload ?? $result)
        }
    } catch {
        Write-Log "Upload failed for $FilePath => article $ArticleId : $_" "ERROR"
        return $null
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
