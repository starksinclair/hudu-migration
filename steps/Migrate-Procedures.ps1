# ============================================================================
# Migrate-Procedures.ps1 — procedure templates, runs, and tasks
# ============================================================================

function Invoke-MigrateProcedureTasks {
    param(
        [int]$TargetProcedureId,
        [object[]]$AllTasks,
        [System.Collections.IDictionary]$Stats
    )

    $taskIdMap   = @{}
    $parentTasks = $allTasks | Where-Object { $null -eq $_.parent_task_id } | Sort-Object position
    foreach ($task in $parentTasks) {
        try {
            $newTask = New-MigrationProcedureTask `
                -ProcedureId $TargetProcedureId `
                -Name        $task.name `
                -Description $(if ($task.description) { [string]$task.description } else { $null }) `
                -Position    $(if ($task.position) { [int]$task.position } else { 0 })
            $newTaskId = ($newTask.procedure_task ?? $newTask).id
            if (-not $newTaskId) { throw 'API returned no procedure task id' }
            $taskIdMap[[string]$task.id] = [int]$newTaskId

            if ($task.completed -eq $true) {
                Set-HuduProcedureTask -Id $newTaskId -Completed $true -ErrorAction SilentlyContinue | Out-Null
            }
            $Stats.TasksCreated++
            Write-Log "  Created parent task '$($task.name)' => ID $newTaskId" "SUCCESS"
        } catch {
            Write-Log "  Failed to create parent task '$($task.name)': $_" "ERROR"
            $Stats.TasksFailed++
        }
    }

    $subTasks = $allTasks | Where-Object { $null -ne $_.parent_task_id } | Sort-Object position
    foreach ($task in $subTasks) {
        $newParentId = $taskIdMap[[string]$task.parent_task_id]
        if (-not $newParentId) {
            Write-Log "  No parent mapping for subtask '$($task.name)'. Skipping." "WARN"
            $Stats.TasksFailed++
            continue
        }
        try {
            $newTask = New-MigrationProcedureTask `
                -ProcedureId $TargetProcedureId `
                -Name        $task.name `
                -Description $(if ($task.description) { [string]$task.description } else { $null }) `
                -Position    $(if ($task.position) { [int]$task.position } else { 0 }) `
                -ParentTaskId $newParentId
            $newTaskId = ($newTask.procedure_task ?? $newTask).id
            if (-not $newTaskId) { throw 'API returned no procedure task id' }
            $taskIdMap[[string]$task.id] = [int]$newTaskId

            if ($task.completed -eq $true) {
                Set-HuduProcedureTask -Id $newTaskId -Completed $true -ErrorAction SilentlyContinue | Out-Null
            }
            $Stats.TasksCreated++
            Write-Log "    Created subtask '$($task.name)' under parent $newParentId" "SUCCESS"
        } catch {
            Write-Log "    Failed to create subtask '$($task.name)': $_" "ERROR"
            $Stats.TasksFailed++
        }
    }
}

function Invoke-ProcedureMigration {
    param(
        [hashtable]$CompanyMap,
        [System.Collections.IDictionary]$Stats,
        [string]   $MigrationMode,
        [int]      $SelectedCompanyId
    )

    Write-Log "========== STEP 5: MIGRATING PROCEDURES =========="

    Use-SourceHudu
    Write-Log "Fetching source procedures..."
    try {
        $allProcs     = @(Get-HuduProcedures)
        $srcTemplates = @($allProcs | Where-Object { -not $_.run })
        $srcRuns      = @($allProcs | Where-Object { $_.run -eq $true })

        if ($MigrationMode -eq "SINGLE") {
            $srcTemplates = @($srcTemplates | Where-Object { $_.company_id -eq $SelectedCompanyId })
            $srcRuns      = @($srcRuns | Where-Object { $_.company_id -eq $SelectedCompanyId })
        }

        Write-Log "Templates: $($srcTemplates.Count) | Runs: $($srcRuns.Count)"
    } catch {
        Write-Log "Error fetching procedures: $($_.Exception.Message)" "ERROR"
        $srcTemplates = @()
        $srcRuns      = @()
    }

    Use-TargetHudu
    $existingTargetProcedures = @(Get-HuduProcedures)
    $targetTemplateByName     = @{}

    foreach ($proc in $srcTemplates) {
        $targetCompanyId = $null
        if ($proc.company_id -and $proc.company_id -ne 0) {
            $targetCompanyId = $CompanyMap[[string]$proc.company_id]
            if (-not $targetCompanyId) {
                Write-Log "No company mapping for procedure '$($proc.name)'. Skipping." "WARN"
                $Stats.ProceduresSkipped++
                continue
            }
        }

        $targetProcName = Get-MigrationName -Name $proc.name
        $existingProc = $existingTargetProcedures | Where-Object {
            -not $_.run -and $_.name -eq $targetProcName -and $_.company_id -eq $targetCompanyId
        } | Select-Object -First 1

        if ($existingProc) {
            Write-Log "Procedure template '$targetProcName' already exists (ID $($existingProc.id)). Mapping." "WARN"
            $targetTemplateByName[$targetProcName] = [int]$existingProc.id
            $Stats.ProceduresSkipped++
            continue
        }

        try {
            Use-SourceHudu
            $procDetail = $null
            try {
                $raw        = Get-HuduProcedures -Id $proc.id
                $procDetail = $raw.procedure ?? $raw
            } catch {
                Write-Log "Could not fetch detail for procedure '$($proc.name)': $_" "WARN"
            }
            $allTasks = @(if ($procDetail -and $procDetail.procedure_tasks) {
                $procDetail.procedure_tasks
            } else {
                try { Get-HuduProcedureTasks -ProcedureId $proc.id } catch { @() }
            })

            Use-TargetHudu
            $procParams = @{ Name = $targetProcName }
            if ($targetCompanyId)  { $procParams['CompanyId']   = $targetCompanyId }
            if ($proc.description) { $procParams['Description'] = $proc.description }

            $created   = New-HuduProcedure @procParams
            $newProcId = [int](($created.procedure ?? $created).id)
            $targetTemplateByName[$targetProcName] = $newProcId
            $null = $existingTargetProcedures += ($created.procedure ?? $created)
            $Stats.ProceduresCreated++
            Write-Log "Created procedure template '$targetProcName' => target ID $newProcId" "SUCCESS"

            Invoke-MigrateProcedureTasks -TargetProcedureId $newProcId -AllTasks $allTasks -Stats $Stats
        } catch {
            Write-Log "Failed to create procedure template '$targetProcName': $_" "ERROR"
            $Stats.ProceduresFailed++
        }
    }

    foreach ($proc in $srcRuns) {
        $targetCompanyId = $null
        if ($proc.company_id -and $proc.company_id -ne 0) {
            $targetCompanyId = $CompanyMap[[string]$proc.company_id]
            if (-not $targetCompanyId) {
                Write-Log "No company mapping for procedure run '$($proc.name)'. Skipping." "WARN"
                $Stats.ProceduresSkipped++
                continue
            }
        }

        $targetProcName = Get-MigrationName -Name $proc.name
        $existingRun = $existingTargetProcedures | Where-Object {
            $_.run -eq $true -and $_.name -eq $targetProcName -and $_.company_id -eq $targetCompanyId
        } | Select-Object -First 1

        if ($existingRun) {
            Write-Log "Procedure run '$targetProcName' already exists (ID $($existingRun.id)). Skipping." "WARN"
            $Stats.ProceduresSkipped++
            continue
        }

        $targetTemplateId = $targetTemplateByName[$targetProcName]
        if (-not $targetTemplateId) {
            $targetTemplate = $existingTargetProcedures | Where-Object {
                -not $_.run -and $_.name -eq $targetProcName -and $_.company_id -eq $targetCompanyId
            } | Select-Object -First 1
            if ($targetTemplate) { $targetTemplateId = [int]$targetTemplate.id }
        }
        if (-not $targetTemplateId) {
            Write-Log "No target template for run '$($proc.name)'. Skipping run." "WARN"
            $Stats.ProceduresFailed++
            continue
        }

        try {
            Use-TargetHudu
            $run = Start-HuduProcedure -ProcedureId $targetTemplateId
            $newProcId = [int](($run.procedure ?? $run).id)
            if (-not $newProcId) { throw 'Start-HuduProcedure returned no run id' }

            $Stats.ProceduresCreated++
            Write-Log "Started procedure run '$targetProcName' from template $targetTemplateId => run ID $newProcId (tasks copied from template by kickoff)" "SUCCESS"
        } catch {
            Write-Log "Failed to create procedure run '$targetProcName': $_" "ERROR"
            $Stats.ProceduresFailed++
        }
    }

    Write-Log "Procedures - Created: $($Stats.ProceduresCreated) | Skipped: $($Stats.ProceduresSkipped) | Failed: $($Stats.ProceduresFailed)"
    Write-Log "Tasks      - Created: $($Stats.TasksCreated) | Failed: $($Stats.TasksFailed)"
}
