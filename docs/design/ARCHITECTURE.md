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
  │     │     ├─ Leftover recovery (archive+verify orphaned temp dirs)
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
  │     │     ├─ NO → One job for all files
  │     │     └─ Sort jobs ascending by size
  │     │
  │     └─► Job Execution (foreach job, smallest first)
  │           ├─ Free-space pre-flight (skip if it won't fit)
  │           ├─ Build archive name
  │           ├─ Create temp dir
  │           ├─ Move/Copy files → temp dir (.NET File API)
  │           ├─ 7za a compress  →  7za t verify
  │           ├─ Remove temp dir (only after verify)
  │           └─ Write JSON receipt
  │
  └─► PHASE 3: Cleanup
        ├─► Write summary + compute exit code (0/1/2)
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
│  │  3. Free-space pre-flight check      │           │
│  │                                      │           │
│  │  4. Move/Copy files → temp dir       │           │
│  │     (.NET File API)                  │           │
│  │                                      │           │
│  │  5. 7za a <archive> * → 7za t verify │           │
│  │     remove temp dir after verify     │           │
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
│  │ 3. Free-space pre-flight (skip job if it won't fit)         │  │
│  │                                                             │  │
│  │ 4. Transfer Files to Temp Dir (.NET File API)               │  │
│  │                                                             │  │
│  │  CleanSourceFiles = true:                                   │  │
│  │    [IO.File]::Move app.log... → temp (copy fallback if      │  │
│  │    locked; originals removed)                               │  │
│  │                                                             │  │
│  │  CleanSourceFiles = false:                                  │  │
│  │    [IO.File]::Copy app.log... → temp (originals preserved)  │  │
│  └────────────────────────┬───────────────────────────────────┘  │
│                            │                                      │
│                            ▼                                      │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 5. Compress, verify, then delete staged files               │  │
│  │                                                             │  │
│  │    7za a -tzip -mm=Deflate -mx=<CompressionLevel>          │  │
│  │       D:\archives\AppLog_COMPUTERNAME_14-01-25.zip         │  │
│  │       D:\app\logs\AppLog_COMPUTERNAME_14-01-25\*           │  │
│  │                                                             │  │
│  │    7za t <archive>   ← integrity test                       │  │
│  │    only on success → remove temp dir (no -sdel)             │  │
│  └────────────────────────┬───────────────────────────────────┘  │
│                            │                                      │
│                            ▼                                      │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ 6. Generate Receipt JSON                                    │  │
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
│         (process spawn: 'a' compress, then 't' integrity test)   │
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
│  │  │  catch: log ERROR (does not re-throw)              │  │    │
│  │  finally: write summary, compute exit code,        │  │    │
│  │           Stop-LogProcessor                         │  │    │
│  │  └────────────────────────────────────────────────────┘  │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Rule try/catch/finally                                  │    │
│  │  ┌────────────────────────────────────────────────────┐  │    │
│  │  │  catch: log ERROR, continue to next rule           │  │    │
│  │  │  finally: log "Finished rule"                      │  │    │
│  │  └────────────────────────────────────────────────────┘  │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  Job try/catch/finally                                   │    │
│  │  ┌────────────────────────────────────────────────────┐  │    │
│  │  │  catch: log ERROR, remove fresh partial archive,   │  │    │
│  │  │         skip this job                              │  │    │
│  │  │  finally: log "Ending Job"                         │  │    │
│  │  └────────────────────────────────────────────────────┘  │    │
│  └──────────────────────────────────────────────────────────┘    │
│                                                                    │
│  Severity Levels:                                                │
│    ERROR  →  log error; counts toward exit code 2               │
│    WARN   →  log warning; counts toward exit code 1             │
│    INFO   →  log informational message                          │
│                                                                  │
│  Exit codes (the only signal the external scheduler reads):     │
│    0 = clean   1 = warnings only   2 = any errors               │
│  Counts come from Get-LogStats; the global finally sets the     │
│  code. Errors are logged, never re-thrown, so the process       │
│  always exits deterministically (a missing module exits 2).     │
└──────────────────────────────────────────────────────────────────┘
```

---

## 8. Key Design Decisions

| Decision | Rationale |
|---|---|
| **Exclude today's files** when `CleanSourceFiles=true` | Prevents archiving files that are still being written to, avoiding corruption |
| **Group by date** when `CleanSourceFiles=true` | Keeps archives organized by day, making restoration and auditing easier |
| **Temp directory approach** | Single 7-Zip invocation is more efficient than per-file compression |
| **Integrity test before delete** | Compress (no `-sdel`), run `7za t`, and only then delete the staged files. A failed/corrupt archive leaves the temp dir intact, so the next run's leftover-recovery pass salvages it — no data loss |
| **Leftover recovery** | Temp dirs left by an interrupted run are detected, archived, verified, and removed (with their own receipt) at the start of each rule |
| **Free-space pre-flight** | Before each job, estimate required space (per `ExpectedCompressionPercent` + buffer) and skip gracefully if it won't fit. Jobs run smallest-first so each completion can free space for the next |
| **Smallest-first ordering** | On a tight disk, completing small jobs first frees source space; once one job doesn't fit, no larger one will, so the rest are skipped with exit code 2 |
| **Resource throttling** | Best-effort lower priority + CPU affinity so the tool doesn't starve the host; failure is logged and ignored |
| **Exit codes 0/1/2** | The external scheduler reads only the exit code, so errors are logged (never re-thrown) and the global finally exits deterministically |
| **Async logger** | Prevents log I/O from blocking the main archival loop |
| **JSON receipts** | Provides an audit trail with file paths, archive paths, and original UTC write times |
| **InvariantCulture** | Ensures consistent date/number formatting across different machine locales |
| **PowerShell 4 compatibility** | Targets Windows PowerShell 4; avoids PS5-only syntax such as `[type]::new()` |

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
        ├── ARCHITECTURE.md           # This document
        └── FLOWCHARTS.md             # Companion Mermaid flowcharts
```
