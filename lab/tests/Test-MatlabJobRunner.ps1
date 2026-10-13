<#
 Unit tests for lab\MatlabJobRunner.ps1 (Windows PowerShell 5.1, no Pester needed).
   powershell -NoProfile -ExecutionPolicy Bypass -File lab\tests\Test-MatlabJobRunner.ps1 [-GitExe <git.exe>] [-RealMatlab <matlab.exe>]

 Builds a throw-away setup under %TEMP%: a bare "GitHub" repo, a "senpai" clone that pushes jobs, and a "lab" clone
 the runner works in. MATLAB is replaced by fake_matlab.cmd (+ fake_matlab.ps1).
 Each runner tick is a separate powershell.exe, like the scheduled task.
 With -RealMatlab, also checks the real MATLAB: -batch exit codes, maxNumCompThreads = 6, MATLAB_MAX_WORKERS, vars escaping.
 Everything (temp folders, processes it started) is removed at the end. Exit code = number of failed checks.
#>
param(
    [string]$GitExe,
    [string]$RealMatlab
)
$ErrorActionPreference = 'Stop'

$LabDir = Split-Path -Parent $PSScriptRoot
$Runner = Join-Path $LabDir 'MatlabJobRunner.ps1'
$RepoGitignore = Join-Path (Split-Path -Parent $LabDir) '.gitignore'
if (-not $GitExe) {
    $c = Get-Command git -ErrorAction SilentlyContinue
    $GitExe = if ($c) { $c.Source } else { @('C:\Program Files\Git\cmd\git.exe', 'C:\Program Files\Git\bin\git.exe', 'C:\Program Files\Git\ucrt64\bin\git.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1 }
}
if (-not $GitExe) { throw 'git not found; pass -GitExe' }

$T = Join-Path $env:TEMP ('mjr_test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Remote = Join-Path $T 'remote.git'
$Senpai = Join-Path $T 'senpai'
$Lab = Join-Path $T 'lab'
$Fake = Join-Path $PSScriptRoot 'fake_matlab.cmd'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$script:Pass = 0; $script:Fail = 0; $script:Failed = @()

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; $script:Failed += $Name; Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red }
}
function Section([string]$Name) { Write-Host "`n== $Name" -ForegroundColor Cyan }

function Git([string]$Dir, [string[]]$GitArgs) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & $GitExe -C $Dir @GitArgs 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $o" }
    (@($o) -join "`n").Trim()
}
$Who = @('-c', 'user.name=test', '-c', 'user.email=test@example.invalid')

function Write-Utf8([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}

# senpai side: write files (relative path -> content; $null = delete), commit, push
function Push-Files([hashtable]$Files, [string]$Message = 'test') {
    foreach ($k in $Files.Keys) {
        $p = Join-Path $Senpai $k
        if ($null -eq $Files[$k]) { Remove-Item -LiteralPath $p -Force } else { Write-Utf8 $p $Files[$k] }
    }
    Git $Senpai @('add', '-A') | Out-Null
    Git $Senpai ($Who + @('commit', '-q', '-m', $Message)) | Out-Null
    Git $Senpai @('push', '-q', 'origin', 'HEAD') | Out-Null
}

function JobJson([string]$Id, [string]$Entry = 'src/ok_job.m', $Vars = $null, [string]$IdField = $Id) {
    $o = [ordered]@{ id = $IdField; entry = $Entry }
    if ($null -ne $Vars) { $o.vars = $Vars }
    $o | ConvertTo-Json -Depth 5
}

function Tick([string]$Matlab = $Fake) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Runner -RepoRoot $Lab -MatlabExe $Matlab -GitExe $GitExe 2>&1 }
    finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0) { Check 'runner exits with 0' $false "exit=$LASTEXITCODE $o" }
    if ($o) { Write-Host "  (runner output) $o" -ForegroundColor DarkYellow }
}

function Status([string]$Id) {
    $p = Join-Path $Lab "results\jobs\$Id\status.json"
    if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
}
function Heartbeat { Get-Content -LiteralPath (Join-Path $Lab 'results\jobs\runner_heartbeat.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function RunnerLog { Get-Content -LiteralPath (Join-Path $Lab 'results\jobs\runner.log') -Raw -Encoding UTF8 }

function JobPids($St) { @([int]$St.wrapperPid) + @(@($St.matlabProcesses) | Where-Object { $_ } | ForEach-Object { [int]$_.pid }) | Where-Object { $_ -gt 0 } }
function AnyAlive([int[]]$Pids) { @($Pids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -gt 0 }
function Wait-JobGone([string]$Id, [int]$TimeoutSec = 60) {
    $pids = JobPids (Status $Id)
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((AnyAlive $pids) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 300 }
    -not (AnyAlive $pids)
}

Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class MjrWindows {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static List<string> Visible() {
        List<string> r = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (IsWindowVisible(h)) { uint p; GetWindowThreadProcessId(h, out p); r.Add(h.ToInt64() + ":" + p); }
            return true; }, IntPtr.Zero);
        return r;
    }
}
'@
function VisibleWindows { @([MjrWindows]::Visible()) }
# new visible windows that belong to a console host / terminal / the job's own processes
function SuspiciousNewWindows($Before, [int[]]$JobPids) {
    @(VisibleWindows | Where-Object { $Before -notcontains $_ } | ForEach-Object {
        $wpid = [int]($_.Split(':')[1])
        $p = Get-Process -Id $wpid -ErrorAction SilentlyContinue
        $name = if ($p) { $p.ProcessName } else { '?' }
        if ($JobPids -contains $wpid -or $name -match '^(cmd|conhost|OpenConsole|WindowsTerminal|powershell|matlab|MATLAB)$') { "$name($wpid)" }
    })
}

$AllStarted = New-Object System.Collections.Generic.List[int]
function Remember($St) { foreach ($p in (JobPids $St)) { $AllStarted.Add($p) } }

try {
    # ------------------------------------------------------------ setup
    Section 'setup'
    New-Item -ItemType Directory -Path $T -Force | Out-Null
    Git $T @('init', '-q', '--bare', $Remote) | Out-Null
    Git $T @('clone', '-q', $Remote, $Senpai) | Out-Null
    Copy-Item $RepoGitignore (Join-Path $Senpai '.gitignore')
    Push-Files @{
        'src/ok_job.m' = "disp('hello');`n"
        'src/readme.txt' = "not MATLAB`n"
        'src/bad-name.m' = "disp(1);`n"
        'src/real_check.m' = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'real_check.m') -Raw)
        'jobs/README.md' = "jobs`n"
    } 'initial'
    Git $T @('clone', '-q', $Remote, $Lab) | Out-Null
    Write-Utf8 (Join-Path $T 'outside.m') "disp(1);`n"
    Check 'fake matlab exists' (Test-Path $Fake)
    Check 'lab clone is clean' ((Git $Lab @('status', '--porcelain')) -eq '')

    # ------------------------------------------------------------ 1. finished / failed / one at a time / id order
    Section 'finished, failed, one job at a time, id order, independent + hidden + BelowNormal'
    Push-Files @{
        'jobs/20260101_b_fail.json' = (JobJson '20260101_b_fail' -Vars ([ordered]@{ FAKE_SECONDS = 2; FAKE_EXIT = 3 }))
        'jobs/20260101_a_ok.json'   = (JobJson '20260101_a_ok' -Vars ([ordered]@{ FAKE_SECONDS = 30 }))
    } 'two jobs'
    $before = VisibleWindows
    Tick
    $a = Status '20260101_a_ok'; Remember $a
    Check 'smallest id (a) started first' ($a -and $a.state -eq 'running') ($a | ConvertTo-Json -Compress)
    Check 'b not started at the same time' ($null -eq (Status '20260101_b_fail'))
    Check 'MATLAB pid recorded' ($a.matlabPid -gt 0 -and @($a.matlabProcesses).Count -ge 1) "$($a | ConvertTo-Json -Compress)`n$(RunnerLog)"
    Check 'wrapper/MATLAB keep running after the runner process exited' (AnyAlive (JobPids $a))
    $mp = Get-Process -Id $a.matlabPid -ErrorAction SilentlyContinue
    Check 'MATLAB priority is BelowNormal' ($mp -and "$($mp.PriorityClass)" -eq 'BelowNormal') "$($mp.PriorityClass)"
    $wpp = Get-CimInstance Win32_Process -Filter "ProcessId=$($a.matlabPid)"
    Check 'MATLAB is a child of the cmd wrapper' ($wpp.ParentProcessId -eq $a.wrapperPid)
    Start-Sleep -Seconds 2
    $sus = SuspiciousNewWindows $before (JobPids $a)
    Check 'no visible window for the started processes' ($sus.Count -eq 0) ($sus -join ', ')
    $hw = @(JobPids $a | ForEach-Object { (Get-Process -Id $_ -ErrorAction SilentlyContinue).MainWindowHandle } | Where-Object { $_ -and $_ -ne [IntPtr]::Zero })
    Check 'started processes have no main window' ($hw.Count -eq 0)
    $hb = Heartbeat
    Check 'heartbeat: running job, pending count, HEAD' ($hb.runningJob -eq '20260101_a_ok' -and $hb.pendingJobs -eq 1 -and $hb.head.Length -eq 40) ($hb | ConvertTo-Json -Compress)

    Tick
    Check 'while a runs, the next tick does not start b' ($null -eq (Status '20260101_b_fail'))
    Check 'a still running' ((Status '20260101_a_ok').state -eq 'running')

    Check 'a exits' (Wait-JobGone '20260101_a_ok')
    Tick
    $a = Status '20260101_a_ok'
    Check 'a -> finished (exit 0)' ($a.state -eq 'finished' -and $a.exitCode -eq 0) ($a | ConvertTo-Json -Compress)
    $b = Status '20260101_b_fail'; Remember $b
    Check 'then b starts' ($b.state -eq 'running')
    $out = Get-Content -LiteralPath (Join-Path $Lab 'results\jobs\20260101_a_ok\fake_output.txt') -Raw
    Check 'MATLAB_MAX_WORKERS=6 reaches MATLAB' ($out -match 'MATLAB_MAX_WORKERS=6')
    Check 'MATLAB runs in the repo root' ($out -match [regex]::Escape("cwd=$Lab"))
    $main = Get-Content -LiteralPath (Join-Path $Lab 'results\jobs\20260101_a_ok\job_main.m')
    Check 'job_main.m starts with maxNumCompThreads(6)' ($main[1] -eq 'maxNumCompThreads(6);') ($main -join ' | ')
    Check 'job_main.m sets JOB_ID/JOB_OUT and runs the entry' (($main -join "`n") -match "JOB_ID = '20260101_a_ok'; JOB_OUT = '.*\\results\\jobs\\20260101_a_ok';" -and $main[-1] -like "run('*\src\ok_job.m');")
    Check 'exitcode.txt and matlab.log written' ((Test-Path (Join-Path $Lab 'results\jobs\20260101_a_ok\exitcode.txt')) -and (Test-Path (Join-Path $Lab 'results\jobs\20260101_a_ok\matlab.log')))

    Check 'b exits' (Wait-JobGone '20260101_b_fail')
    Tick
    $b = Status '20260101_b_fail'
    Check 'b -> failed (exit 3)' ($b.state -eq 'failed' -and $b.exitCode -eq 3) ($b | ConvertTo-Json -Compress)
    $aStart = (Status '20260101_a_ok').startTime
    Tick
    Check 'finished job is never run again' ((Status '20260101_a_ok').startTime -eq $aStart -and (Status '20260101_a_ok').state -eq 'finished')
    Check 'heartbeat: nothing pending, nothing running' ((Heartbeat).pendingJobs -eq 0 -and $null -eq (Heartbeat).runningJob)

    # ------------------------------------------------------------ 2. cancel
    Section '.cancel'
    Push-Files @{
        'jobs/20260102_c_cancel.json' = (JobJson '20260102_c_cancel')
        'jobs/20260102_c_cancel.cancel' = ''
        'jobs/20260102_d_ok.json' = (JobJson '20260102_d_ok' -Vars ([ordered]@{ FAKE_SECONDS = 1 }))
    } 'cancel'
    Tick
    Check 'cancelled job -> cancelled' ((Status '20260102_c_cancel').state -eq 'cancelled')
    $d = Status '20260102_d_ok'; Remember $d
    Check 'the next job starts in the same tick' ($d.state -eq 'running')
    Check 'd exits' (Wait-JobGone '20260102_d_ok')
    Tick
    Check 'd -> finished' ((Status '20260102_d_ok').state -eq 'finished')

    # ------------------------------------------------------------ 3. stop (launcher + body)
    Section '.stop (launcher -> body process tree)'
    Push-Files @{ 'jobs/20260103_s_stop.json' = (JobJson '20260103_s_stop' -Vars ([ordered]@{ FAKE_SECONDS = 120; FAKE_CHILD = $true })) } 'stop'
    Tick
    $s = Status '20260103_s_stop'; Remember $s
    $procs = @($s.matlabProcesses)
    Check 'launcher and body both recorded' ($procs.Count -eq 2) ($procs | ConvertTo-Json -Compress)
    $body = $procs | Where-Object { $_.parentPid -ne $s.wrapperPid } | Select-Object -First 1
    Check 'matlabPid = body' ($body -and $s.matlabPid -eq $body.pid)
    $bp = if ($body) { Get-Process -Id $body.pid -ErrorAction SilentlyContinue }
    Check 'body priority is BelowNormal' ($bp -and "$($bp.PriorityClass)" -eq 'BelowNormal')
    Tick
    Check 'still running without .stop' ((Status '20260103_s_stop').state -eq 'running')
    Push-Files @{ 'jobs/20260103_s_stop.stop' = '' } 'stop it'
    Tick
    Check 'stopped job -> stopped' ((Status '20260103_s_stop').state -eq 'stopped')
    Start-Sleep -Seconds 1
    Check 'all its processes are gone' (-not (AnyAlive (JobPids $s)))

    # ------------------------------------------------------------ 4. lost
    Section 'lost'
    Push-Files @{ 'jobs/20260104_l_lost.json' = (JobJson '20260104_l_lost' -Vars ([ordered]@{ FAKE_SECONDS = 120 })) } 'lost'
    Tick
    $l = Status '20260104_l_lost'; Remember $l
    Check 'lost job running' ($l.state -eq 'running')
    foreach ($p in (JobPids $l)) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    Tick
    Check 'killed outside the runner without exitcode.txt -> lost' ((Status '20260104_l_lost').state -eq 'lost')

    # ------------------------------------------------------------ 5. rejected + escaping
    Section 'rejected jobs, vars escaping'
    $outsideM = (Join-Path $T 'outside.m')
    $jp = -join ([char[]]@(0x65E5, 0x672C, 0x8A9E))   # 3 Japanese characters (kept out of the source: PS 5.1 reads BOM-less files as ANSI)
    $tricky = "it's 100% `"q`" & ^ | < > ! $jp"
    Push-Files @{
        'jobs/20260105_r01.json' = (JobJson '20260105_r01' 'src/../src/ok_job.m')
        'jobs/20260105_r02.json' = (JobJson '20260105_r02' $outsideM)
        'jobs/20260105_r03.json' = (JobJson '20260105_r03' '../outside.m')
        'jobs/20260105_r04.json' = (JobJson '20260105_r04' 'src/missing.m')
        'jobs/20260105_r05.json' = (JobJson '20260105_r05' 'src/readme.txt')
        'jobs/20260105_r06.json' = (JobJson '20260105_r06' 'src/bad-name.m')
        'jobs/20260105_r07.json' = (JobJson '20260105_r07' -Vars ([ordered]@{ '1abc' = 1 }))
        'jobs/20260105_r08.json' = (JobJson '20260105_r08' -Vars ([ordered]@{ 'my-var' = 1 }))
        'jobs/20260105_r09.json' = (JobJson '20260105_r09' -Vars ([ordered]@{ 'end' = 1 }))
        'jobs/20260105_r10.json' = (JobJson '20260105_r10' -Vars ([ordered]@{ 'JOB_OUT' = 'x' }))
        'jobs/20260105_r11.json' = (JobJson '20260105_r11' -Vars ([ordered]@{ s = "line1`nline2" }))
        'jobs/20260105_r12.json' = (JobJson '20260105_r12' -Vars ([ordered]@{ a = @(@(1, 2), @(3, 4)) }))
        'jobs/20260105_r13.json' = (JobJson '20260105_r13' -Vars ([ordered]@{ a = @(1, 'x') }))
        'jobs/20260105_r14.json' = '{"id": "20260105_r14", "entry": "src/ok_job.m", "vars": {"a": null}}'
        'jobs/20260105_r15.json' = '{"id": "20260105_r15", "entry": "src/ok_job.m", "vars": {"a": {"b": 1}}}'
        'jobs/20260105_r16.json' = (JobJson '20260105_r16' -IdField 'other_id')
        'jobs/20260105_r17.json' = '{"id": "20260105_r17", "entry": '
        'jobs/20260105_r18.json' = (JobJson '20260105_r18' -Vars ([ordered]@{ p = 'results/jobs/x.mat' }))
        'jobs/20260105_r19.json' = (JobJson '20260105_r19' 'results/x.m')
        'jobs/20260105_z_escape.json' = (JobJson '20260105_z_escape' -Vars ([ordered]@{
            tag = $tricky; n = 42; x = 0.3; tiny = -3.5e-5; flag = $true; off = $false; list = @(0.8, 1, 1.2); empty = @(); FAKE_SECONDS = 1 }))
    } 'rejected'
    Tick
    $rej = 1..19 | ForEach-Object { $id = '20260105_r{0:D2}' -f $_; [pscustomobject]@{ id = $id; st = (Status $id) } }
    foreach ($r in $rej) {
        Check ("{0} rejected: {1}" -f $r.id, $r.st.reason) ($r.st.state -eq 'rejected' -and $r.st.reason) ($r.st | ConvertTo-Json -Compress)
    }
    $z = Status '20260105_z_escape'; Remember $z
    Check 'valid job after the rejected ones starts in the same tick' ($z.state -eq 'running')
    $zm = [IO.File]::ReadAllText((Join-Path $Lab 'results\jobs\20260105_z_escape\job_main.m'), $Utf8)
    $expect = @(
        "tag = 'it''s 100% `"q`" & ^ | < > ! $jp';", 'n = 42;', 'x = 0.3;', 'tiny = -3.5E-05;', 'flag = true;', 'off = false;',
        'list = [0.8, 1, 1.2];', 'empty = [];')
    foreach ($e in $expect) { Check "job_main.m has: $e" ($zm.Contains($e)) }
    Check 'z exits' (Wait-JobGone '20260105_z_escape')
    Tick
    Check 'z -> finished' ((Status '20260105_z_escape').state -eq 'finished')

    # ------------------------------------------------------------ 6. dirty working tree
    Section 'dirty working tree'
    $headBefore = Git $Lab @('rev-parse', 'HEAD')
    Write-Utf8 (Join-Path $Lab 'src\written_by_matlab.mat') 'x'
    Push-Files @{ 'jobs/20260106_dirty.json' = (JobJson '20260106_dirty' -Vars ([ordered]@{ FAKE_SECONDS = 1 })) } 'dirty'
    Tick
    Check 'no pull while dirty' ((Git $Lab @('rev-parse', 'HEAD')) -eq $headBefore)
    Check 'no job started while dirty' ($null -eq (Status '20260106_dirty'))
    Check 'dirty tree is logged' ((RunnerLog) -match 'working tree not clean')
    Check 'heartbeat shows the error' ((Heartbeat).thisRun -eq 'working tree not clean' -and (Heartbeat).lastError.message -match 'not clean')
    Remove-Item (Join-Path $Lab 'src\written_by_matlab.mat')
    Tick
    $dj = Status '20260106_dirty'; Remember $dj
    Check 'after cleaning: pulled and started' ($dj.state -eq 'running' -and (Git $Lab @('rev-parse', 'HEAD')) -ne $headBefore)
    Check 'dirty job exits' (Wait-JobGone '20260106_dirty')
    Tick
    Check 'heartbeat keeps the last error, this run ok' ((Heartbeat).thisRun -eq 'ok' -and (Heartbeat).lastError.message -match 'not clean')

    # ------------------------------------------------------------ 7. lock, missing MATLAB, log rotation
    Section 'lock, missing MATLAB, log rotation'
    Push-Files @{ 'jobs/20260107_lock.json' = (JobJson '20260107_lock' -Vars ([ordered]@{ FAKE_SECONDS = 1 })) } 'lock'
    $lockPath = Join-Path $Lab 'results\jobs\runner.lock'
    $me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
    Write-Utf8 $lockPath (@{ pid = $PID; created = ([datetime]$me.CreationDate).ToString('o'); time = 'x' } | ConvertTo-Json -Compress)
    Tick
    Check 'live lock: runner does nothing' ($null -eq (Status '20260107_lock') -and (Test-Path $lockPath))
    Write-Utf8 $lockPath (@{ pid = $PID; created = '2000-01-01T00:00:00.0000000+09:00'; time = 'x' } | ConvertTo-Json -Compress)
    Tick -Matlab (Join-Path $T 'no_such_matlab.exe')
    Check 'stale lock (PID reused) is removed' (-not (Test-Path $lockPath))
    Check 'missing MATLAB: job not consumed, error recorded' ($null -eq (Status '20260107_lock') -and (Heartbeat).lastError.message -match 'MATLAB not found')
    $logPath = Join-Path $Lab 'results\jobs\runner.log'
    [IO.File]::AppendAllText($logPath, ('x' * 1100000))
    Tick
    $lk = Status '20260107_lock'; Remember $lk
    Check 'then the job starts' ($lk.state -eq 'running')
    Check 'runner.log rotated to runner.log.1 at 1 MB' ((Test-Path "$logPath.1") -and (Get-Item $logPath).Length -lt 100000)
    Check 'lock released after each run' (-not (Test-Path $lockPath))
    [void](Wait-JobGone '20260107_lock')
    Tick
    Check 'lab working tree stayed clean (all output under results/)' ((Git $Lab @('status', '--porcelain')) -eq '')

    # ------------------------------------------------------------ 8. real MATLAB (optional)
    if ($RealMatlab) {
        Section "real MATLAB: $RealMatlab"
        $rd = Join-Path $T 'real'; New-Item -ItemType Directory $rd -Force | Out-Null
        foreach ($case in @(@{ n = 'ok'; code = 'disp(version); exit(0)'; want = 'zero' }, @{ n = 'err'; code = "error('x')"; want = 'nonzero' })) {
            $cmdFile = Join-Path $rd "$($case.n).cmd"; $codeFile = Join-Path $rd "$($case.n).txt"
            [IO.File]::WriteAllText($cmdFile, ("@echo off`r`n`"$RealMatlab`" -batch `"$($case.code)`" -logfile `"$rd\$($case.n).log`"`r`n>`"$codeFile`" echo %ERRORLEVEL%`r`n"), [Text.Encoding]::ASCII)
            $p = Start-Process -FilePath $env:ComSpec -ArgumentList '/d', '/c', "`"$cmdFile`"" -WindowStyle Hidden -Wait -PassThru
            $ec = (Get-Content $codeFile -Raw).Trim()
            Check ("-batch `"{0}`" -> exit code {1} ({2})" -f $case.code, $ec, $case.want) ($(if ($case.want -eq 'zero') { $ec -eq '0' } else { $ec -ne '0' -and $ec -ne '' }))
        }
        Push-Files @{
            'jobs/20260201_real_ok.json' = (JobJson '20260201_real_ok' 'src/real_check.m' ([ordered]@{ tag = $tricky; list = @(0.8, 1, 1.2); flag = $true; n = 42 }))
            'jobs/20260201_real_xerr.json' = (JobJson '20260201_real_xerr' 'src/real_check.m' ([ordered]@{ make_error = $true }))
        } 'real'
        foreach ($id in '20260201_real_ok', '20260201_real_xerr') {
            Tick -Matlab $RealMatlab
            $st = Status $id; Remember $st
            Write-Host ("  processes: " + ((@($st.matlabProcesses) | ForEach-Object { "$($_.name):$($_.pid) parent=$($_.parentPid) belowNormal=$($_.belowNormal)" }) -join '; '))
            Check "$id running with real MATLAB" ($st.state -eq 'running')
            Check "$id exits within 5 min" (Wait-JobGone $id 300)
            Tick -Matlab $RealMatlab
        }
        $ok = Status '20260201_real_ok'
        Check 'real ok job -> finished' ($ok.state -eq 'finished') ($ok | ConvertTo-Json -Compress)
        $res = Join-Path $Lab 'results\jobs\20260201_real_ok\check.txt'
        $txt = if (Test-Path $res) { [IO.File]::ReadAllText($res, $Utf8) } else { '' }
        Write-Host $txt
        Check 'maxNumCompThreads = 6 inside the job' ($txt -match '(?m)^threads=6\r?$')
        Check 'MATLAB_MAX_WORKERS = 6 inside the job' ($txt -match '(?m)^max_workers=6\r?$')
        Check 'Simulink cache folder = JOB_OUT\slprj' ($txt.Contains("cache=$Lab\results\jobs\20260201_real_ok\slprj"))
        Check 'a Simulink model was simulated' ($txt -match '(?m)^sim=ok 1\r?$')
        Check 'no slprj/.slxc in the git-tracked folders' (@(Get-ChildItem $Lab -Recurse -Force -Include slprj, *.slxc -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "$Lab\results\*" }).Count -eq 0)
        Check 'string var arrives unchanged (quotes, %, ^, !, Japanese)' ($txt.Contains("tag=$tricky"))
        Check 'number array var' ($txt -match '(?m)^list=0\.8 1 1\.2\r?$')
        Check 'logical var' ($txt -match '(?m)^flag=1 logical\r?$')
        Check 'pwd is inside the repo' ($txt.Contains("pwd=$Lab"))
        $er = Status '20260201_real_xerr'
        Check 'real error job -> failed' ($er.state -eq 'failed' -and $er.exitCode -ne 0) ($er | ConvertTo-Json -Compress)
        $elog = Get-Content (Join-Path $Lab 'results\jobs\20260201_real_xerr\matlab.log') -Raw
        Check 'the error is in matlab.log' ($elog -match 'intentional test error')
        Check 'lab working tree stayed clean after real MATLAB' ((Git $Lab @('status', '--porcelain')) -eq '')
    }
}
catch {
    Check 'test script ran without exceptions' $false ("{0} {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage)
}
finally {
    Section 'cleanup'
    foreach ($p in ($AllStarted | Select-Object -Unique)) {
        $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
        # only processes this test started (fake/real MATLAB, its cmd wrapper)
        if ($proc -and $proc.ProcessName -match '^(cmd|powershell|matlab|MATLAB)$') { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue; Write-Host "  stopped leftover $($proc.ProcessName) $p" }
    }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ("  temp folder removed: {0}" -f (-not (Test-Path $T)))
    Write-Host ("`nRESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
    foreach ($f in $script:Failed) { Write-Host "  failed: $f" -ForegroundColor Red }
}
exit $script:Fail
