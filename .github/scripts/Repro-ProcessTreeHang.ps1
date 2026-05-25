# Reproduces chocolatey/choco#3902 on Windows: GetProcessTree via NugetCommon.GetRemoteRepositories.
# Exit 0 = no hang this run; exit 2 = hang reproduced (timeout); exit 1 = setup/runtime error.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ChocoExe,

    [int]$TimeoutSeconds = 90,

    # UntilHang: loop 'search' until timeout or MaxAttempts. Legacy: run Iterations x scenarios once.
    [ValidateSet('UntilHang', 'Once')]
    [string]$Mode = 'UntilHang',

    [int]$MaxAttempts = 200,

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

function Write-HangReproduced {
    param(
        [int]$Attempt,
        [string]$LogFile,
        [double]$ElapsedSeconds
    )

    $message = "#3902 HANG REPRODUCED on attempt $Attempt after ${ElapsedSeconds}s (see $LogFile)"
    Write-Host "::error::$message"
    Set-Content -Path (Join-Path $env:RUNNER_TEMP 'repro-3902/HANG-REPRODUCED.txt') -Value $message -Encoding UTF8
    if ($env:GITHUB_OUTPUT) {
        "hang_reproduced=true" >> $env:GITHUB_OUTPUT
        "hang_attempt=$Attempt" >> $env:GITHUB_OUTPUT
        "hang_log_file=$LogFile" >> $env:GITHUB_OUTPUT
    }
}

if (-not (Test-Path -LiteralPath $ChocoExe)) {
    Write-Error "choco.exe not found at: $ChocoExe"
    exit 1
}

$logRoot = Join-Path $env:RUNNER_TEMP 'repro-3902'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

Write-Section 'Environment'
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "User: $env:USERNAME"
Write-Host "Session: $(if ($env:SESSIONNAME) { $env:SESSIONNAME } else { '(empty)' })"
Write-Host "OS: $([Environment]::OSVersion.VersionString)"
Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
Write-Host "Mode: $Mode"
Write-Host "GITHUB_RUN_ID: $env:GITHUB_RUN_ID"
Write-Host "GITHUB_REF: $env:GITHUB_REF"
Write-Host "GITHUB_SHA: $env:GITHUB_SHA"

Write-Section 'Parent process chain (PowerShell host)'
Get-ParentProcessChain | ForEach-Object { Write-Host "  $_" }

# Hits GetProcessTree() via GetRemoteRepositories. Release CI builds need --allow-unofficial-build.
$searchArgs = @('search', 'chocolatey', '--allow-unofficial-build', '--debug', '--verbose')

if ($Mode -eq 'UntilHang') {
    Write-Section "UntilHang: up to $MaxAttempts search attempts (timeout ${TimeoutSeconds}s each)"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $logFile = Join-Path $logRoot ("attempt-{0:D4}-search.log" -f $attempt)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-ChocoWithTimeout -Exe $ChocoExe -Arguments $searchArgs -TimeoutSec $TimeoutSeconds
        $sw.Stop()

        $combined = $result.StdOut + "`n" + $result.StdErr
        $combined | Set-Content -Path $logFile -Encoding UTF8

        $hasProcessTree = Test-ProcessTreeLogged -CombinedOutput $combined
        Write-Host "attempt $attempt/$MaxAttempts : elapsed=$([math]::Round($sw.Elapsed.TotalSeconds, 2))s exit=$($result.ExitCode) timedOut=$($result.TimedOut) processTreeLogged=$hasProcessTree"

        if ($result.TimedOut) {
            Write-HangReproduced -Attempt $attempt -LogFile $logFile -ElapsedSeconds $sw.Elapsed.TotalSeconds
            exit 2
        }

        if (-not $hasProcessTree) {
            Write-Host "::warning::Attempt $attempt finished without 'Process Tree:' — command may have failed before enumeration (log: $logFile)"
        }

        if ($attempt % 25 -eq 0) {
            Write-Host "Progress: $attempt / $MaxAttempts attempts without hang so far."
        }
    }

    Write-Section 'Summary'
    Write-Host "Result: No hang after $MaxAttempts attempts on this build."
    if ($env:GITHUB_OUTPUT) { "hang_reproduced=false" >> $env:GITHUB_OUTPUT }
    exit 0
}

# Mode Once (smoke / legacy)
$commonArgs = @('--allow-unofficial-build', '--debug', '--verbose')
$scenarios = @(
    @{ Name = 'search'; Args = @('search', 'chocolatey') + $commonArgs },
    @{ Name = 'info'; Args = @('info', 'chocolatey') + $commonArgs }
)

$hangDetected = $false
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

        if ($result.TimedOut) {
            Write-HangReproduced -Attempt $i -LogFile $logFile -ElapsedSeconds $sw.Elapsed.TotalSeconds
            $hangDetected = $true
        }
    }
}

if ($hangDetected) { exit 2 }
Write-Host 'Result: No hang detected (Once mode).'
exit 0
