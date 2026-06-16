# Log Rotation & Archiving Script — Design Document

## 1. System Overview

This PowerShell script automates the rotation and archival of log files. It reads rules from a JSON configuration, discovers matching files, groups them (optionally by date), compresses them into ZIP archives via 7-Zip, and writes JSON receipts for auditability.

```
┌─────────────────────────────────────────────────────────────────┐
│                      shiny-pancake                             │
│                                                                 │
│  ┌──────────────────┐     ┌──────────────┐     ┌──────────┐   │
│  │ configurations/  │     │   modules/   │     │ bin/     │   │
│  │                  │     │              │     │          │   │
│  │ directories_     │     │ logger/      │     │ 7zip/    │   │
│  │ list.json        │     │ fileimport/  │     │  7za.exe │   │
│  └────────┬─────────┘     └──────────────┘     └──────────┘   │
│           │                                                     │
│           ▼                                                     │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    main.ps1                              │  │
│  │                                                          │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌────────────────┐  │  │
│  │  │ Phase 1:    │  │ Phase 2:    │  │ Phase 3:       │  │  │
│  │  │ Prereqs     │→ │ Rules       │→ │ Cleanup        │  │  │
│  │  │ Validation  │  │ Processing  │  │ (Stop Logger)  │  │  │
│  │  └─────────────┘  └─────────────┘  └────────────────┘  │  │
│  └──────────────────────────────────────────────────────────┘  │
│           │                                                     │
│           ▼                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐    │
│  │   logs/      │  │  receipt/    │  │  DestinationPath │    │
│  │              │  │              │  │  (per rule)      │    │
│  │ log_YYYY-    │  │ YYYY-MM-DD/  │  │                  │    │
│  │ MM-DD.log    │  │              │  │ *.zip archives   │    │
│  └──────────────┘  └──────────────┘  └──────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Execution Flow

### 2.1 Top-Level Flow

```
START
  │
  ├─► Load Parameters (JsonConfigPath, LogFile)
  │
  ├─► Import Modules
  │     ├─ modules/logger (async log processor)
  │     └─ modules/fileimport (JSON reader)
  │
  ├─► Start-LogProcessor
  │
  ├─► PHASE 1: Prerequisites Validation
  │     │
  │     ├─► Test-Path 7za.exe ?
  │     │     ├─ NO → ERROR + throw
  │     │     └─ YES → run 7za.exe, check exit code
  │     │
  │     ├─► Get-JsonContent (load config)
  │     │     ├─ FAIL → ERROR + throw
  │     │     └─ OK  → continue
  │     │
  │     ├─► Validate Config
  │     │     ├─ Required fields present?
  │     │     ├─ No invalid filename chars?
  │     │     ├─ DateFormat valid?
  │     │     └─ FileNamePattern valid regex?
  │     │           ├─ FAIL → ERROR + throw
  │     │           └─ OK  → continue
  │     │
  │     └─► New-Item receipt/YYYY-MM-DD
  │
  ├─► PHASE 2: Rules Processing (foreach rule)
  │     │
  │     ├─► Rule Prerequisites
  │     │     ├─ SourcePath exists?
  │     │     ├─ DestinationPath exists?
  │     │     ├─ Files found?
  │     │     └─ Apply FileNamePattern filter
  │     │
  │     ├─► Job Generation
  │     │     │
  │     │     ├─ CleanSourceFiles == true?
  │     │     │     ├─ YES → Exclude today's files
  │     │     │     │       Group by LastWriteTime date
  │     │     │     │       One job per date group
  │     │     │     │
  │     │     └─ NO → One job for all files
  │     │
  │     └─► Job Execution (foreach job)
  │           ├─ Build archive name
  │           ├─ Create temp dir
  │           ├─ Move/Copy files → temp dir
  │           ├─ 7za.exe compress + delete temp
  │           └─ Write JSON receipt
  │
  └─► PHASE 3: Cleanup
        └─► Stop-LogProcessor
```

### 2.2 Detailed Rule Processing Flow

```
┌─────────────────────────────────────────────────────┐
│                   Rule Processing                    │
│                                                      │
│  ┌──────────────────────┐                           │
│  │  Load Rule Config    │                           │
│  └──────────┬───────────┘                           │
│             │                                        │
│             ▼                                        │
│  ┌──────────────────────┐    NO     ┌────────────┐  │
│  │ SourcePath exists?   │──────────►│ WARN +     │  │
│  └──────────┬───────────┘           │ SKIP RULE  │  │
│             │ YES                    └────────────┘  │
│             │                                        │
│             ▼                                        │
│  ┌──────────────────────┐    NO     ┌────────────┐  │
│  │DestPath exists?      │──────────►│ ERROR +    │  │
│  └──────────┬───────────┘           │ SKIP RULE  │  │
│             │ YES                    └────────────┘  │
│             │                                        │
│             ▼                                        │
│  ┌──────────────────────┐                           │
│  │ Get-ChildItem files  │                           │
│  └──────────┬───────────┘                           │
│             │                                        │
│             ▼                                        │
│  ┌──────────────────────┐    NO     ┌────────────┐  │
│  │ Files found?         │──────────►│ Mandatory? │  │
│  └──────────┬───────────┘           │            │  │
│             │ YES                    │ YES → ERR  │  │
│             │                        │ NO  → INF  │  │
│             │                        └─────┬──────┘  │
│             │                              │         │
│             ▼                              ▼         │
│  ┌──────────────────────┐    ┌──────────────────┐   │
│  │ Apply FileNamePattern│    │ All files kept   │   │
│  │ (regex filter)       │    └────────┬─────────┘   │
│  └──────────┬───────────┘             │             │
│             │                          ▼             │
│             │              ┌──────────────────┐     │
│             │              │ Job Generation    │     │
│             │              └────────┬─────────┘     │
│             │                       │               │
│             │              ┌────────┴─────────┐     │
│             │              │                  │     │
│             │     CleanSourceFiles   NOT       │     │
│             │          = true         = false   │     │
│             │              │                  │     │
│             │              ▼                  ▼     │
│             │     ┌──────────────┐  ┌──────────┐   │
│             │     │ Exclude today│  │ Single   │   │
│             │     │ files        │  │ Job      │   │
│             │     │              │  │          │   │
│             │     │ Group by     │  │          │   │
│             │     │ date         │  │          │   │
│             │     │              │  │          │   │
│             │     │ N Jobs       │  │ 1 Job    │   │
│             │     └──────┬───────┘  └──────────┘   │
│             │            │                           │
│             ▼            ▼                           │
│  ┌──────────────────────────────────────┐           │
│  │  For Each Job:                       │           │
│  │                                      │           │
│  │  1. Build ArchiveName                │           │
│  │     <Prefix>_<COMPUTERNAME>_<date>   │           │
│  │     <Suffix>.zip                      │           │
│  │                                      │           │
│  │  2. Create temp dir in SourcePath    │           │
│  │                                      │           │
│  │  3. Move/Copy files → temp dir       │           │
│  │                                      │           │
│  │  4. 7za.exe a -sdel <archive> *      │           │
│  │                                      │           │
│  │  5. Remove temp dir                  │           │
│  │                                      │           │
│  │  6. Write JSON receipt               │           │
│  └──────────────────────────────────────┘           │
└─────────────────────────────────────────────────────┘
```

---

## 3. Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Component Architecture                        │
│                                                                      │
│  ┌──────────────┐    ┌──────────────────────────────────────────┐   │
│  │   main.ps1   │    │              Orchestrator                │   │
│  │              │    │                                          │   │
│  │  - Params    │    │  ┌─────────────┐  ┌──────────────────┐  │   │
│  │  - Settings  │────┼──►│ Prereqs     │  │ Rules Processor  │  │   │
│  │  - Try/Catch │    │  │ Validator   │  │                  │  │   │
│  └──────┬───────┘    │  └─────────────┘  │  ┌────┬────┬────┐│  │   │
│         │            │                   │  │ R1 │ R2 │ R3 ││  │   │
│         │            │                   │  └────┴────┴────┘│  │   │
│         │            │                   │         │        │  │   │
│         │            │                   │  ┌──────┴──────┐ │  │   │
│         │            │                   │  │  Jobs       │ │  │   │
│         │            │                   │  │  Generator  │ │  │   │
│         │            │                   │  └──────┬──────┘ │  │   │
│         │            │                   │         │        │  │   │
│         │            │                   │  ┌──────┴──────┐ │  │   │
│         │            │                   │  │  Job Runner │ │  │   │
│         │            │                   │  └──────┬──────┘ │  │   │
│         │            │                   └──────────┼───────┘  │   │
│         │            │                              │          │   │
│         │            │                   ┌──────────┼───────┐  │   │
│         │            │                   │          │       │  │   │
│         │            │         ┌─────────┴┐  ┌────┴────┐  │  │   │
│         │            │         │  Logger  │  │ 7-Zip   │  │  │   │
│         │            │         │ Provider │  │ Engine  │  │  │   │
│         │            │         └──────────┘  └─────────┘  │  │   │
│         │            │                                      │  │   │
│         │            │         ┌──────────┐  ┌──────────┐ │  │   │
│         │            │         │ Receipt  │  │ JSON     │ │  │   │
│         │            │         │ Writer   │  │ Config   │ │  │   │
│         │            │         └──────────┘  └──────────┘ │  │   │
│         │            │                                      │  │   │
│         │            └──────────────────────────────────────┘  │   │
│         │                                                      │   │
│         │            ┌──────────────────────────────────┐      │   │
│         │            │         modules/                  │      │   │
│         │            │                                  │      │   │
│         │            │  ┌──────────────┐  ┌──────────┐ │      │   │
│         │            │  │ logger/      │  │fileimport│ │      │   │
│         │            │  │              │  │          │ │      │   │
│         │            │  │ Start-Log    │  │Get-Json  │ │      │   │
│         │            │  │ Processor    │  │Content   │ │      │   │
│         │            │  │ Add-LogMsg   │  │          │ │      │   │
│         │            │  │ Stop-LogProc │  │          │ │      │   │
│         │            │  └──────────────┘  └──────────┘ │      │   │
│         │            └──────────────────────────────────┘      │   │
│         │                                                      │   │
│         ▼                                                      │   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐    │   │
│  │ logs/        │  │ receipt/     │  │ DestinationPath  │    │   │
│  │              │  │              │  │ (per rule)       │    │   │
│  │ log_YYYY-    │  │ YYYY-MM-DD/  │  │                  │    │   │
│  │ MM-DD.log    │  │ *.json       │  │ *.zip            │    │   │
│  └──────────────┘  └──────────────┘  └──────────────────┘    │   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. Data Flow

### 4.1 Config → Rules → Jobs

```
┌──────────────────────────────────────────────────────────────────┐
│                     JSON Config (directories_list.json)           │
│                                                                   │
│  [                                                               │
│    {                                                             │
│      "Name": "App Logs",                                         │
│      "SourcePath": "D:\\app\\logs",                              │
│      "DestinationPath": "D:\\archives",                          │
│      "ArchiveNamePrefix": "AppLog",                              │
│      "ArchiveNameSuffix": "",                                    │
│      "DateFormat": "dd-MM-yy",                                   │
│      "FileNamePattern": ".*\\.log$",                             │
│      "CleanSourceFiles": true,                                   │
│      "Mandatory": false                                          │
│    },                                                            │
│    { ... }                                                       │
│  ]                                                               │
└────────────────────────────┬─────────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│                    Parsed Rule Objects                            │
│                                                                   │
│  Rule {                            Rule {                        │
│    Name = "App Logs"                Name = "System Logs"         │
│    SourcePath = "D:\\app\\logs"     SourcePath = "D:\\sys\\logs" │
│    DestPath = "D:\\archives"        DestPath = "D:\\archives"    │
│    Prefix = "AppLog"                Prefix = "SysLog"            │
│    Pattern = ".*\\.log$"            Pattern = ""                 │
│    CleanSrc = true                  CleanSrc = false             │
│    Mandatory = false                Mandatory = true             │
│  }                                }                              │
└────────────────────────────┬─────────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│                    Discovered & Filtered Files                    │
│                                                                   │
│  Rule 1: "App Logs"                                              │
│    SourcePath: D:\app\logs                                        │
│    All files: app.log, error.log, debug.log, readme.txt          │
│    Filtered: app.log, error.log, debug.log  (pattern match)      │
│                                                                   │
│  Rule 2: "System Logs"                                            │
│    SourcePath: D:\sys\logs                                        │
│    All files: sys1.log, sys2.log, sys3.log                       │
│    Filtered: sys1.log, sys2.log, sys3.log  (no filter)           │
└────────────────────────────┬─────────────────────────────────────┘
                             │
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│                    Generated Jobs                                 │
│                                                                   │
│  Rule 1 (CleanSourceFiles=true):                                 │
│    Files from 3 dates → 3 jobs                                   │
│    ┌─────────────────────────────────────────────────────┐       │
│    │ Job 1: AppLog_14-01-25                              │       │
│    │   Files: app.log (14-01), error.log (14-01)        │       │
│    └─────────────────────────────────────────────────────┘       │
│    ┌─────────────────────────────────────────────────────┐       │
│    │ Job 2: AppLog_13-01-25                              │       │
│    │   Files: debug.log (13-01)                          │       │
│    └─────────────────────────────────────────────────────┘       │
│    ┌─────────────────────────────────────────────────────┐       │
│    │ Job 3: AppLog_12-01-25                              │       │
│    │   Files: app.log (12-01)                            │       │
│    └─────────────────────────────────────────────────────┘       │
│                                                                   │
│  Rule 2 (CleanSourceFiles=false):                                │
│    Single job for all files                                      │
│    ┌─────────────────────────────────────────────────────┐       │
│    │ Job 4: SysLog                                       │       │
│    │   Files: sys1.log, sys2.log, sys3.log              │       │
│    └─────────────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────────────┘
```

### 4.2 Job Execution Data Flow

```
┌──────────────────────────────────────────────────────────────────┐
│                    Single Job Execution                           │
│                                                                   │
│  Input: Job { Name, Files[], BackupDate, UTC }                   │
│         Rule { SourcePath, DestPath, Prefix, Suffix, ... }       │
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 1. Compute Archive Name                                     │  │
│  │    "AppLog_COMPUTERNAME_14-01-25.zip"                      │  │
│  └────────────────────────┬───────────────────────────────────┘  │
│                            │                                      │
│                            ▼                                      │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 2. Create Temp Directory                                    │  │
│  │    D:\app\logs\AppLog_COMPUTERNAME_14-01-25\               │  │
│  └────────────────────────┬───────────────────────────────────┘  │
│                            │                                      │
│                            ▼                                      │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 3. Transfer Files to Temp Dir                               │  │
│  │                                                             │  │
│  │  CleanSourceFiles = true:                                   │  │
│  │    Move-Item app.log, error.log → temp dir                 │  │
│  │    (originals deleted)                                      │  │
│  │                                                             │  │
│  │  CleanSourceFiles = false:                                  │  │
│  │    Copy-Item app.log, error.log → temp dir                 │  │
│  │    (originals preserved)                                    │  │
│  └────────────────────────┬───────────────────────────────────┘  │
│                            │                                      │
│                            ▼                                      │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 4. Compress with 7-Zip                                      │  │
│  │                                                             │  │
│  │    7za.exe a -tzip -mm=Deflate -mx=9 -sdel                 │  │
│  │       D:\archives\AppLog_COMPUTERNAME_14-01-25.zip         │  │
│  │       D:\app\logs\AppLog_COMPUTERNAME_14-01-25\*           │  │
│  │                                                             │  │
│  │    -sdel: delete temp dir contents after zipping            │  │
│  └────────────────────────┬───────────────────────────────────┘  │
│                            │                                      │
│                            ▼                                      │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 5. Generate Receipt JSON                                    │  │
│  │                                                             │  │
│  │    receipt/2025-01-15/AppLog_14-01-25_1736934000.json     │  │
│  │    ┌─────────────────────────────────────────────────┐     │  │
│  │    │ {                                               │     │  │
│  │    │   "Name": "AppLog_14-01-25",                   │     │  │
│  │    │   "UTC": "2025-01-15T10:30:00.0000000Z",       │     │  │
│  │    │   "Archive": "D:\\archives\\...zip",            │     │  │
│  │    │   "Files": [                                    │     │  │
│  │    │     { "Name": "app.log", "LastWriteTimeUtc":   │     │  │
│  │    │              "2025-01-14T08:00:00.0000000Z"},   │     │  │
│  │    │     { "Name": "error.log", "LastWriteTimeUtc": │     │  │
│  │    │              "2025-01-14T09:00:00.0000000Z"}    │     │  │
│  │    │   ]                                             │     │  │
│  │    │ }                                               │     │  │
│  │    └─────────────────────────────────────────────────┘     │  │
│  └────────────────────────┬───────────────────────────────────┘  │
│                            │                                      │
│                            ▼                                      │
│  Output: Archive at DestPath, Receipt in receipt/YYYY-MM-DD/     │
│          Originals: deleted (if CleanSourceFiles) or kept        │
└──────────────────────────────────────────────────────────────────┘
```

---

## 5. Module Interaction Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                    Module Interactions                            │
│                                                                   │
│  main.ps1                                                        │
│    │                                                             │
│    ├─── Import-Module logger ─────────────────────────┐         │
│    │                                                  │         │
│    │                                                  ▼         │
│    │                                          ┌───────────────┐ │
│    │                                          │  Start-Log   │ │
│    │                                          │  Processor   │ │
│    │                                          └───────┬─────┘ │
│    │                                                  │         │
│    │                                                  ▼         │
│    │                                          ┌───────────────┐ │
│    │                                          │ Async Logger  │ │
│    │                                          │ (background   │ │
│    │                                          │  runspace)    │ │
│    │                                          └───────┬─────┘ │
│    │                                                  │         │
│    │                                                  ▼         │
│    │                                          ┌───────────────┐ │
│    │                                          │  Log File     │ │
│    │                                          │  (disk write) │ │
│    │                                          └───────────────┘ │
│    │                                                  │         │
│    │  Add-LogMessage ─────────────────────────────────┘         │
│    │  (enqueue to background runspace)                          │
│    │                                                             │
│    ├─── Import-Module fileimport ────────────────────┐          │
│    │                                                 │          │
│    │                                                 ▼          │
│    │                                          ┌───────────────┐  │
│    │                                          │ Get-Json     │  │
│    │                                          │ Content      │  │
│    │                                          └───────┬─────┘  │
│    │                                                  │          │
│    │                                                  ▼          │
│    │                                          ┌───────────────┐  │
│    │                                          │ JSON Config  │  │
│    │                                          │ File         │  │
│    │                                          └───────────────┘  │
│    │                                                             │
│    └─── External: 7za.exe ──────────────────────────────────────┘
│         (process spawn, -sdel flag)                              │
└──────────────────────────────────────────────────────────────────┘
```

---

## 6. Archive Naming Convention

```
┌──────────────────────────────────────────────────────────────────┐
│                    Archive Name Construction                      │
│                                                                   │
│  Pattern:                                                        │
│  ┌──────────┐ ┌────────────┐ ┌──────────┐ ┌──────────┐         │
│  │  Prefix  │ │ COMPU-     │ │  Date    │ │  Suffix  │         │
│  │ (optional)│ │ TERNAME   │ │ (config) │ │(optional)│         │
│  └────┬─────┘ └─────┬──────┘ └────┬─────┘ └────┬─────┘         │
│       │             │             │            │                 │
│       ▼             ▼             ▼            ▼                 │
│  "AppLog"    "_WIN-SRV01_"   "_14-01-25_"    ""                 │
│       │             │             │            │                 │
│       └─────────────┴─────────────┴────────────┘                 │
│                            │                                     │
│                            ▼                                     │
│                    "AppLog_WIN-SRV01_14-01-25.zip"              │
│                                                                   │
│  Date Format Options:                                            │
│    Default: dd-MM-yy  →  14-01-25                               │
│    Custom:  yyyyMMdd  →  20250114                               │
│    Custom:  MMM-yy    →  Jan-25                                 │
└──────────────────────────────────────────────────────────────────┘
```

---

## 7. Error Handling Strategy

```
┌──────────────────────────────────────────────────────────────────┐
│                    Error Handling Hierarchy                       │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Global try/finally (main.ps1)                           │    │
│  │  ┌────────────────────────────────────────────────────┐  │    │
│  │  │  finally: Stop-LogProcessor                        │  │    │
│  │  └────────────────────────────────────────────────────┘  │    │
│  │                                                          │    │
│  │  throw → script abort, critical error                    │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Rule try/catch/finally                                  │    │
│  │  ┌────────────────────────────────────────────────────┐  │    │
│  │  │  catch: log WARN, continue to next rule            │  │    │
│  │  │  finally: log "Finished rule"                      │  │    │
│  │  └────────────────────────────────────────────────────┘  │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Job try/catch/finally                                   │    │
│  │  ┌────────────────────────────────────────────────────┐  │    │
│  │  │  catch: log ERROR, skip this job                   │  │    │
│  │  │  finally: log "Ending Job"                         │  │    │
│  │  └────────────────────────────────────────────────────┘  │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                    │
│  Severity Levels:                                                │
│    ERROR  →  script abort (global) or rule skip (rule-level)     │
│    WARN   →  log warning, continue processing                    │
│    INFO   →  log informational message                           │
└──────────────────────────────────────────────────────────────────┘
```

---

## 8. Key Design Decisions

| Decision | Rationale |
|---|---|
| **Exclude today's files** when `CleanSourceFiles=true` | Prevents archiving files that are still being written to, avoiding corruption |
| **Group by date** when `CleanSourceFiles=true` | Keeps archives organized by day, making restoration and auditing easier |
| **Temp directory approach** | Single 7-Zip invocation is more efficient than per-file compression; `-sdel` ensures atomic cleanup |
| **Async logger** | Prevents log I/O from blocking the main archival loop |
| **JSON receipts** | Provides an audit trail with file paths, archive paths, and original UTC write times |
| **InvariantCulture** | Ensures consistent date/number formatting across different machine locales |
| **`-sdel` flag** | Automatically deletes the temp directory after compression, avoiding orphaned temp files |

---

## 9. File Layout

```
shiny-pancake/
├── main.ps1                          # Entry point, orchestrator
├── configurations/
│   └── directories_list.json         # Archiving rules config
├── modules/
│   ├── logger/
│   │   └── logger.psm1               # Async producer-consumer logger
│   └── fileimport/
│       └── fileimport.psm1           # JSON file reader
├── bin/
│   └── 7zip/
│       └── 7za.exe                   # 7-Zip portable executable
├── logs/                             # Auto-created
│   └── log_YYYY-MM-DD.log            # Execution log
├── receipt/                          # Auto-created
│   └── YYYY-MM-DD/
│       └── <JobName>_<unix_ts>.json  # Per-job receipts
└── docs/
    └── design/
        └── ARCHITECTURE.md           # This document
```
