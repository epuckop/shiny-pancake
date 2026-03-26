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
```

**Requirements before running:**
- `bin\7zip\7za.exe` must exist (7-Zip portable executable)
- `configurations\directories_list.json` must exist (see config schema below)

The script auto-creates `logs\` and `receipt\` directories.

## Architecture

### Execution Flow

`main.ps1` drives everything in three phases:
1. **Prerequisites** — verifies 7-Zip exists, loads JSON config, creates receipt directory
2. **Job generation** — per rule, filters files by `FileNamePattern`, then either creates one job (if `CleanSourceFiles=false`) or groups files by `LastWriteTime` date and creates one job per date group (if `CleanSourceFiles=true`, also excludes today's files)
3. **Job execution** — for each job: creates a temp directory, moves/copies files into it, calls `7za.exe -sdel` to compress and delete the temp dir, writes a JSON receipt to `receipt\<date>\`

### Modules

- **`modules/logger`** — async producer-consumer logger. Main thread enqueues messages via `Add-LogMessage`; a background runspace dequeues and writes to file every 100ms. Call `Start-LogProcessor` before use and `Stop-LogProcessor` in the `finally` block.
- **`modules/fileimport`** — single function `Get-JsonContent` that reads and parses a JSON file.

### JSON Config Schema

Each element in the config array:

| Field | Type | Description |
|---|---|---|
| `Name` | string | Display name for the rule |
| `SourcePath` | string | Directory to read files from |
| `DestinationPath` | string | Directory to write archives to |
| `ArchiveNamePrefix` | string | Prefix for archive filename; final name: `<Prefix>_<COMPUTERNAME>_<dd-MM-yy>.zip` |
| `FileNamePattern` | string (regex) | Optional filter; if empty, all files are processed |
| `CleanSourceFiles` | bool | `true` = move files (delete originals); `false` = copy files (keep originals) |
| `Mandatory` | bool | `true` = log ERROR if no files found; `false` = log INFO |

### Receipt Format

Each job writes `receipt\<yyyy-MM-dd>\<JobName>_<unix_timestamp>.json` containing job name, UTC timestamp, archive path, and a list of processed files with their original UTC write times.

### Archive Naming

`<ArchiveNamePrefix>_<COMPUTERNAME>_<dd-MM-yy>.zip`

Date used: the files' `LastWriteTime` date (for `CleanSourceFiles=true`) or the current date (for `CleanSourceFiles=false`).
