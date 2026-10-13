<#
 Body of the fake matlab (fake_matlab.cmd) used by Test-MatlabJobRunner.ps1.
 Reads the job_main.m named in -batch "run('<...>\job_main.m')" and obeys these vars:
   FAKE_SECONDS = n;  (default 2)   FAKE_EXIT = n;  (default 0)
   FAKE_CHILD = true;  behave like a launcher: start a child "body" process and wait for it
 Writes <JOB_OUT>\fake_output.txt (MATLAB_MAX_WORKERS, current folder) and the -logfile.
#>
param([string]$batch, [string]$logfile, [int]$child = -1, [int]$code = 0)

if ($child -ge 0) { Start-Sleep -Seconds $child; exit $code }

$main = [regex]::Match($batch, "^run\('((?:[^']|'')*)'\)$").Groups[1].Value.Replace("''", "'")
$text = [IO.File]::ReadAllText($main)
function Get-Int([string]$Name, [int]$Default) {
    $m = [regex]::Match($text, "(?m)^$Name = (-?\d+);")
    if ($m.Success) { [int]$m.Groups[1].Value } else { $Default }
}
$seconds = Get-Int 'FAKE_SECONDS' 2
$exitCode = Get-Int 'FAKE_EXIT' 0
$jobOut = [regex]::Match($text, "JOB_OUT = '((?:[^']|'')*)';").Groups[1].Value.Replace("''", "'")

[IO.File]::WriteAllText((Join-Path $jobOut 'fake_output.txt'),
    "MATLAB_MAX_WORKERS=$env:MATLAB_MAX_WORKERS`r`ncwd=$((Get-Location).Path)`r`n")
if ($logfile) { [IO.File]::WriteAllText($logfile, "fake matlab: -batch $batch`r`n") }

if ($text -match '(?m)^FAKE_CHILD = true;') {
    $p = Start-Process -FilePath powershell.exe -NoNewWindow -Wait -PassThru -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-child', $seconds, '-code', $exitCode)
    exit $p.ExitCode
}
Start-Sleep -Seconds $seconds
exit $exitCode
