# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

PowerShell script for log rotation and archiving. It reads rules from a JSON config, finds files matching each rule, groups them by date (optionally), compresses them with 7-Zip into named archives, and writes JSON receipts.

## Running the Script

```powershell
# Default config and log paths
.\main.ps1

# Custom config or log file
.\main.ps1 -JsonConfigPath "path\to\config.json" -LogFile "path\to\logfile.log"

# Resource throttling controls
.\main.ps1 -LimitResources $false
.\main.ps1 -CpuPercent 25 -ProcessPriority Idle
```

**Parameters:**

| Parameter | Default | Description |
|---|---|---|
| `JsonConfigPath` | `configurations\directories_list.json` | Path to the JSON rules file |
| `LogFile` | `logs\log_yyyy-MM-dd.log` | Path to the log file for this run |
| `LimitResources` | `$true` | Lower priority and restrict CPU affinity (best-effort; logs a warning and continues if it fails) |
| `CpuPercent` | `50` | Approx. % of CPU cores the process may use (1–100; floored, min 1) |
| `ProcessPriority` | `BelowNormal` | Priority class: `Idle`, `BelowNormal`, `Normal`, `AboveNormal`, `High` |

**Exit codes** (the only signal an external scheduler reads): `0` = clean, `1` = warnings only, `2` = any errors. Counts are tracked in the logger and read in the global `finally`; a missing module exits `2` via stderr.

**Requirements before running:**
- `bin\7zip\7za.exe` must exist (7-Zip portable executable)
- `configurations\directories_list.json` must exist (see config schema below)
- Windows PowerShell 4+ — avoid PS5-only syntax (e.g. use `New-Object`, not `[type]::new()`)

The script auto-creates `logs\` and `receipt\` directories.

## Architecture

### Execution Flow

`main.ps1` drives everything in phases:
1. **Resource throttling** — best-effort priority/affinity adjustment (controlled by `-LimitResources`/`-CpuPercent`/`-ProcessPriority`).
2. **Prerequisites** — verifies 7-Zip exists and is functional, loads & validates JSON config, creates receipt directory.
3. **Per rule** — validates source/dest exist, then:
   - **Leftover recovery** — finds temp dirs (`<Prefix><COMPUTERNAME>_*`) left by an interrupted run, archives + integrity-tests + removes them, writes a recovery receipt.
   - **Job generation** — filters files by `FileNamePattern`, then either creates one job (if `CleanSourceFiles=false`) or groups files by `LastWriteTime` date and creates one job per date group (if `CleanSourceFiles=true`, also excludes today's files). Jobs are sorted ascending by total size.
4. **Job execution** — for each job (smallest first): runs a **free-space pre-flight** check (skips this and all larger jobs with an error if it won't fit), stages files into a temp dir (move-with-copy-fallback, or copy), compresses with `7za a` (no `-sdel`), **integrity-tests the archive with `7za t`**, and only then deletes the staged files. Writes a JSON receipt. A fresh partial archive is removed on failure; a pre-existing one (same-day append) is preserved.

The staging dir lives under `SourcePath`; the archive name is `<Prefix>_<COMPUTERNAME>_<date><_Suffix>.zip`.

### Modules

- **`modules/logger`** — async producer-consumer logger. Main thread enqueues messages via `Add-LogMessage`; a background runspace dequeues and writes to file every 100ms. Call `Start-LogProcessor` before use and `Stop-LogProcessor` in the `finally` block. `Get-LogStats` returns the running WARN/ERROR counts (used for the exit code).
- **`modules/fileimport`** — single function `Get-JsonContent` that reads and parses a JSON file.

### JSON Config Schema

Each element in the config array:

| Field | Type | Required | Description |
|---|---|---|---|
| `Name` | string | yes | Display name for the rule |
| `SourcePath` | string | yes | Directory to read files from |
| `DestinationPath` | string | yes | Directory to write archives to |
| `CleanSourceFiles` | bool | yes | `true` = move files (delete originals); `false` = copy files (keep originals) |
| `Mandatory` | bool | yes | `true` = log ERROR if no files found; `false` = log INFO |
| `FileNamePattern` | string (regex) | no | Filter; if empty, all files are processed |
| `ArchiveNamePrefix` | string | no | Prefix before the hostname in the archive name |
| `ArchiveNameSuffix` | string | no | Suffix after the date in the archive name |
| `DateFormat` | string (.NET) | no | Date format in the archive name; defaults to `dd-MM-yy` |
| `CompressionLevel` | int 0–9 | no | 7-Zip `-mx` level; defaults to `5` |
| `ExpectedCompressionPercent` | int 0–99 | no | Expected size reduction, used only for the free-space estimate; defaults to `0` (assume incompressible) |
| `Description` | string | no | Free-text, ignored by the script |

### Receipt Format

Each job writes `receipt\<yyyy-MM-dd>\<JobName>_<unix_timestamp>.json` containing job name, UTC timestamp, archive path, and a list of processed files with their original UTC write times. Recovered leftover dirs write `<dir>_recovered_<unix_timestamp>.json` with `"Recovered": true`.

### Archive Naming

`<ArchiveNamePrefix>_<COMPUTERNAME>_<dd-MM-yy>.zip`

Date used: the files' `LastWriteTime` date (for `CleanSourceFiles=true`) or the current date (for `CleanSourceFiles=false`).
