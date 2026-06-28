<#
.SYNOPSIS
  Phase 0 bring-up checklist for the LiveDSP POC.

.DESCRIPTION
  Walks through every Phase 0 item from live-audio-poc-brief.md section 6:
  Rust toolchain, Cargo project skeleton, Roland Rubix ASIO driver, physical
  wiring, signal check, and Rubix ASIO panel settings.

  Each step is run as either an automated probe (toolchain, driver registry,
  device enumeration) or an interactive prompt (physical wiring, signal). The
  script records pass / fail / skip + notes for every step and writes a
  Markdown report to ~/vault/newtones/logs/.

.PARAMETER ProjectRoot
  Repo root. Defaults to the parent of this script's directory.

.PARAMETER VaultRoot
  Vault root. Defaults to $HOME\vault\newtones.

.PARAMETER SkipInteractive
  Run only the automated probes. Useful for CI / unattended checks.

.EXAMPLE
  pwsh -File scripts\phase0-checklist.ps1
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$VaultRoot   = (Join-Path $HOME 'vault\newtones'),
    [switch]$SkipInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ProjectRoot) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir -and $MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if (-not $scriptDir) { $scriptDir = $PWD.Path }
    $ProjectRoot = Split-Path -Parent $scriptDir
}

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][ValidateSet('pass','fail','skip','info')][string]$Status,
        [string]$Detail = ''
    )
    $script:Results.Add([pscustomobject]@{
        Phase  = $Phase
        Step   = $Step
        Status = $Status
        Detail = $Detail
        Time   = (Get-Date).ToString('s')
    }) | Out-Null

    $color = switch ($Status) {
        'pass' { 'Green' }
        'fail' { 'Red' }
        'skip' { 'DarkYellow' }
        'info' { 'Cyan' }
    }
    Write-Host ("  [{0}] {1}" -f $Status.ToUpper().PadRight(4), $Step) -ForegroundColor $color
    if ($Detail) { Write-Host ("        {0}" -f $Detail) -ForegroundColor DarkGray }
}

function Read-YesNoSkip {
    param([Parameter(Mandatory)][string]$Prompt)
    if ($SkipInteractive) { return 'skip' }
    while ($true) {
        $raw = Read-Host ("{0} [y/n/s(kip)]" -f $Prompt)
        switch -Regex ($raw.Trim().ToLower()) {
            '^(y|yes)$' { return 'yes' }
            '^(n|no)$'  { return 'no' }
            '^(s|skip)$' { return 'skip' }
            default { Write-Host "    answer y, n, or s" -ForegroundColor DarkYellow }
        }
    }
}

function Confirm-Step {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Step,
        [string]$Note = ''
    )
    $answer = Read-YesNoSkip -Prompt $Step
    switch ($answer) {
        'yes'  { Add-Result -Phase $Phase -Step $Step -Status 'pass' -Detail $Note }
        'no'   {
            $reason = if ($SkipInteractive) { '' } else { Read-Host '    what blocked it?' }
            Add-Result -Phase $Phase -Step $Step -Status 'fail' -Detail $reason
        }
        'skip' { Add-Result -Phase $Phase -Step $Step -Status 'skip' -Detail $Note }
    }
}

# ---------------------------------------------------------------- Software --

function Test-RustToolchain {
    Write-Host "`n[software] Rust toolchain" -ForegroundColor White

    $rustup = Get-Command rustup -ErrorAction SilentlyContinue
    if (-not $rustup) {
        Add-Result software 'rustup on PATH' fail 'install from https://rustup.rs'
        return
    }
    Add-Result software 'rustup on PATH' pass $rustup.Source

    $rustc = Get-Command rustc -ErrorAction SilentlyContinue
    if (-not $rustc) {
        Add-Result software 'rustc on PATH' fail 'run: rustup default stable'
        return
    }
    $version = (& rustc --version) 2>$null
    Add-Result software 'rustc available' pass $version

    $defaultToolchain = (& rustup show active-toolchain) 2>$null
    if ($defaultToolchain -match '^stable') {
        Add-Result software 'stable toolchain active' pass $defaultToolchain.Trim()
    } else {
        Add-Result software 'stable toolchain active' fail ("active: {0} -- run: rustup default stable" -f $defaultToolchain)
    }

    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cargo) {
        Add-Result software 'cargo available' pass ((& cargo --version) 2>$null)
    } else {
        Add-Result software 'cargo available' fail ''
    }

    $targets = (& rustup target list --installed) 2>$null
    if ($targets -match 'x86_64-pc-windows-msvc') {
        Add-Result software 'x86_64-pc-windows-msvc target installed' pass ''
    } else {
        Add-Result software 'x86_64-pc-windows-msvc target installed' fail 'run: rustup target add x86_64-pc-windows-msvc'
    }
}

function Test-CargoProject {
    Write-Host "`n[software] Cargo project skeleton" -ForegroundColor White

    $cargoToml = Join-Path $ProjectRoot 'livedsp\Cargo.toml'
    if (Test-Path $cargoToml) {
        Add-Result software 'livedsp/Cargo.toml exists' pass $cargoToml
    } else {
        Add-Result software 'livedsp/Cargo.toml exists' fail 'create with: cargo new livedsp --bin'
        return
    }

    $expectedDirs = 'src\audio','src\dsp','src\params','src\ui'
    foreach ($d in $expectedDirs) {
        $full = Join-Path $ProjectRoot ("livedsp\{0}" -f $d)
        if (Test-Path $full) {
            Add-Result software ("module dir present: {0}" -f $d) pass ''
        } else {
            Add-Result software ("module dir present: {0}" -f $d) fail ("create: {0}" -f $full)
        }
    }
}

function Get-PersistedEnv {
    param([Parameter(Mandatory)][string]$Name)
    $val = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $val) { $val = [Environment]::GetEnvironmentVariable($Name, 'User') }
    if (-not $val) { $val = [Environment]::GetEnvironmentVariable($Name, 'Machine') }
    return $val
}

function Test-AsioBuildChain {
    Write-Host "`n[software] cpal ASIO build chain" -ForegroundColor White

    $libclangDir = Get-PersistedEnv 'LIBCLANG_PATH'
    if (-not $libclangDir) {
        Add-Result software 'LIBCLANG_PATH set' fail 'install LLVM and set LIBCLANG_PATH to its bin dir (e.g. C:\Program Files\LLVM\bin)'
    } elseif (-not (Test-Path (Join-Path $libclangDir 'libclang.dll'))) {
        Add-Result software 'LIBCLANG_PATH set' fail ("libclang.dll not found under {0}" -f $libclangDir)
    } else {
        Add-Result software 'LIBCLANG_PATH set' pass $libclangDir
    }

    $asioDir = Get-PersistedEnv 'CPAL_ASIO_DIR'
    if (-not $asioDir) {
        Add-Result software 'CPAL_ASIO_DIR set' fail 'download Steinberg ASIO SDK and set CPAL_ASIO_DIR to the SDK root'
    } elseif (-not (Test-Path (Join-Path $asioDir 'common\iasiodrv.h'))) {
        Add-Result software 'CPAL_ASIO_DIR set' fail ("common\iasiodrv.h not found under {0}" -f $asioDir)
    } else {
        Add-Result software 'CPAL_ASIO_DIR set' pass $asioDir
    }
}

# ---------------------------------------------------------------- Hardware --

function Test-RubixAsioDriver {
    Write-Host "`n[hardware] Roland Rubix ASIO driver" -ForegroundColor White

    $asioKey = 'HKLM:\SOFTWARE\ASIO'
    if (-not (Test-Path $asioKey)) {
        Add-Result hardware 'HKLM\SOFTWARE\ASIO exists' fail 'no ASIO drivers registered on this system'
        return
    }
    Add-Result hardware 'HKLM\SOFTWARE\ASIO exists' pass ''

    $drivers = Get-ChildItem $asioKey | Select-Object -ExpandProperty PSChildName
    $rubix   = $drivers | Where-Object { $_ -match 'rubix|roland' }
    if ($rubix) {
        Add-Result hardware 'Rubix ASIO driver registered' pass ($rubix -join ', ')
    } else {
        Add-Result hardware 'Rubix ASIO driver registered' fail ("found drivers: {0}" -f ($drivers -join ', '))
    }

    $usb = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
           Where-Object { $_.FriendlyName -match 'rubix|roland' }
    if ($usb) {
        $names = ($usb | ForEach-Object { $_.FriendlyName }) -join '; '
        Add-Result hardware 'Rubix USB device connected' pass $names
    } else {
        Add-Result hardware 'Rubix USB device connected' fail 'plug in the Rubix22 over USB'
    }
}

function Test-Wiring {
    Write-Host "`n[hardware] physical wiring + Rubix front panel" -ForegroundColor White

    Confirm-Step hardware 'mic plugged into INPUT 1L (XLR)'
    Confirm-Step hardware '+48 V phantom engaged for INPUT 1L'
    Confirm-Step hardware 'Hi-Z switch OFF on INPUT 1L'
    Confirm-Step hardware 'headphones in PHONES jack'
    Confirm-Step hardware 'DIRECT MONITOR switch OFF' 'otherwise you hear dry + processed at once'
    Confirm-Step hardware 'SENS gain set so loud notes do not clip' 'verify with a DAW or meter app'
    Confirm-Step hardware 'monitoring on headphones only, never speakers' 'open condenser + speakers = Larsen feedback'
}

function Test-RubixPanel {
    Write-Host "`n[hardware] Rubix ASIO control panel" -ForegroundColor White

    Confirm-Step hardware 'sample rate set to 48 kHz'
    Confirm-Step hardware 'USB streaming mode at lowest stable value'
    Confirm-Step hardware 'frame size at lowest stable value' 'target ~6 ms round-trip; back off if xruns'
}

# ------------------------------------------------------------------ Report --

function Write-Report {
    $stamp   = Get-Date -Format 'yyyy-MM-dd-HHmm'
    $logDir  = Join-Path $VaultRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir ("{0}-phase0-checklist.md" -f $stamp)

    $pass = @($script:Results | Where-Object Status -eq 'pass').Count
    $fail = @($script:Results | Where-Object Status -eq 'fail').Count
    $skip = @($script:Results | Where-Object Status -eq 'skip').Count
    $status = if ($fail -gt 0) { 'blocked' } elseif ($skip -gt 0) { 'in-progress' } else { 'completed' }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine(("date: {0}" -f (Get-Date -Format 'yyyy-MM-dd')))
    [void]$sb.AppendLine('project: newtones')
    [void]$sb.AppendLine(("status: {0}" -f $status))
    [void]$sb.AppendLine('phase: 0')
    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Phase 0 checklist run')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(("- pass: {0}" -f $pass))
    [void]$sb.AppendLine(("- fail: {0}" -f $fail))
    [void]$sb.AppendLine(("- skip: {0}" -f $skip))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Results')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| phase | step | status | detail |')
    [void]$sb.AppendLine('|---|---|---|---|')
    foreach ($r in $script:Results) {
        $detail = ($r.Detail -replace '\|','\\|')
        [void]$sb.AppendLine(("| {0} | {1} | {2} | {3} |" -f $r.Phase, $r.Step, $r.Status, $detail))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Next steps')
    [void]$sb.AppendLine('')
    if ($fail -gt 0) {
        [void]$sb.AppendLine('Resolve every `fail` row above before starting Phase 1 (audio pipeline skeleton).')
    } elseif ($skip -gt 0) {
        [void]$sb.AppendLine('Re-run without `-SkipInteractive` to close out the skipped manual checks.')
    } else {
        [void]$sb.AppendLine('Phase 0 closed. Move to Phase 1: cpal ASIO host, duplex stream, passthrough.')
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Open questions')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- ')

    $sb.ToString() | Out-File -FilePath $logFile -Encoding utf8

    Write-Host ''
    Write-Host ("report: {0}" -f $logFile) -ForegroundColor Cyan
    Write-Host ("summary: pass={0} fail={1} skip={2}" -f $pass, $fail, $skip) -ForegroundColor White

    if ($fail -gt 0) { exit 1 } else { exit 0 }
}

# ----------------------------------------------------------------- Driver --

Write-Host ''
Write-Host 'LiveDSP - Phase 0 bring-up checklist' -ForegroundColor White
Write-Host ("project root: {0}" -f $ProjectRoot) -ForegroundColor DarkGray
Write-Host ("vault root  : {0}" -f $VaultRoot)   -ForegroundColor DarkGray

Test-RustToolchain
Test-CargoProject
Test-AsioBuildChain
Test-RubixAsioDriver
Test-Wiring
Test-RubixPanel
Write-Report
