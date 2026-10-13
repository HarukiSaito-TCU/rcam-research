<#
 MatlabJobRunner: one tick of the lab-PC job runner (Windows PowerShell 5.1 only, no other runtime).
 Started every 5 minutes by the scheduled task "MatlabJobRunner" (see lab\install_task.ps1). Each run:
   lock -> clean-tree check -> git pull --ff-only -> check the running job -> start at most one new job -> heartbeat.
 MATLAB is started through WMI as an independent, hidden, BelowNormal process; the runner itself exits at once.
 Everything it writes goes under <repo>\results\ (git-ignored). Always exits 0.

   powershell -NoProfile -ExecutionPolicy Bypass -File lab\MatlabJobRunner.ps1 [-MatlabExe <path>] [-GitExe <path>] [-RepoRoot <path>]

 MatlabExe / GitExe default to lab\config.json ("matlabExe", "gitExe"); GitExe falls back to "git" on PATH.
 Dot-sourcing this file (". .\MatlabJobRunner.ps1") only defines the functions (used by the tests).
#>
param(
    [string]$MatlabExe,
    [string]$GitExe,
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

$script:MaxThreads = 6           # maxNumCompThreads(6), MATLAB_MAX_WORKERS=6
$script:LockStaleMinutes = 30
$script:LogMaxBytes = 1MB
$script:IdPattern = '^[A-Za-z0-9_-]+$'
$script:VarPattern = '^[A-Za-z][A-Za-z0-9_]*$'
$script:MatlabKeywords = @('break', 'case', 'catch', 'classdef', 'continue', 'else', 'elseif', 'end', 'for', 'function',
    'global', 'if', 'otherwise', 'parfor', 'persistent', 'return', 'spmd', 'switch', 'try', 'while')
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$script:BelowNormal = 16384       # BELOW_NORMAL_PRIORITY_CLASS (Win32_ProcessStartup.PriorityClass)

# ---------------------------------------------------------------- small helpers

function Get-Now { (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }

function Write-TextFile([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Write-JsonFile([string]$Path, $Object) {
    # write to a temp file and move, so a reader never sees half a file
    $tmp = "$Path.tmp"
    Write-TextFile $tmp ($Object | ConvertTo-Json -Depth 6)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-JsonFile([string]$Path) {
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Log([string]$Message) {
    $line = '{0} [{1}] {2}' -f (Get-Now), $PID, $Message
    try {
        if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt $script:LogMaxBytes) {
            Move-Item -LiteralPath $script:LogPath -Destination "$($script:LogPath).1" -Force
        }
        [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", $script:Utf8NoBom)
    } catch { }
}

function Set-LastError([string]$Message) {
    $script:LastError = [ordered]@{ time = (Get-Now); message = $Message }
    Write-Log "ERROR: $Message"
}

# ---------------------------------------------------------------- processes

function ConvertTo-TimeString($DateTime) { if ($DateTime) { ([datetime]$DateTime).ToString('o') } else { $null } }

function Get-ProcessInfo([int]$ProcessId) {
    Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
}

# Alive = a process with this PID exists AND it is the same process (creation time matches; PIDs get reused).
function Test-ProcessAlive([int]$ProcessId, [string]$Created) {
    if ($ProcessId -le 0) { return $false }
    $p = Get-ProcessInfo $ProcessId
    if (-not $p) { return $false }
    if (-not $Created) { return $true }
    $diff = ([datetime]$p.CreationDate - [datetime]::Parse($Created, $null, 'RoundtripKind')).TotalSeconds
    return ([math]::Abs($diff) -lt 1)
}

function Get-ChildProcessInfo([int]$ParentId) {
    @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$ParentId" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'conhost.exe' -and $_.Name -ne 'OpenConsole.exe' })
}

function Set-BelowNormal([int]$ProcessId) {
    try { (Get-Process -Id $ProcessId -ErrorAction Stop).PriorityClass = 'BelowNormal'; return $true } catch { return $false }
}

# Children and grandchildren of the wrapper (matlab.exe launcher -> MATLAB.exe body), recorded with creation time.
function Update-JobProcesses($Status, [int]$WaitSeconds) {
    $known = @{}
    foreach ($m in @($Status.matlabProcesses)) { if ($m) { $known[[int]$m.pid] = $m } }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $childSeen = $null
    do {
        $wrapperAlive = Test-ProcessAlive $Status.wrapperPid $Status.wrapperCreated
        if ($wrapperAlive) {
            foreach ($c in Get-ChildProcessInfo $Status.wrapperPid) {
                $level = @(@{ p = $c; parent = [int]$Status.wrapperPid })
                $level += @(Get-ChildProcessInfo $c.ProcessId | ForEach-Object { @{ p = $_; parent = [int]$c.ProcessId } })
                foreach ($e in $level) {
                    $p = $e.p
                    if (-not $known.ContainsKey([int]$p.ProcessId)) {
                        $known[[int]$p.ProcessId] = [pscustomobject][ordered]@{
                            pid = [int]$p.ProcessId; name = $p.Name; parentPid = $e.parent
                            created = (ConvertTo-TimeString $p.CreationDate)
                            belowNormal = (Set-BelowNormal $p.ProcessId)
                        }
                    }
                }
            }
        }
        # wait for the launcher, then up to 3 s for a body under it (later ticks pick up a body that comes later)
        $haveBody = @($known.Values | Where-Object { $_.parentPid -ne [int]$Status.wrapperPid }).Count -gt 0
        if (-not $childSeen -and $known.Count) { $childSeen = Get-Date }
        if (-not $wrapperAlive -or $haveBody -or (Get-Date) -ge $deadline) { break }
        if ($childSeen -and ((Get-Date) - $childSeen).TotalSeconds -ge 3) { break }
        Start-Sleep -Milliseconds 250
    } while ($true)
    $Status.matlabProcesses = @($known.Values | Sort-Object pid)
    $Status.matlabPid = $null
    $body = @($Status.matlabProcesses | Where-Object { $_.parentPid -ne [int]$Status.wrapperPid } | Select-Object -First 1)
    $first = @($Status.matlabProcesses | Select-Object -First 1)
    if ($body.Count) { $Status.matlabPid = $body[0].pid } elseif ($first.Count) { $Status.matlabPid = $first[0].pid }
}

function Test-JobAlive($Status) {
    if (Test-ProcessAlive $Status.wrapperPid $Status.wrapperCreated) { return $true }
    foreach ($m in @($Status.matlabProcesses)) { if ($m -and (Test-ProcessAlive $m.pid $m.created)) { return $true } }
    return $false
}

# Stop only the processes this runner started (identified by PID + creation time). Never by name.
function Stop-JobProcesses($Status) {
    $targets = @(@{ pid = $Status.wrapperPid; created = $Status.wrapperCreated }) +
        @(@($Status.matlabProcesses) | Where-Object { $_ } | ForEach-Object { @{ pid = $_.pid; created = $_.created } })
    foreach ($t in $targets) {
        if (Test-ProcessAlive $t.pid $t.created) {
            $old = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { $out = & taskkill.exe /PID $t.pid /T /F 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $old }
            Write-Log ("taskkill /PID {0} /T /F -> {1}" -f $t.pid, ((@($out) -join ' ') -replace '\s+', ' '))
        }
    }
}

# ---------------------------------------------------------------- git

function Invoke-Git([string[]]$GitArgs) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $script:Git -C $script:Root @GitArgs 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    [pscustomobject]@{ Code = $code; Output = (@($out) -join "`n").Trim() }
}

# ---------------------------------------------------------------- lock

function Enter-RunnerLock([string]$Path) {
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            # FileShare.Read: others may read who holds it, but cannot delete it while we run
            $fs = [System.IO.File]::Open($Path, 'CreateNew', 'Write', 'Read')
            $me = Get-ProcessInfo $PID
            $info = [ordered]@{ pid = $PID; created = (ConvertTo-TimeString $me.CreationDate); time = (Get-Now) }
            $bytes = $script:Utf8NoBom.GetBytes(($info | ConvertTo-Json -Compress))
            $fs.Write($bytes, 0, $bytes.Length); $fs.Flush()
            return $fs
        } catch {
            if ($attempt -gt 0 -or -not (Test-Path -LiteralPath $Path)) { return $null }
            if (-not (Test-LockStale $Path)) { return $null }
            try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { return $null }
            Write-Log "removed stale lock $Path"
        }
    }
    return $null
}

function Test-LockStale([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $true }
    if (((Get-Date) - $item.LastWriteTime).TotalMinutes -ge $script:LockStaleMinutes) { return $true }
    try { $info = Read-JsonFile $Path } catch { return $false }   # being written right now: not stale
    if (-not $info -or -not $info.pid) { return $false }
    return -not (Test-ProcessAlive ([int]$info.pid) $info.created)
}

function Exit-RunnerLock($Stream, [string]$Path) {
    if ($Stream) {
        $Stream.Dispose()
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------- job validation

function Test-IsNumber($Value) {
    ($Value -is [int]) -or ($Value -is [long]) -or ($Value -is [double]) -or ($Value -is [decimal]) -or
    ($Value -is [single]) -or ($Value -is [int16]) -or ($Value -is [byte])
}

function Format-MatlabNumber($Value) {
    if ($Value -is [double] -or $Value -is [single]) { return ([double]$Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
    return [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
}

# JSON value -> MATLAB literal. Allowed: number, string, true/false, array of numbers. Throws with a reason otherwise.
function ConvertTo-MatlabLiteral($Value) {
    if ($null -eq $Value) { throw 'null is not allowed' }
    if ($Value -is [string]) {
        if ($Value -match '[\x00-\x1F\x7F]') { throw 'strings must not contain control characters (newline, tab, ...)' }
        if ($Value -match '(^|[\\/])results[\\/]') { throw 'do not pass results/ paths in vars; write to JOB_OUT' }
        return "'" + $Value.Replace("'", "''") + "'"
    }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if (Test-IsNumber $Value) { return Format-MatlabNumber $Value }
    if ($Value -is [System.Array]) {
        $items = foreach ($e in $Value) {
            if (($e -is [bool]) -or -not (Test-IsNumber $e)) { throw 'arrays may contain numbers only' }
            Format-MatlabNumber $e
        }
        return '[' + (@($items) -join ', ') + ']'
    }
    throw ('type {0} is not allowed (use number, string, true/false, or an array of numbers)' -f $Value.GetType().Name)
}

# Returns @{ Ok; Reason; Id; Entry (relative); EntryFull; VarLines }.
function Test-JobFile([string]$Path, [string]$Root) {
    $r = @{ Ok = $false; Reason = $null; Id = [IO.Path]::GetFileNameWithoutExtension($Path); Entry = $null; EntryFull = $null; VarLines = @() }
    if ($r.Id -notmatch $script:IdPattern) { $r.Reason = "file name '$($r.Id)' must use only A-Z a-z 0-9 _ -"; return $r }
    try { $job = Read-JsonFile $Path } catch { $r.Reason = "invalid JSON: $($_.Exception.Message)"; return $r }
    if ($job -isnot [System.Management.Automation.PSCustomObject]) { $r.Reason = 'the job file must be a JSON object'; return $r }
    if ($job.id -isnot [string] -or $job.id -cne $r.Id) { $r.Reason = "id must equal the file name ('$($r.Id)')"; return $r }

    $entry = $job.entry
    if ($entry -isnot [string] -or -not $entry) { $r.Reason = 'entry is missing'; return $r }
    if ($entry.Contains('..')) { $r.Reason = "entry must not contain '..'"; return $r }
    if ([IO.Path]::IsPathRooted($entry) -or $entry.Contains(':')) { $r.Reason = 'entry must be a path relative to the repo'; return $r }
    if ($entry -notmatch '\.m$') { $r.Reason = 'entry must be a .m file'; return $r }
    $full = [IO.Path]::GetFullPath((Join-Path $Root $entry))
    if (-not $full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { $r.Reason = 'entry is outside the repo'; return $r }
    $relTop = $full.Substring($Root.Length + 1).Split('\')[0]
    if ($relTop -eq '.git' -or $relTop -eq 'results') { $r.Reason = "entry must not be under $relTop\"; return $r }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $r.Reason = "entry not found: $entry"; return $r }
    if ([IO.Path]::GetFileNameWithoutExtension($full) -notmatch $script:VarPattern) {
        $r.Reason = 'entry file name must be a valid MATLAB name (letters, digits, _; starts with a letter)'; return $r
    }

    $lines = @()
    if ($null -ne $job.vars) {
        if ($job.vars -isnot [System.Management.Automation.PSCustomObject]) { $r.Reason = 'vars must be a JSON object'; return $r }
        foreach ($p in $job.vars.PSObject.Properties) {
            $n = $p.Name
            if ($n -cnotmatch $script:VarPattern -or $n.Length -gt 63) { $r.Reason = "invalid variable name '$n'"; return $r }
            if ($script:MatlabKeywords -contains $n -or $n -ceq 'JOB_ID' -or $n -ceq 'JOB_OUT') { $r.Reason = "variable name '$n' is reserved"; return $r }
            try { $lit = ConvertTo-MatlabLiteral $p.Value } catch { $r.Reason = "vars.${n}: $($_.Exception.Message)"; return $r }
            $lines += "$n = $lit;"
        }
    }
    $r.Ok = $true; $r.Entry = $entry; $r.EntryFull = $full; $r.VarLines = $lines
    return $r
}

function Get-MatlabQuoted([string]$s) { "'" + $s.Replace("'", "''") + "'" }

# The code MATLAB runs (written to results\jobs\<id>\job_main.m).
function New-JobMainCode($Check, [string]$Root, [string]$JobOut) {
    $l = @(
        '% generated by lab\MatlabJobRunner.ps1 - do not edit'
        "maxNumCompThreads($($script:MaxThreads));"
        "cd($(Get-MatlabQuoted $Root));"
        "JOB_ID = $(Get-MatlabQuoted $Check.Id); JOB_OUT = $(Get-MatlabQuoted $JobOut);"
    ) + $Check.VarLines + @("run($(Get-MatlabQuoted $Check.EntryFull));")
    ($l -join "`r`n") + "`r`n"
}

# ---------------------------------------------------------------- job state

function Get-JobDir([string]$Id) { Join-Path $script:JobsOut $Id }

function Set-JobStatus([string]$Id, $Status) {
    $dir = Get-JobDir $Id
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Status.updated = Get-Now
    Write-JsonFile (Join-Path $dir 'status.json') $Status
}

function New-FinalStatus([string]$Id, [string]$State, [string]$Reason) {
    $s = [ordered]@{ id = $Id; state = $State; reason = $Reason; time = (Get-Now); commit = $script:Head; updated = $null }
    Set-JobStatus $Id $s
    Write-Log "job $Id -> $State$(if ($Reason) { ": $Reason" })"
}

function ConvertTo-Hashtable($Object) {
    $h = [ordered]@{}
    foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h
}

# Step 5: check the job in state "running". Returns $true if a job is still running.
function Update-RunningJobs {
    $busy = $false
    foreach ($d in @(Get-ChildItem -Path $script:JobsOut -Directory -ErrorAction SilentlyContinue)) {
        $f = Join-Path $d.FullName 'status.json'
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try { $st = Read-JsonFile $f } catch { Write-Log "cannot read ${f}: $($_.Exception.Message)"; continue }
        if ($st.state -ne 'running') { continue }
        $id = $st.id
        $s = ConvertTo-Hashtable $st
        $dir = Get-JobDir $id
        if (Test-JobAlive $s) {
            if (Test-Path -LiteralPath (Join-Path $script:Root "jobs\$id.stop")) {
                Write-Log "job ${id}: jobs\$id.stop found, stopping wrapper $($s.wrapperPid) / MATLAB $($s.matlabPid)"
                Stop-JobProcesses $s
                $s.state = 'stopped'; $s.reason = "jobs\$id.stop"; $s.endTime = Get-Now
                Set-JobStatus $id $s
                Write-Log "job $id -> stopped"
                continue
            }
            $before = @($s.matlabProcesses).Count
            Update-JobProcesses $s 0
            if (@($s.matlabProcesses).Count -ne $before) { Set-JobStatus $id $s }
            $script:RunningJob = $id
            $busy = $true
            continue
        }
        $codeFile = Join-Path $dir 'exitcode.txt'
        $code = $null
        if (Test-Path -LiteralPath $codeFile) {
            $txt = (Get-Content -LiteralPath $codeFile -Raw -ErrorAction SilentlyContinue)
            if ($txt) { $txt = $txt.Trim() }
            $n = 0
            if ([int]::TryParse($txt, [ref]$n)) { $code = $n }
        }
        $s.endTime = Get-Now
        if ($null -eq $code) {
            $s.state = 'lost'; $s.reason = 'MATLAB is gone and exitcode.txt is missing or unreadable'
        } else {
            $s.exitCode = $code
            if ($code -eq 0) { $s.state = 'finished' } else { $s.state = 'failed'; $s.reason = "exit code $code (see matlab.log)" }
        }
        Set-JobStatus $id $s
        Write-Log "job $id -> $($s.state)$(if ($null -ne $code) { " (exit code $code)" })"
    }
    return $busy
}

function Get-PendingJobs {
    $jobsDir = Join-Path $script:Root 'jobs'
    $files = [object[]]@(Get-ChildItem -Path $jobsDir -Filter *.json -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.json' -and -not (Test-Path -LiteralPath (Join-Path (Get-JobDir $_.BaseName) 'status.json')) })
    # ordinal order of the id (= file name), independent of the PC's culture settings
    $keys = [string[]]@($files | ForEach-Object { $_.BaseName })
    [Array]::Sort($keys, $files, [StringComparer]::Ordinal)
    $files
}

function Start-MatlabJob($Check) {
    $id = $Check.Id
    $dir = Get-JobDir $id
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $main = Join-Path $dir 'job_main.m'
    $wrapper = Join-Path $dir 'run_job.cmd'
    $log = Join-Path $dir 'matlab.log'
    $codeFile = Join-Path $dir 'exitcode.txt'
    Write-TextFile $main (New-JobMainCode $Check $script:Root $dir)

    # A .cmd file (not one "a & echo %ERRORLEVEL%" line: cmd would expand %ERRORLEVEL% before MATLAB runs).
    # The environment is set here because a WMI-created process does not inherit the runner's environment.
    $batchArg = "run($(Get-MatlabQuoted $main))"
    $matlabLine = '"{0}" -batch "{1}" -logfile "{2}"' -f $script:Matlab, $batchArg, $log
    if ($script:Matlab -match '\.(cmd|bat)$') { $matlabLine = 'call ' + $matlabLine }   # the tests' fake matlab
    $cmdText = @(
        '@echo off'
        "set `"MATLAB_MAX_WORKERS=$($script:MaxThreads)`""
        $matlabLine.Replace('%', '%%')
        ('>"{0}" echo %ERRORLEVEL%' -f $codeFile.Replace('%', '%%'))
    ) -join "`r`n"
    [System.IO.File]::WriteAllText($wrapper, $cmdText + "`r`n", [System.Text.Encoding]::ASCII)
    $commandLine = '"{0}" /d /c "{1}"' -f $env:ComSpec, $wrapper

    # status first: if anything below dies half-way, the job is never started twice (it becomes "lost")
    $s = [ordered]@{
        id = $id; state = 'running'; reason = $null; entry = $Check.Entry; commit = $script:Head
        startTime = (Get-Now); endTime = $null; exitCode = $null
        wrapperPid = 0; wrapperCreated = $null; matlabPid = $null; matlabProcesses = @()
        command = $commandLine; matlabCommand = $matlabLine; updated = $null
    }
    Set-JobStatus $id $s

    $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0; PriorityClass = [uint32]$script:BelowNormal }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $commandLine; CurrentDirectory = $script:Root; ProcessStartupInformation = $si }
    if ($r.ReturnValue -ne 0) {
        $s.state = 'failed'; $s.reason = "Win32_Process.Create returned $($r.ReturnValue)"; $s.endTime = Get-Now
        Set-JobStatus $id $s
        Set-LastError "job ${id}: could not start ($($s.reason))"
        return
    }
    $s.wrapperPid = [int]$r.ProcessId
    $wp = Get-ProcessInfo $s.wrapperPid
    if ($wp) { $s.wrapperCreated = ConvertTo-TimeString $wp.CreationDate }
    [void](Set-BelowNormal $s.wrapperPid)
    Update-JobProcesses $s 15
    Set-JobStatus $id $s
    $script:RunningJob = $id
    Write-Log "job $id started: wrapper $($s.wrapperPid), MATLAB $($s.matlabPid) ($((@($s.matlabProcesses) | ForEach-Object { "$($_.name):$($_.pid)" }) -join ', '))"
}

# Step 6: start the pending job with the smallest id (cancelled / rejected ones are skipped).
function Start-NextJob {
    foreach ($f in Get-PendingJobs) {
        $id = $f.BaseName
        foreach ($mark in 'cancel', 'stop') {
            if (Test-Path -LiteralPath (Join-Path $script:Root "jobs\$id.$mark")) {
                New-FinalStatus $id 'cancelled' "jobs\$id.$mark (not started)"
                $id = $null; break
            }
        }
        if (-not $id) { continue }
        $check = Test-JobFile $f.FullName $script:Root
        if (-not $check.Ok) { New-FinalStatus $id 'rejected' $check.Reason; continue }
        Start-MatlabJob $check
        return
    }
}

function Write-Heartbeat {
    $hbPath = Join-Path $script:JobsOut 'runner_heartbeat.json'
    $last = $script:LastError
    if (-not $last -and (Test-Path -LiteralPath $hbPath)) {
        try { $last = (Read-JsonFile $hbPath).lastError } catch { }
    }
    $hb = [ordered]@{
        time = (Get-Now); host = $env:COMPUTERNAME; head = $script:Head
        pendingJobs = @(Get-PendingJobs).Count; runningJob = $script:RunningJob
        thisRun = $script:Outcome; lastError = $last
    }
    try { Write-JsonFile $hbPath $hb } catch { Write-Log "cannot write heartbeat: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- main

function Get-RunnerConfig([string]$Root) {
    $p = Join-Path $Root 'lab\config.json'
    if (Test-Path -LiteralPath $p) { return Read-JsonFile $p }
    return [pscustomobject]@{}
}

function Invoke-Runner {
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
    $script:Root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
    $script:JobsOut = Join-Path $script:Root 'results\jobs'
    $script:LogPath = Join-Path $script:JobsOut 'runner.log'
    $script:Head = $null; $script:RunningJob = $null; $script:LastError = $null; $script:Outcome = 'ok'
    New-Item -ItemType Directory -Path $script:JobsOut -Force | Out-Null

    $lockPath = Join-Path $script:JobsOut 'runner.lock'
    $lock = Enter-RunnerLock $lockPath
    if (-not $lock) { return }   # another runner is active
    try {
        $env:GIT_TERMINAL_PROMPT = '0'
        $cfg = Get-RunnerConfig $script:Root
        $script:Git = if ($GitExe) { $GitExe } elseif ($cfg.gitExe) { $cfg.gitExe } else { 'git' }
        $script:Matlab = if ($MatlabExe) { $MatlabExe } else { $cfg.matlabExe }

        $st = Invoke-Git @('status', '--porcelain')
        if ($st.Code -ne 0) { $script:Outcome = 'git status failed'; Set-LastError "git status failed: $($st.Output)"; return }
        if ($st.Output) {
            $script:Outcome = 'working tree not clean'
            Set-LastError ("working tree not clean - no pull, no new job. Something wrote into git-tracked folders " +
                "(write outputs under results/ only):`n$($st.Output)")
            return
        }
        $pull = Invoke-Git @('pull', '--ff-only')
        if ($pull.Code -ne 0) { $script:Outcome = 'git pull failed'; Set-LastError "git pull --ff-only failed: $($pull.Output)"; return }
        $script:Head = (Invoke-Git @('rev-parse', 'HEAD')).Output

        if (Update-RunningJobs) { return }
        if (-not @(Get-PendingJobs).Count) { return }
        if (-not $script:Matlab -or -not (Test-Path -LiteralPath $script:Matlab -PathType Leaf)) {
            $script:Outcome = 'MATLAB not found'
            Set-LastError "MATLAB not found ('$($script:Matlab)'). Set matlabExe in lab\config.json."
            return
        }
        if ($script:Root -match '[^\x20-\x7E]') { $script:Outcome = 'non-ASCII repo path'; Set-LastError "the repo path must be ASCII: $($script:Root)"; return }
        Start-NextJob
    } catch {
        $script:Outcome = 'exception'
        Set-LastError ("unexpected: {0} at {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage)
    } finally {
        try { Write-Heartbeat } catch { }
        Exit-RunnerLock $lock $lockPath
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-Runner } catch { }
    exit 0
}
