<#
 Register / remove / inspect the scheduled task that runs lab\MatlabJobRunner.ps1 every 5 minutes.
   powershell -NoProfile -ExecutionPolicy Bypass -File lab\install_task.ps1 install|uninstall|status
 Runs as the current user, only while that user is logged on (Interactive), limited rights - no admin needed.
 If registration is denied the script says so and stops (it never elevates).
 Touches only the task "MatlabJobRunner"; other tasks are never read or changed.
#>
param([Parameter(Position = 0)][ValidateSet('install', 'uninstall', 'status')][string]$Action = 'status')
$TaskName = 'MatlabJobRunner'
$Root = Split-Path -Parent $PSScriptRoot
$Runner = Join-Path $PSScriptRoot 'MatlabJobRunner.ps1'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Show-Status {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { Write-Output "NOT REGISTERED: $TaskName"; return }
    $i = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Output "REGISTERED: $TaskName  state=$($t.State)  user=$($t.Principal.UserId)  logon=$($t.Principal.LogonType)  runlevel=$($t.Principal.RunLevel)"
    Write-Output "  repetition interval : $($t.Triggers[0].Repetition.Interval)"
    Write-Output "  last run time       : $($i.LastRunTime)"
    Write-Output "  last task result    : $($i.LastTaskResult)  (0 = success, 267009 = running, 267011 = not run yet)"
    Write-Output "  next run time       : $($i.NextRunTime)"
    Write-Output "  missed runs         : $($i.NumberOfMissedRuns)"
    Write-Output "  action              : $($t.Actions[0].Execute) $($t.Actions[0].Arguments)"
    $hb = Join-Path $Root 'results\jobs\runner_heartbeat.json'
    if (Test-Path -LiteralPath $hb) { Write-Output "  heartbeat           : $((Get-Content -LiteralPath $hb -Raw -Encoding UTF8 | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 4))" }
}

switch ($Action) {
    'install' {
        if (-not (Test-Path -LiteralPath $Runner)) { Write-Output "ERROR: $Runner not found"; exit 1 }
        try {
            $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $args1 = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Runner
            $act = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $args1 -WorkingDirectory $Root
            $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
            $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
            $pri = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Principal $pri `
                -Description 'Senpai MATLAB job runner (every 5 min): git pull, start at most one MATLAB job, results\ only' `
                -Force -ErrorAction Stop | Out-Null
            Write-Output "installed $TaskName (every 5 min, user $user, only when logged on)"
            Show-Status
        } catch {
            Write-Output "INSTALL FAILED: $($_.Exception.Message)"
            if ($_.Exception.Message -match 'denied|Access|0x80070005') {
                Write-Output 'Administrator rights seem to be required on this machine. Not elevating - stopping here.'
            }
            exit 1
        }
    }
    'uninstall' {
        # a running MATLAB job is an independent process and keeps running; stop it with jobs\<id>.stop beforehand if needed
        try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop; Write-Output "removed $TaskName" }
        catch { Write-Output "uninstall: $($_.Exception.Message)"; exit 1 }
    }
    'status' { Show-Status }
}
