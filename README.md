# shiny-pancake

PowerShell script for log rotation and archiving. Reads rules from a JSON config, finds matching files, compresses them with 7-Zip, and writes JSON receipts for each completed job.

## Requirements

- Windows PowerShell 4+
- 7-Zip portable executable at `bin\7zip\7za.exe`

## Usage

```powershell
# Default config and log paths
.\main.ps1

# Custom paths
.\main.ps1 -JsonConfigPath "path\to\config.json" -LogFile "path\to\logfile.log"
```

| Parameter | Default | Description |
|---|---|---|
| `JsonConfigPath` | `configurations\directories_list.json` | Path to the JSON rules file |
| `LogFile` | `logs\log_yyyy-MM-dd.log` | Path to the log file for this run |

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
- The `receipt` and `logs` directories are created automatically on first run.
