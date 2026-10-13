<#
 One-time setup of the lab PC, as far as it can be automated. Run on the lab PC as user kiriki, AFTER the repo was
 cloned with the deploy key (docs\lab_setup.md, section 2):
   powershell -NoProfile -ExecutionPolicy Bypass -File C:\work\<repo>\lab\setup_lab.ps1 [-MatlabExe <path>]
   ... -Snapshot      only record the state of the existing research (before/after comparison, docs section 5)

 Steps (stops at the first NG with what to do):
   1 repo: ASCII path, not OneDrive, results/ ignored, core.sshCommand (repo-local) set, read access to GitHub
   2 MATLAB: path + version, -batch exit codes (0 on success, non-zero on error) -> lab\config.json
   3 Parallel: Processes profile NumWorkers = 6 (skipped and recorded if Parallel Computing Toolbox is missing)
   4 Syncthing: copy lab\lab_stignore.txt to <repo>\.stignore (the folder itself is added in the GUI by a person)
   5 task: lab\install_task.ps1 install + status
 Never touches: git --global settings, gh, other scheduled tasks, other Syncthing folders, other processes.
 Writes a report to results\setup\setup_report.txt.
#>
param(
    [string]$MatlabExe,
    [switch]$SkipParallelProfile,
    [switch]$SkipTask,
    [switch]$Snapshot
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$SetupDir = Join-Path $Root 'results\setup'
New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
$Report = Join-Path $SetupDir 'setup_report.txt'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$KeyPath = Join-Path $env:USERPROFILE '.ssh\senpai_repo_ed25519'

function Out-Report([string]$Line) {
    Write-Host $Line
    [IO.File]::AppendAllText($Report, ("{0}  {1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Line), $Utf8)
}
function OK([string]$m) { Out-Report "OK    $m" }
function NG([string]$m, [string]$what) {
    Out-Report "NG    $m"
    Out-Report "      -> $what"
    Out-Report 'STOPPED. Nothing after this step was done.'
    exit 1
}
function Invoke-Native([string]$Exe, [string[]]$NativeArgs) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $Exe @NativeArgs 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $old }
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = (@($o) -join "`n").Trim() }
}

# ---- before/after record of the existing research (read-only: no index refresh, no task change)
function Save-Snapshot {
    $f = Join-Path $SetupDir ('existing_research_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $lines = @("snapshot $(Get-Date -Format o)")
    $sindy = 'C:\work\sindy-rl-winter'
    if (Test-Path $sindy) {
        $st = Invoke-Native 'git' @('-C', $sindy, '--no-optional-locks', 'status', '--porcelain')
        $lines += "git status --porcelain ($sindy): exit=$($st.Code) lines=$(@($st.Output -split "`n" | Where-Object { $_ }).Count)"
        $lines += $st.Output
    } else { $lines += "$sindy not found" }
    foreach ($n in 'CraneJobRunner', 'CraneWatchdog', 'SyncthingAutostart') {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        if ($t) { $i = Get-ScheduledTaskInfo -TaskName $n; $lines += "task ${n}: state=$($t.State) last=$($i.LastRunTime) result=$($i.LastTaskResult) next=$($i.NextRunTime)" }
        else { $lines += "task ${n}: not found" }
    }
    $lines += 'Syncthing: check in the GUI (http://127.0.0.1:8384) that every existing folder shows 0 errors / Up to Date.'
    [IO.File]::WriteAllText($f, ($lines -join "`r`n") + "`r`n", $Utf8)
    Write-Host ($lines -join "`n")
    Write-Host "`nsaved: $f"
}
if ($Snapshot) { Save-Snapshot; exit 0 }

# ---- run a short MATLAB command the same way the runner does (cmd wrapper writes %ERRORLEVEL%)
function Invoke-MatlabCheck([string]$Exe, [string]$Name, [string]$Code, [int]$TimeoutMin = 15) {
    $cmdFile = Join-Path $SetupDir "$Name.cmd"
    $log = Join-Path $SetupDir "$Name.log"
    $ecFile = Join-Path $SetupDir "$Name.exitcode.txt"
    Remove-Item -LiteralPath $log, $ecFile -ErrorAction SilentlyContinue
    $line = ('"{0}" -batch "{1}" -logfile "{2}"' -f $Exe, $Code, $log).Replace('%', '%%')   # % is special in .cmd files
    $text = "@echo off`r`n$line`r`n>`"$ecFile`" echo %ERRORLEVEL%`r`n"
    [IO.File]::WriteAllText($cmdFile, $text, [Text.Encoding]::ASCII)
    Write-Host "      running MATLAB: $Code  (can take a few minutes)"
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList '/d', '/c', "`"$cmdFile`"" -WindowStyle Hidden -PassThru
    try { $p.PriorityClass = 'BelowNormal' } catch { }
    if (-not $p.WaitForExit($TimeoutMin * 60000)) {
        & taskkill.exe /PID $p.Id /T /F | Out-Null     # only the process tree this script started
        return [pscustomobject]@{ ExitCode = $null; Log = $log; Text = "timeout after $TimeoutMin min" }
    }
    $ec = if (Test-Path $ecFile) { (Get-Content -LiteralPath $ecFile -Raw).Trim() } else { $null }
    $lt = if (Test-Path $log) { Get-Content -LiteralPath $log -Raw } else { '' }
    [pscustomobject]@{ ExitCode = $ec; Log = $log; Text = $lt }
}

Out-Report "==== setup_lab.ps1 on $env:COMPUTERNAME as $env:USERNAME, repo $Root"

# ---- 1 repo
if ($Root -match '[^\x20-\x7E]') { NG "repo path is not ASCII: $Root" 'clone again to C:\work\<repo name> (ASCII only)' }
if ($Root -match 'OneDrive') { NG "repo is under OneDrive: $Root" 'clone again to C:\work\<repo name>' }
if ($Root -notmatch '^C:\\') { Out-Report "WARN  repo is not on C: ($Root). C:\work\<repo name> is recommended." }
$gv = Invoke-Native 'git' @('--version')
if ($gv.Code -ne 0) { NG 'git not found on PATH' 'install Git for Windows or ask the person in charge of the lab PC' }
$ign = Invoke-Native 'git' @('-C', $Root, 'check-ignore', '-q', 'results/x')
if ($ign.Code -ne 0) { NG 'results/ is not git-ignored' 'the senpai must add /results/ to .gitignore and push' }
$ssh = Invoke-Native 'git' @('-C', $Root, 'config', '--local', '--get', 'core.sshCommand')
if (-not $ssh.Output) {
    if (-not (Test-Path $KeyPath)) { NG "deploy key $KeyPath not found" 'do docs\lab_setup.md section 2 first' }
    $sshCmd = 'ssh -i "{0}" -o IdentitiesOnly=yes -o BatchMode=yes' -f ($KeyPath -replace '\\', '/')
    [void](Invoke-Native 'git' @('-C', $Root, 'config', '--local', 'core.sshCommand', $sshCmd))
    Out-Report "set repo-local core.sshCommand = $sshCmd"
}
OK "core.sshCommand (repo-local) = $((Invoke-Native 'git' @('-C', $Root, 'config', '--local', '--get', 'core.sshCommand')).Output)"
$fetch = Invoke-Native 'git' @('-C', $Root, 'fetch', '--dry-run')
if ($fetch.Code -ne 0) { NG "git fetch failed: $($fetch.Output)" 'check that the deploy key is registered on GitHub (senpai) and that the clone used it' }
OK 'git fetch works with the deploy key'
$dirty = Invoke-Native 'git' @('-C', $Root, 'status', '--porcelain')
if ($dirty.Output) { NG "working tree not clean:`n$($dirty.Output)" 'the runner will not pull while this is so; ask the senpai (do not delete research files on your own)' }
OK 'working tree clean'

# ---- 2 MATLAB
$cfgPath = Join-Path $PSScriptRoot 'config.json'
if (-not $MatlabExe -and (Test-Path $cfgPath)) { $MatlabExe = (Get-Content $cfgPath -Raw | ConvertFrom-Json).matlabExe }
if (-not $MatlabExe) {
    $MatlabExe = Get-ChildItem 'C:\Program Files\MATLAB\R*\bin\matlab.exe' -ErrorAction SilentlyContinue |
        Sort-Object { $_.Directory.Parent.Name } | Select-Object -Last 1 -ExpandProperty FullName
}
if (-not $MatlabExe -or -not (Test-Path -LiteralPath $MatlabExe)) { NG 'matlab.exe not found' 'run again with -MatlabExe "<path to bin\matlab.exe>"' }
if ($MatlabExe -match '[%"]') { NG "unusual MATLAB path: $MatlabExe" 'ask the senpai' }
OK "MATLAB: $MatlabExe"
$v = Invoke-MatlabCheck $MatlabExe 'check_version' 'disp(version); exit(0)'
if ($v.ExitCode -ne '0') { NG "MATLAB did not run (exit code $($v.ExitCode)). Log: $($v.Log)`n$($v.Text)" 'if it is a license error, stop here and talk to the senpai' }
OK ("MATLAB version: {0}" -f (($v.Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()))
$e = Invoke-MatlabCheck $MatlabExe 'check_error' "error('setup_lab:check','intentional error')"
if (-not $e.ExitCode -or $e.ExitCode -eq '0') { NG "MATLAB -batch with an error returned exit code '$($e.ExitCode)' (must be non-zero)" 'the runner cannot tell failed jobs; ask the senpai (see SPEC 4.6: add exit(code))' }
OK "-batch exit codes: success 0, error $($e.ExitCode)"
$gitPath = (Get-Command git).Source
[IO.File]::WriteAllText($cfgPath, ([ordered]@{ matlabExe = $MatlabExe; gitExe = $gitPath } | ConvertTo-Json) + "`r`n", $Utf8)
OK "wrote $cfgPath (git-ignored)"

# ---- 3 Parallel Computing Toolbox: at most 6 workers
if ($SkipParallelProfile) { Out-Report 'SKIP  parallel profile (-SkipParallelProfile)' }
else {
    $code = "if isempty(ver('parallel')), disp('NO_PCT'), exit(0), end; " +
        "try, c=parcluster('Processes'); catch, c=parcluster('local'); end; " +
        "c.NumWorkers=6; saveProfile(c); c=parcluster(c.Profile); fprintf('PROFILE=%s NUMWORKERS=%d\n', c.Profile, c.NumWorkers); exit(0)"
    $pc = Invoke-MatlabCheck $MatlabExe 'check_parallel' $code
    if ($pc.Text -match 'NO_PCT') { Out-Report 'SKIP  Parallel Computing Toolbox is not installed (nothing to limit). Recorded.' }
    elseif ($pc.Text -match 'NUMWORKERS=6') { OK ("parallel profile: " + ([regex]::Match($pc.Text, 'PROFILE=\S+ NUMWORKERS=\d+').Value)) }
    else { NG "could not set NumWorkers=6. Log: $($pc.Log)`n$($pc.Text)" 'ask the senpai' }
}

# ---- 4 Syncthing ignore file (must exist BEFORE the folder is added in the Syncthing GUI)
$stSrc = Join-Path $PSScriptRoot 'lab_stignore.txt'
$stDst = Join-Path $Root '.stignore'
Copy-Item -LiteralPath $stSrc -Destination $stDst -Force
OK ".stignore: $((Get-Content $stDst) -join ' | ')"

# ---- 5 scheduled task
if ($SkipTask) { Out-Report 'SKIP  task registration (-SkipTask)' }
else {
    $it = Invoke-Native $PSHOME\powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'install_task.ps1'), 'install')
    Out-Report $it.Output
    if ($it.Code -ne 0) { NG 'task registration failed' 'do not use admin rights; ask the person in charge of the lab PC' }
    OK 'task MatlabJobRunner registered'
}

Out-Report 'DONE. Next (by hand): Syncthing GUI steps and the checks in docs\lab_setup.md (sections 4-5).'
