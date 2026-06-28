# Phase 0 scripts

Scripts that automate the Phase 0 bring-up checklist from
[live-audio-poc-brief.md](../live-audio-poc-brief.md) section 6.

Run from PowerShell (Windows). Bash is not supported - the checks read the
Windows registry and PnP device list.

## Scripts

### `phase0-checklist.ps1`

Walks every Phase 0 item. Automated probes for:

- `rustup`, `rustc`, `cargo` on PATH
- stable toolchain active
- `x86_64-pc-windows-msvc` target installed
- `livedsp/Cargo.toml` and module dirs present
- `HKLM\SOFTWARE\ASIO` Rubix driver entry
- Rubix22 enumerated by Windows as a PnP device

Interactive prompts for physical wiring and the Rubix front-panel switches
(phantom, Hi-Z, DIRECT MONITOR, headphones, SENS) and Rubix ASIO panel
settings (48 kHz, USB streaming, frame size).

Writes a Markdown report to `~/vault/newtones/logs/YYYY-MM-DD-HHmm-phase0-checklist.md`
following the session log format in the global `CLAUDE.md`.

```pwsh
pwsh -File scripts\phase0-checklist.ps1
pwsh -File scripts\phase0-checklist.ps1 -SkipInteractive   # automated probes only
```

Exit code is 1 if any check failed.

### `bootstrap-cargo-project.ps1`

Idempotent. Scaffolds `livedsp/` with:

- `cargo new livedsp --bin --vcs none`
- module dirs `src/audio`, `src/dsp`, `src/params`, `src/ui` per brief section 5
- `Cargo.toml` seeded with the crates from brief section 4

```pwsh
pwsh -File scripts\bootstrap-cargo-project.ps1
```

Version specs are left as `*` so `cargo build` resolves the latest compatible
on first run. Pin them in `Cargo.toml` after that first successful build.

## Typical Phase 0 flow

```pwsh
pwsh -File scripts\bootstrap-cargo-project.ps1
cd livedsp
cargo build
cd ..
pwsh -File scripts\phase0-checklist.ps1
```

When every row in the report is `pass`, Phase 0 is closed. Move to Phase 1.
