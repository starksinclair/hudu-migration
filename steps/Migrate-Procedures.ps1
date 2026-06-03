# ============================================================================
# Migrate-Procedures.ps1 — procedure templates, runs, and tasks
# ============================================================================

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
        $srcTemplates = $allProcs | Where-Object { -not $_.run }
        $srcRuns      = $allProcs | Where-Object { $_.run -eq $true }

        if ($MigrationMode -eq "SINGLE") {
            $srcTemplates = $srcTemplates | Where-Object { $_.company_id -eq $SelectedCompanyId }
            $srcRuns      = $srcRuns      | Where-Object { $_.company_id -eq $SelectedCompanyId }
        }

        $procsToMigrate = @($srcTemplates) + @($srcRuns)
        Write-Log "Templates: $($srcTemplates.Count) | Runs: $($srcRuns.Count) | Total: $($procsToMigrate.Count)"
    } catch {
        Write-Log "Error fetching procedures: $($_.Exception.Message)" "ERROR"
        $procsToMigrate = @()
    }

    Use-TargetHudu
    $existingTargetProcedures = @(Get-HuduProcedures)

    foreach ($proc in $procsToMigrate) {
        $targetCompanyId = $null
        if ($proc.company_id -and $proc.company_id -ne 0) {
            $targetCompanyId = $CompanyMap[[string]$proc.company_id]
            if (-not $targetCompanyId) {
                Write-Log "No company mapping for procedure '$($proc.name)'. Skipping." "WARN"
                $Stats.ProceduresSkipped++
                continue
            }
        }

        $procType = if ($proc.run) { "run ($($proc.status))" } else { "template" }

        $existingProc = $existingTargetProcedures | Where-Object {
            $_.name       -eq $proc.name -and
            $_.company_id -eq $targetCompanyId -and
            $_.run        -eq $proc.run
        } | Select-Object -First 1

        if ($existingProc) {
            Write-Log "Procedure '$($proc.name)' ($procType) already exists. Skipping." "WARN"
            $Stats.ProceduresSkipped++
            continue
        }

        try {
            # Fetch full detail (with tasks) from source before switching context
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
            $procParams = @{ Name = $proc.name }
            if ($targetCompanyId)    { $procParams['CompanyId']   = $targetCompanyId  }
            if ($proc.description)   { $procParams['Description'] = $proc.description }
            if ($proc.run -eq $true) { $procParams['Run']         = $true             }

            $created   = New-HuduProcedure @procParams
            $newProcId = ($created.procedure ?? $created).id
            $Stats.ProceduresCreated++
            Write-Log "Created procedure '$($proc.name)' ($procType) => target ID $newProcId" "SUCCESS"

            # Two-pass task migration to preserve parent -> subtask hierarchy
            $taskIdMap   = @{}
            $parentTasks = $allTasks | Where-Object { $null -eq $_.parent_task_id } | Sort-Object position
            foreach ($task in $parentTasks) {
                try {
                    $tp = @{ ProcedureId = $newProcId; Name = $task.name }
                    if ($task.description) { $tp['Description'] = $task.description }
                    if ($task.position)    { $tp['Position']    = $task.position    }

                    $newTask   = New-HuduProcedureTask @tp
                    $newTaskId = ($newTask.procedure_task ?? $newTask).id
                    $taskIdMap[[string]$task.id] = $newTaskId

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
                    $tp = @{ ProcedureId = $newProcId; Name = $task.name; ParentTaskId = $newParentId }
                    if ($task.description) { $tp['Description'] = $task.description }
                    if ($task.position)    { $tp['Position']    = $task.position    }

                    $newTask   = New-HuduProcedureTask @tp
                    $newTaskId = ($newTask.procedure_task ?? $newTask).id
                    $taskIdMap[[string]$task.id] = $newTaskId

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
        } catch {
            Write-Log "Failed to create procedure '$($proc.name)' ($procType): $_" "ERROR"
            $Stats.ProceduresFailed++
        }
    }

    Write-Log "Procedures - Created: $($Stats.ProceduresCreated) | Skipped: $($Stats.ProceduresSkipped) | Failed: $($Stats.ProceduresFailed)"
    Write-Log "Tasks      - Created: $($Stats.TasksCreated) | Failed: $($Stats.TasksFailed)"
}
