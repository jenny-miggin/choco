# Reproduces chocolatey/choco#3902 on Windows: GetProcessTree / NuGet user-agent path.
# Exits 0 if every run completes and logs "Process Tree:"; exits 1 on timeout or missing log line.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ChocoExe,

    [int]$TimeoutSeconds = 90,

    [int]$Iterations = 3
)

$ErrorActionPreference = 'Stop'

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "========== $Title =========="
}

function Get-ParentProcessChain {
    param([int]$MaxDepth = 20)

    $chain = [System.Collections.Generic.List[string]]::new()
    $current = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
    $depth = 0

    while ($null -ne $current -and $depth -lt $MaxDepth) {
        $name = $current.Name
        $id = $current.ProcessId
        $ppid = $current.ParentProcessId
        $chain.Add("${name} (pid=$id, ppid=$ppid)")
        if ($ppid -eq 0) { break }
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -ErrorAction SilentlyContinue
        $depth++
    }

    return $chain
}

function Invoke-ChocoWithTimeout {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [int]$TimeoutSec
    )

    $argString = ($Arguments -join ' ')
    Write-Host "Running: `"$Exe`" $argString (timeout ${TimeoutSec}s)"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill($true) } catch { }
        return @{
            TimedOut = $true
            ExitCode = -1
            StdOut = $stdout.Result
            StdErr = $stderr.Result
        }
    }

    [void]$stdout.Wait()
    [void]$stderr.Wait()

    return @{
        TimedOut = $false
        ExitCode = $proc.ExitCode
        StdOut = $stdout.Result
        StdErr = $stderr.Result
    }
}

function Test-ProcessTreeLogged {
    param([string]$CombinedOutput)

    return ($CombinedOutput -match '(?m)^Process Tree:')
}

if (-not (Test-Path -LiteralPath $ChocoExe)) {
    Write-Error "choco.exe not found at: $ChocoExe"
    exit 2
}

Write-Section 'Environment'
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "User: $env:USERNAME"
Write-Host "Session: $(if ($env:SESSIONNAME) { $env:SESSIONNAME } else { '(empty)' })"
Write-Host "OS: $([Environment]::OSVersion.VersionString)"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
Write-Host "GITHUB_RUN_ID: $env:GITHUB_RUN_ID"
Write-Host "GITHUB_REF: $env:GITHUB_REF"
Write-Host "GITHUB_SHA: $env:GITHUB_SHA"

Write-Section 'Parent process chain (PowerShell host)'
Get-ParentProcessChain | ForEach-Object { Write-Host "  $_" }

# GetProcessTree() is invoked from NugetCommon.GetRemoteRepositories (user-agent / process tree logging).
# Commands that only touch local state may never hit that path.
# Release CI builds require --allow-unofficial-build (see CONTRIBUTING.md).
$commonArgs = @('--allow-unofficial-build', '--debug', '--verbose')

$scenarios = @(
    @{ Name = 'search'; Args = @('search', 'chocolatey') + $commonArgs },
    @{ Name = 'info'; Args = @('info', 'chocolatey') + $commonArgs },
    @{ Name = 'list'; Args = @('list') + $commonArgs }
)

$anyFailure = $false
$logRoot = Join-Path $env:RUNNER_TEMP 'repro-3902'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

for ($i = 1; $i -le $Iterations; $i++) {
    Write-Section "Iteration $i of $Iterations"

    foreach ($scenario in $scenarios) {
        $logFile = Join-Path $logRoot ("iter{0}-{1}.log" -f $i, $scenario.Name)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-ChocoWithTimeout -Exe $ChocoExe -Arguments $scenario.Args -TimeoutSec $TimeoutSeconds
        $sw.Stop()

        $combined = $result.StdOut + "`n" + $result.StdErr
        $combined | Set-Content -Path $logFile -Encoding UTF8

        $hasProcessTree = Test-ProcessTreeLogged -CombinedOutput $combined
        Write-Host "  $($scenario.Name): elapsed=$($sw.Elapsed.TotalSeconds)s exit=$($result.ExitCode) timedOut=$($result.TimedOut) processTreeLogged=$hasProcessTree"
        Write-Host "  log: $logFile"

        if ($result.TimedOut) {
            Write-Host "::error::Timed out after ${TimeoutSeconds}s on '$($scenario.Name)' (iteration $i). Possible #3902 hang before process tree enumeration completed."
            $anyFailure = $true
        }
        elseif (-not $hasProcessTree) {
            Write-Host "::warning::Completed but no 'Process Tree:' line in output for '$($scenario.Name)' (iteration $i). Check log — may have failed earlier or logging differed."
            $anyFailure = $true
        }
    }
}

Write-Section 'Summary'
if ($anyFailure) {
    Write-Host 'Result: REPRO INDICATORS PRESENT (timeout and/or missing Process Tree log). See artifacts under repro-3902.'
    exit 1
}

Write-Host 'Result: No hang detected in this run; all scenarios completed with Process Tree logged.'
exit 0
