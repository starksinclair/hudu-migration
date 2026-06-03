# ============================================================================
# Migrate-Passwords.ps1 — password (and password folder if necessary) migration
# ============================================================================

function Invoke-PasswordMigration {
    Write-Log "========== STEP 3: MIGRATING PASSWORDS AND PASSWORD FOLDERS =========="

    if (-not $Stats) {
        $Stats = [PSCustomObject]@{
            PasswordFoldersCreated = 0
            PasswordFoldersSkipped = 0
            PasswordFoldersFailed  = 0
            PasswordsCreated        = 0
            PasswordsSkipped        = 0
            PasswordsFailed         = 0
        }
    }


    Use-SourceHudu
    $sourcePasswordFolders = Get-HuduPasswordFolders
    $sourcePasswords = Get-HuduPasswords
    Write-Log "Found $($sourcePasswordFolders.Count) password folders and $($sourcePasswords.Count) passwords in source."

    $passwordFolderCandidates = @{}

    foreach ($folder in $sourcePasswordFolders) {
        $candidateCompanyId = if ($folder.company_id -and $folder.company_id -ne 0) { [int]$folder.company_id } else { 0 }
        $candidateKey = Get-PasswordFolderLookupKey -Name $folder.name -CompanyId $candidateCompanyId
        if (-not $passwordFolderCandidates.ContainsKey($candidateKey)) {
            $passwordFolderCandidates[$candidateKey] = [PSCustomObject]@{
                id             = $folder.id
                name           = $folder.name
                company_id     = $candidateCompanyId
                description    = $folder.description
                security       = $folder.security
                allowed_groups = $folder.allowed_groups
            }
        }
    }

    foreach ($password in $sourcePasswords) {
        if (-not $password.password_folder_id -or $password.password_folder_id -eq 0) {
            continue
        }

        if ($password.password_folder_name) {
            $inferredCompanyId = if ($password.company_id -and $password.company_id -ne 0) { [int]$password.company_id } else { 0 }
            $inferredKey = Get-PasswordFolderLookupKey -Name $password.password_folder_name -CompanyId $inferredCompanyId

            if (-not $passwordFolderCandidates.ContainsKey($inferredKey)) {
                $passwordFolderCandidates[$inferredKey] = [PSCustomObject]@{
                    id             = $password.password_folder_id
                    name           = $password.password_folder_name
                    company_id     = $inferredCompanyId
                    description    = $null
                    security       = $null
                    allowed_groups = $null
                }
            }
        }
    }

    $sourcePasswordFolderById = @{}
    $sourcePasswordFoldersToMigrate = @($passwordFolderCandidates.Values)
    foreach ($folder in $sourcePasswordFoldersToMigrate) {
        $sourcePasswordFolderById[[string]$folder.id] = $folder
    }


    Use-TargetHudu
    $targetPasswordFolders = @(Get-HuduPasswordFolders)
    $PasswordFolderLookup = @{}

    foreach ($targetFolder in $targetPasswordFolders) {
        Add-PasswordFolderLookupEntry -Lookup $PasswordFolderLookup -Folder $targetFolder
    }

    $PasswordFolderMap = @{} 

    foreach ($folder in $sourcePasswordFoldersToMigrate) {
        if ($migrationMode -eq "SINGLE") {
            if ($folder.company_id -and $folder.company_id -ne 0 -and $folder.company_id -ne $selectedCompanyId) {
                continue
            }
        }

        $folderKey = Get-PasswordFolderLookupKey -Name $folder.name -CompanyId 0
        $existing = $PasswordFolderLookup[$folderKey]

        if ($existing) {
            Write-Log "Global Folder Recognized: Mapping Source ID $($folder.id) -> Target ID $($existing.id)." "INFO"
            $PasswordFolderMap[[string]$folder.id] = $existing.id
            $Stats.PasswordFoldersSkipped++
            continue
        }

        try {
            Use-TargetHudu
            $folderParams = @{ Name = $folder.name }
            if ($folder.description) { $folderParams.Description = $folder.description }
            if ($folder.allowed_groups -and $folder.allowed_groups.Count -gt 0) {
                $folderParams.Security = 'specific'
                $folderParams.AllowedGroups = @($folder.allowed_groups)
            } else {
                $folderParams.Security = 'all_users'
            }
            
            $created = New-HuduPasswordFolder @folderParams
            $newId = $created.id ?? $created.password_folder.id ?? $created.folder.id
            
            if (-not $newId) {
                $refetchedFolder = Get-HuduPasswordFolders -Name $folder.name | Select-Object -First 1
                if ($refetchedFolder) { $newId = $refetchedFolder.id }
            }

            $PasswordFolderMap[[string]$folder.id] = $newId
            Add-PasswordFolderLookupEntry -Lookup $PasswordFolderLookup -Folder $created
            $Stats.PasswordFoldersCreated++
        } catch {
            Write-Log "Failed to create password folder '$($folder.name)': $_" "ERROR"
            $Stats.PasswordFoldersFailed++
        }
    }


    Use-TargetHudu
    $targetPasswords = @(Get-HuduPasswords)
    $PasswordLookup = @{}

    foreach ($targetPassword in $targetPasswords) {
        Add-PasswordLookupEntry -Lookup $PasswordLookup -Password $targetPassword
    }

    foreach ($password in $sourcePasswords) {
        if ($migrationMode -eq "SINGLE") {
            if ($password.company_id -and $password.company_id -ne 0 -and $password.company_id -ne $selectedCompanyId) {
                continue
            }
        }

        $targetCompanyId = $null
        if ($password.company_id -and $password.company_id -ne 0) {
            if ($null -ne $CompanyMap -and $CompanyMap.ContainsKey([string]$password.company_id)) {
                $targetCompanyId = $CompanyMap[[string]$password.company_id]
            } else {
                $targetCompanyId = 43 # Target Context fallback
            }
        }

        $targetPasswordFolderId = $null
        if ($password.password_folder_id -and $password.password_folder_id -ne 0) {
            $targetPasswordFolderId = $PasswordFolderMap[[string]$password.password_folder_id]
        }

        try {
            $passwordParams = @{
                name     = $password.name
            }
            if ($null -ne $targetCompanyId) { $passwordParams['company_id'] = [int]$targetCompanyId }
            if ($password.username) { $passwordParams['username'] = $password.username }
            if ($password.password) { $passwordParams['password'] = $password.password }

            $otpKeys = @('otp_secret', 'otp_uri')
            foreach ($k in $otpKeys) {
                if ($password.PSObject.Properties[$k] -and $null -ne $password.$k) {
                    $passwordParams[$k] = $password.$k
                }
            }

            if ($targetPasswordFolderId) { $passwordParams['password_folder_id'] = [int]$targetPasswordFolderId }
            if ($password.notes) { $passwordParams['notes'] = $password.notes }
            if ($password.url) { $passwordParams['url'] = $password.url }

            $passwordKey = Get-PasswordLookupKey -Name $password.name -CompanyId ($targetCompanyId ?? 0)
            if ($PasswordLookup.ContainsKey($passwordKey)) {
                Write-Log "Password '$($password.name)' already exists inside destination company. Skipping." "INFO"
                $Stats.PasswordsSkipped++
                continue
            }

            Use-TargetHudu
            $createdPwd = New-HuduPassword @passwordParams
            $createdObj = $createdPwd.password ?? $createdPwd
            if ($createdObj -and $createdObj.id) {
                Add-PasswordLookupEntry -Lookup $PasswordLookup -Password $createdObj
            }

            $Stats.PasswordsCreated++
        } catch {
            Write-Log "Failed to migrate password record '$($password.name)': $_" "ERROR"
            $Stats.PasswordsFailed++
        }
    }

    Write-Log "Password Records Complete - Created: $($Stats.PasswordsCreated) | Skipped: $($Stats.PasswordsSkipped) | Failed: $($Stats.PasswordsFailed)"
}