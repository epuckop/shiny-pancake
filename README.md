# shiny-pancake

PowerShell script for log rotation and archiving. Reads rules from a JSON config, finds matching files, compresses them with 7-Zip, and writes JSON receipts for each completed job.

## Requirements

- Windows PowerShell 4+
- 7-Zip standalone executable at `bin\7zip\x64\7za.exe`

## Usage

```powershell
# Default config and log paths
.\main.ps1

# Custom paths
.\main.ps1 -JsonConfigPath "path\to\config.json" -LogFile "path\to\logfile.log"

# Run without resource throttling
.\main.ps1 -LimitResources $false

# Restrict to ~25% of CPU cores at Idle priority
.\main.ps1 -CpuPercent 25 -ProcessPriority Idle
```

| Parameter | Default | Description |
|---|---|---|
| `JsonConfigPath` | `configurations\directories_list.json` | Path to the JSON rules file |
| `LogFile` | `logs\log_yyyy-MM-dd.log` | Path to the log file for this run |
| `LimitResources` | `$true` | Lower process priority and restrict CPU affinity to reduce system impact. Set `$false` to disable |
| `CpuPercent` | `50` | Approximate percentage of CPU cores the process may use (1–100). Floored, minimum 1 core. Ignored when `LimitResources` is `$false` |
| `ProcessPriority` | `BelowNormal` | Process priority class: `Idle`, `BelowNormal`, `Normal`, `AboveNormal`, `High`. Ignored when `LimitResources` is `$false` |

Resource throttling is best-effort: if priority or affinity cannot be applied, the run logs a warning and continues normally.

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed with no warnings or errors |
| `1` | Completed with warnings only |
| `2` | Completed with one or more errors |

## Configuration

Rules are defined as a JSON array. Each rule is processed independently — a failed rule does not stop the others.

### Required fields

| Field | Type | Description |
|---|---|---|
| `Name` | string | Display name used in logs |
| `SourcePath` | string | Directory to read files from |
| `DestinationPath` | string | Directory to write archives to |
| `CleanSourceFiles` | bool | `true` — move files into archive (delete originals); `false` — copy files (keep originals) |
| `Mandatory` | bool | `true` — log ERROR if no matching files found; `false` — log INFO |

### Optional fields

| Field | Type | Description |
|---|---|---|
| `FileNamePattern` | string (regex) | Filter files by name. If omitted, all files in `SourcePath` are processed |
| `ArchiveNamePrefix` | string | Prefix added before the hostname in the archive name |
| `ArchiveNameSuffix` | string | Suffix added after the date in the archive name |
| `DateFormat` | string (.NET format) | Date format used in the archive name. Defaults to `dd-MM-yy` |
| `CompressionLevel` | int (0–9) | 7-Zip compression level. Defaults to `5`. Higher = smaller archive, slower |
| `ExpectedCompressionPercent` | int (0–99) | Expected size reduction, used only to estimate free space before a job runs. E.g. `90` means the archive is expected to be ~10% of the source size. Defaults to `0` (assume incompressible — the most conservative estimate) |
| `Description` | string | Free-text description, not used by the script |

### Archive naming

```
[prefix_]COMPUTERNAME_date[_suffix].zip
```

Examples:

| Prefix | Suffix | DateFormat | Result |
|---|---|---|---|
| `Logs` | `PROD` | `yyyy-MM-dd` | `Logs_HOSTNAME_2025-03-26_PROD.zip` |
| _(none)_ | _(none)_ | _(default)_ | `HOSTNAME_26-03-25.zip` |

### Example config

```json
[
    {
        "Name": "AppLogs",
        "Description": "Daily rotation of application logs.",
        "SourcePath": "C:\\App\\logs",
        "DestinationPath": "D:\\Backups\\AppLogs",
        "FileNamePattern": "^.*\\.log$",
        "ArchiveNamePrefix": "AppLogs",
        "ArchiveNameSuffix": "PROD",
        "DateFormat": "yyyy-MM-dd",
        "CompressionLevel": 9,
        "CleanSourceFiles": true,
        "Mandatory": false
    }
]
```

## Output

| Path | Description |
|---|---|
| `logs\log_yyyy-MM-dd.log` | Execution log with timestamps and thread IDs |
| `receipt\yyyy-MM-dd\<job>_<timestamp>.json` | One JSON file per completed job |
| `receipt\yyyy-MM-dd\<dir>_recovered_<timestamp>.json` | Receipt for a leftover temp directory recovered after an interrupted run (includes `"Recovered": true`) |

### Receipt format

```json
{
    "Name": "AppLogs_26-03-25",
    "UTC": "2025-03-26T10:00:00.0000000Z",
    "Archive": "D:\\Backups\\AppLogs\\AppLogs_HOSTNAME_2025-03-26_PROD.zip",
    "Files": [
        {
            "Name": "app.log",
            "LastWriteTimeUtc": "2025-03-25T23:59:00.0000000Z"
        }
    ]
}
```

## Behaviour notes

- When `CleanSourceFiles` is `true`, files modified **today** are skipped and processed on the next run. Files from previous days are grouped by their last write date — one archive per date group.
- When `CleanSourceFiles` is `false`, all matching files are packed into a single archive regardless of date.
- Files are staged into a temp directory, compressed, and the archive is integrity-tested **before** the staged files are deleted. If compression or the test fails, the temp directory is left in place so no data is lost.
- **Disk-space pre-flight:** before each job, free space is checked on the destination (for the archive) and, in keep mode, on the source volume (for the temp copy that lives alongside the originals — source + temp copy + archive coexist). Jobs are processed smallest-first; if one does not fit, it and all larger remaining jobs in that rule are skipped with an error (exit code `2`). The estimate uses `ExpectedCompressionPercent`, the current size of any archive being appended to, and a static safety buffer. An optimistic estimate is safe: a genuine out-of-space failure during compression is caught and leaves source data intact.
- **Crash recovery:** leftover temp directories from a previous interrupted run are detected at the start of each rule, archived, verified, and removed — with their own recovery receipt — before normal processing begins.
- The `receipt` and `logs` directories are created automatically on first run.
