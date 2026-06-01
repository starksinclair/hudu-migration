# ============================================================================
# CompanySelector.ps1 — console and WinForms company picker
# ============================================================================

function Show-CompanySelectorConsole {
    param([object[]]$Companies)

    Write-Host ""
    Write-Host "=== Hudu Migration - Company Selector ===" -ForegroundColor Cyan
    Write-Host "Choose a single company to test, or migrate all companies at once." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [1] Migrate ONE company (testing)"    -ForegroundColor White
    Write-Host "  [2] Migrate ALL companies (production)" -ForegroundColor White
    Write-Host "  [C] Cancel"                             -ForegroundColor White
    Write-Host ""

    do {
        $modeChoice = (Read-Host "Enter choice (1, 2, or C)").Trim().ToUpperInvariant()
    } while ($modeChoice -notin @('1', '2', 'C'))

    if ($modeChoice -eq 'C') { return @{ Mode = 'CANCEL'; CompanyId = $null } }
    if ($modeChoice -eq '2') {
        Write-Host "Full migration: all companies will be migrated." -ForegroundColor Green
        return @{ Mode = 'ALL'; CompanyId = $null }
    }

    Write-Host ""
    Write-Host "Companies in source instance:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Companies.Count; $i++) {
        $co = $Companies[$i]
        Write-Host ("  [{0}] {1} (ID: {2})" -f ($i + 1), $co.name, $co.id)
    }
    Write-Host ""
    Write-Host "Tip: Start with a small company for testing before a full migration." -ForegroundColor DarkGreen
    Write-Host ""

    do {
        $raw = Read-Host "Enter company number (1-$($Companies.Count))"
        if ($raw -match '^\d+$') {
            $index = [int]$raw - 1
            if ($index -ge 0 -and $index -lt $Companies.Count) {
                $picked = $Companies[$index]
                Write-Host "Selected: $($picked.name) (ID: $($picked.id))" -ForegroundColor Green
                return @{ Mode = 'SINGLE'; CompanyId = $picked.id }
            }
        }
        Write-Host "Invalid selection. Enter a number from 1 to $($Companies.Count)." -ForegroundColor Yellow
    } while ($true)
}

function Show-CompanySelectorGui {
    param([object[]]$Companies)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = "Hudu Migration - Company Selector"
    $form.Size          = New-Object System.Drawing.Size(600, 500)
    $form.StartPosition = "CenterScreen"
    $form.BackColor     = [System.Drawing.Color]::FromArgb(240, 240, 240)
    $form.Font          = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.MaximizeBox   = $false
    $form.MinimizeBox   = $false

    $titleLabel          = New-Object System.Windows.Forms.Label
    $titleLabel.Text     = "Select Migration Mode"
    $titleLabel.Location = New-Object System.Drawing.Point(20, 20)
    $titleLabel.Size     = New-Object System.Drawing.Size(550, 30)
    $titleLabel.Font     = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($titleLabel)

    $instructionLabel          = New-Object System.Windows.Forms.Label
    $instructionLabel.Text     = "Choose a single company to test, or migrate all companies at once."
    $instructionLabel.Location = New-Object System.Drawing.Point(20, 55)
    $instructionLabel.Size     = New-Object System.Drawing.Size(550, 25)
    $instructionLabel.Font     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
    $form.Controls.Add($instructionLabel)

    $companyLabel          = New-Object System.Windows.Forms.Label
    $companyLabel.Text     = "Companies in Source Instance:"
    $companyLabel.Location = New-Object System.Drawing.Point(20, 85)
    $companyLabel.Size     = New-Object System.Drawing.Size(550, 20)
    $companyLabel.Font     = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($companyLabel)

    $listBox               = New-Object System.Windows.Forms.ListBox
    $listBox.Location      = New-Object System.Drawing.Point(20, 110)
    $listBox.Size          = New-Object System.Drawing.Size(550, 250)
    $listBox.Font          = New-Object System.Drawing.Font("Segoe UI", 10)
    $listBox.SelectionMode = "One"
    foreach ($company in $Companies) {
        $listBox.Items.Add("$($company.name) (ID: $($company.id))") | Out-Null
    }
    $form.Controls.Add($listBox)

    $infoLabel           = New-Object System.Windows.Forms.Label
    $infoLabel.Text      = "Tip: Start with a small company for testing before running full migration"
    $infoLabel.Location  = New-Object System.Drawing.Point(20, 365)
    $infoLabel.Size      = New-Object System.Drawing.Size(550, 35)
    $infoLabel.AutoSize  = $false
    $infoLabel.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
    $infoLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 0)
    $form.Controls.Add($infoLabel)

    $migrateOneButton           = New-Object System.Windows.Forms.Button
    $migrateOneButton.Text      = "Migrate This Company"
    $migrateOneButton.Location  = New-Object System.Drawing.Point(20, 410)
    $migrateOneButton.Size      = New-Object System.Drawing.Size(170, 40)
    $migrateOneButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $migrateOneButton.ForeColor = [System.Drawing.Color]::White
    $migrateOneButton.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($migrateOneButton)

    $migrateAllButton           = New-Object System.Windows.Forms.Button
    $migrateAllButton.Text      = "Migrate All Companies"
    $migrateAllButton.Location  = New-Object System.Drawing.Point(205, 410)
    $migrateAllButton.Size      = New-Object System.Drawing.Size(170, 40)
    $migrateAllButton.BackColor = [System.Drawing.Color]::FromArgb(0, 176, 80)
    $migrateAllButton.ForeColor = [System.Drawing.Color]::White
    $migrateAllButton.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($migrateAllButton)

    $cancelButton           = New-Object System.Windows.Forms.Button
    $cancelButton.Text      = "Cancel"
    $cancelButton.Location  = New-Object System.Drawing.Point(390, 410)
    $cancelButton.Size      = New-Object System.Drawing.Size(180, 40)
    $cancelButton.BackColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $cancelButton.Font      = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($cancelButton)

    $script:_selectorMode      = $null
    $script:_selectorCompanyId = $null

    $migrateOneButton.Add_Click({
        if ($listBox.SelectedIndex -lt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please select a company first", "Selection Required",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        $script:_selectorMode      = "SINGLE"
        $script:_selectorCompanyId = $Companies[$listBox.SelectedIndex].id
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $migrateAllButton.Add_Click({
        $script:_selectorMode      = "ALL"
        $script:_selectorCompanyId = $null
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $cancelButton.Add_Click({
        $script:_selectorMode = "CANCEL"
        $form.DialogResult    = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })

    $form.ShowDialog() | Out-Null
    return @{ Mode = $script:_selectorMode; CompanyId = $script:_selectorCompanyId }
}

function Show-CompanySelector {
    param([object[]]$Companies)
    if ($IsWindows) { return Show-CompanySelectorGui -Companies $Companies }
    return Show-CompanySelectorConsole -Companies $Companies
}
