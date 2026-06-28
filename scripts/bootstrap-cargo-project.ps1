<#
.SYNOPSIS
  Scaffold the LiveDSP Cargo project per live-audio-poc-brief.md sections 4-5.

.DESCRIPTION
  Idempotent. If livedsp/Cargo.toml already exists, prints what is there and
  exits without touching anything. Otherwise:
    - runs `cargo new livedsp --bin --vcs none`
    - creates module dirs: audio, dsp, params, ui
    - writes empty mod.rs files so each module compiles
    - writes Cargo.toml with the crates listed in section 4 of the brief
    - writes a placeholder engine.rs and updates main.rs to wire modules

  Does not run `cargo build`. Run that yourself once a network/registry is
  reachable so you can see real version resolution.

.PARAMETER ProjectRoot
  Repo root. Defaults to the parent of this script's directory.
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$crateRoot = Join-Path $ProjectRoot 'livedsp'
$cargoToml = Join-Path $crateRoot 'Cargo.toml'

if (Test-Path $cargoToml) {
    Write-Host ("livedsp already scaffolded at {0}" -f $crateRoot) -ForegroundColor Yellow
    Write-Host 'nothing to do. delete the folder if you want to start over.' -ForegroundColor DarkGray
    exit 0
}

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Host 'cargo not on PATH. install Rust first: https://rustup.rs' -ForegroundColor Red
    exit 1
}

Write-Host ("scaffolding {0}" -f $crateRoot) -ForegroundColor Cyan
Push-Location $ProjectRoot
try {
    & cargo new livedsp --bin --vcs none
    if ($LASTEXITCODE -ne 0) { throw "cargo new failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}

$modules = 'audio','dsp','params','ui'
foreach ($m in $modules) {
    $dir = Join-Path $crateRoot ("src\{0}" -f $m)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $modFile = Join-Path $dir 'mod.rs'
    if (-not (Test-Path $modFile)) {
        Set-Content -Path $modFile -Value "// $m module - filled in during later phases`n" -Encoding utf8
    }
}

$engineRs = Join-Path $crateRoot 'src\engine.rs'
@'
// Owns lifetimes. Allocates everything up front. Never touches the RT path
// after init. Wired up in Phase 1.
'@ | Set-Content -Path $engineRs -Encoding utf8

$mainRs = Join-Path $crateRoot 'src\main.rs'
@'
mod audio;
mod dsp;
mod engine;
mod params;
mod ui;

fn main() {
    println!("LiveDSP - Phase 0 placeholder");
}
'@ | Set-Content -Path $mainRs -Encoding utf8

# Cargo.toml with the crates from brief section 4. Versions deliberately left
# loose so cargo resolves the latest compatible at first build. Lock down once
# Phase 1 builds clean.
$cargoTomlBody = @'
[package]
name    = "livedsp"
version = "0.1.0"
edition = "2021"
publish = false

[dependencies]
# Audio I/O via ASIO host on Windows.
cpal = { version = "*", features = ["asio"] }

# Wait-free SPSC ring buffer for the RT bridge.
rtrb = "*"

# Latest-state share between UI and audio threads.
triple_buffer = "*"

# Fixed-capacity collections for the hot path.
heapless = "*"

# Fail fast if the audio callback ever allocates.
assert_no_alloc = "*"

# Stop denormals from tanking CPU in delay/reverb feedback tails.
no_denormals = "*"

# Promote the audio thread priority correctly.
audio_thread_priority = "*"

# Minimal UI on a non-RT thread.
eframe = "*"
egui   = "*"

[profile.release]
lto           = "fat"
codegen-units = 1
panic         = "abort"
debug         = 1

[profile.dev]
opt-level = 1
'@
Set-Content -Path $cargoToml -Value $cargoTomlBody -Encoding utf8

Write-Host ''
Write-Host 'done. next steps:' -ForegroundColor Green
Write-Host '  1. cd livedsp'
Write-Host '  2. cargo build              # resolves real versions, pins lockfile'
Write-Host '  3. pin the version specs in Cargo.toml to whatever cargo picked'
