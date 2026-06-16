<#
.SYNOPSIS
    This script provides a multi-stage process for archiving and rotating log files based on a JSON configuration.
.DESCRIPTION
    The script operates in several distinct stages for each rule defined in the configuration file.
.PARAMETER JsonConfigPath
    Path to the JSON file containing archiving rules. Defaults to 'configurations\directories_list.json'.
.PARAMETER LogFile
    Path to the log file for this execution. Defaults to a dated file in the 'logs\' directory.
.PARAMETER LimitResources
    When $true (default), the script lowers its process priority and restricts CPU affinity to reduce
    its impact on the system. Set to $false to run without any resource throttling.
.PARAMETER CpuPercent
    Approximate percentage of CPU cores the process is allowed to use (1-100, default 50). The core count
    is floored so the budget is never exceeded, with a minimum of 1 core. Ignored if -LimitResources is $false.
.PARAMETER ProcessPriority
    Process priority class to apply (default 'BelowNormal'). Ignored if -LimitResources is $false.
.NOTES
    Author: Dmitry Goldenberg
    Compatibility: Windows PowerShell 4 and later.
#>

param(
    [string]$JsonConfigPath = (Join-Path $PSScriptRoot "configurations\directories_list.json"),
    [string]$LogFile = (Join-Path $PSScriptRoot "logs\log_$(Get-Date -Format "yyyy-MM-dd").log"),
    [bool]$LimitResources = $true,
    [ValidateRange(1, 100)][int]$CpuPercent = 50,
    [ValidateSet('Idle', 'BelowNormal', 'Normal', 'AboveNormal', 'High')][string]$ProcessPriority = 'BelowNormal'
)

###################################################
######### Starting Script global settings #########
###################################################

# --- Global Settings ---
# Define an invariant culture for consistent date/number formatting.
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

# Define a standard, unambiguous date format to be used throughout the script.
$StandardDateFormat = 'dd-MM-yy'

# --- 7-Zip Configuration ---
$ZipPath = (Join-Path $PSScriptRoot "bin\7zip\7za.exe")
# Default 7-Zip compression level (0-9). Overridable per-rule via 'CompressionLevel' in the config.
$DefaultCompressionLevel = 5

# --- Free-space pre-flight ---
# Static safety margin added on top of the estimated archive size for the disk-space check.
$SpaceSafetyBufferBytes = 256MB

# Receipt path
$ReceiptPath = (Join-Path $PSScriptRoot "receipt\$(Get-Date -Format "yyyy-MM-dd")")

###################################################
########## Ending Script global settings ##########
###################################################

######################################################
############## Import requested modules ##############
######################################################

foreach ($Module in 'logger', 'fileimport') {
    try { Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "modules\$Module") -ErrorAction Stop }
    catch {
        # Logger is not available yet — write to stderr and exit with the error code (2) so the
        # external scheduler, which only inspects the exit code, sees a failure rather than exit 1.
        [Console]::Error.WriteLine("Critical Error: 'modules\$Module' not found or failed to load. Script cannot continue.`nError: $_")
        exit 2
    }
}

#################################################
############## Starting main logic ##############
#################################################

# global try
try {
    ############## Start logger ##############
    Start-LogProcessor -LogFilePath $LogFile
    Add-LogMessage "Starting Script" INFO

    ############## Start resource throttling ##############
    # Best-effort: lower priority and restrict CPU affinity. Failure here must not stop the run.
    if ($LimitResources) {
        try {
            $Proc = [System.Diagnostics.Process]::GetCurrentProcess()
            $Proc.PriorityClass = $ProcessPriority

            # Floor the core budget so we never exceed the requested percentage; at least 1 core.
            $TotalCores = [System.Environment]::ProcessorCount
            $AllowedCores = [int][Math]::Max(1, [Math]::Floor($TotalCores * $CpuPercent / 100.0))
            $ShiftCores = $TotalCores - $AllowedCores
            # Bitmask of the highest $AllowedCores cores, leaving the low cores for the OS/foreground.
            $Mask = ([int64][Math]::Pow(2, $AllowedCores) - 1) * [int64][Math]::Pow(2, $ShiftCores)
            $Proc.ProcessorAffinity = [IntPtr]$Mask

            Add-LogMessage "Resource throttling applied: priority '$ProcessPriority', $AllowedCores of $TotalCores core(s) (~$CpuPercent%)." INFO
        }
        catch {
            Add-LogMessage "Could not apply resource throttling. Continuing without it. Error: $($_.Exception.Message)" WARN
        }
    }
    else {
        Add-LogMessage "Resource throttling disabled by parameter. Running at default priority/affinity." INFO
    }
    ############## End resource throttling ##############

    ############## Start Prerequisites Validation ##############
    # Run pre-flight checks to ensure the environment is ready for execution.

    # Check for 7-Zip and verify it is functional
    if (-not (Test-Path -Path $ZipPath -PathType Leaf)) {
        Add-LogMessage "Prerequisite failed: 7-Zip executable not found at '$ZipPath'." ERROR
        throw "Prerequisite failed: 7-Zip executable not found at '$ZipPath'."
    }

    $ZipOutput = & $ZipPath 2>&1
    if ($LASTEXITCODE -eq 0) {
        $ZipVersion = ($ZipOutput | Select-String '7-Zip').Line.Trim()
        Add-LogMessage "Prerequisite passed: 7-Zip is functional. $ZipVersion" INFO
    }
    else {
        Add-LogMessage "Prerequisite failed: 7-Zip executable at '$ZipPath' is not functional. Exit code: $LASTEXITCODE" ERROR
        throw "Prerequisite failed: 7-Zip executable at '$ZipPath' is not functional."
    }

    # Get configuration from the json file
    try {
        $Configurations = Get-JsonContent -Path $JsonConfigPath
        Add-LogMessage "Configuration loaded successfully from: '$JsonConfigPath'." INFO
    }
    catch {
        Add-LogMessage "CRITICAL: Failed to load configuration file: $JsonConfigPath. Script cannot continue." ERROR
        throw "CRITICAL: Failed to load configuration file: $JsonConfigPath. Script cannot continue.`nOriginal Error: $_"
    }

    # Validate configuration is not empty
    if (-not $Configurations) {
        Add-LogMessage "CRITICAL: Configuration file '$JsonConfigPath' contains no rules." ERROR
        throw "CRITICAL: Configuration file '$JsonConfigPath' contains no rules."
    }
    Add-LogMessage "Configuration contains $($Configurations.Count) rule(s)." INFO

    # Validate required fields in each rule
    $ConfigValid = $true
    $RuleIndex = 0
    $InvalidFileNameChars = [System.IO.Path]::GetInvalidFileNameChars()
    foreach ($Rule in $Configurations) {
        $RuleIndex++
        $RuleLabel = if (-not [string]::IsNullOrWhiteSpace($Rule.Name)) { "'$($Rule.Name)'" } else { "at index $RuleIndex" }

        foreach ($Field in @('Name', 'SourcePath', 'DestinationPath')) {
            if ([string]::IsNullOrWhiteSpace($Rule.$Field)) {
                Add-LogMessage "Config validation: Rule $RuleLabel is missing required string field '$Field'." ERROR
                $ConfigValid = $false
            }
        }

        foreach ($Field in @('CleanSourceFiles', 'Mandatory')) {
            if ($null -eq $Rule.$Field) {
                Add-LogMessage "Config validation: Rule $RuleLabel is missing required boolean field '$Field'." ERROR
                $ConfigValid = $false
            }
        }
        foreach ($Field in @('Name', 'ArchiveNamePrefix', 'ArchiveNameSuffix')) {
            if (-not [string]::IsNullOrWhiteSpace($Rule.$Field)) {
                if ($Rule.$Field.IndexOfAny($InvalidFileNameChars) -ge 0) {
                    Add-LogMessage "Config validation: Rule $RuleLabel field '$Field' contains invalid filename characters." ERROR
                    $ConfigValid = $false
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($Rule.DateFormat)) {
            try { (Get-Date).ToString($Rule.DateFormat, $InvariantCulture) | Out-Null }
            catch {
                Add-LogMessage "Config validation: Rule $RuleLabel has invalid 'DateFormat' value '$($Rule.DateFormat)'." ERROR
                $ConfigValid = $false
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($Rule.FileNamePattern)) {
            try { $null = [regex]$Rule.FileNamePattern }
            catch {
                Add-LogMessage "Config validation: Rule $RuleLabel has invalid 'FileNamePattern' value '$($Rule.FileNamePattern)'." ERROR
                $ConfigValid = $false
            }
        }

        if ($null -ne $Rule.CompressionLevel) {
            $ParsedLevel = $Rule.CompressionLevel -as [int]
            if ($null -eq $ParsedLevel -or $ParsedLevel -lt 0 -or $ParsedLevel -gt 9) {
                Add-LogMessage "Config validation: Rule $RuleLabel has invalid 'CompressionLevel' value '$($Rule.CompressionLevel)'. Must be an integer 0-9." ERROR
                $ConfigValid = $false
            }
        }

        if ($null -ne $Rule.ExpectedCompressionPercent) {
            $ParsedPercent = $Rule.ExpectedCompressionPercent -as [int]
            if ($null -eq $ParsedPercent -or $ParsedPercent -lt 0 -or $ParsedPercent -gt 99) {
                Add-LogMessage "Config validation: Rule $RuleLabel has invalid 'ExpectedCompressionPercent' value '$($Rule.ExpectedCompressionPercent)'. Must be an integer 0-99." ERROR
                $ConfigValid = $false
            }
        }
    }

    if (-not $ConfigValid) {
        throw "CRITICAL: Configuration validation failed. Fix the config and re-run."
    }
    Add-LogMessage "Configuration validation passed: $($Configurations.Count) rule(s) validated." INFO

    # Create folder for receipt
    if (-not (Test-Path -Path $ReceiptPath -PathType Container)) { New-Item -Path $ReceiptPath -ItemType Directory -Force | Out-Null }
    ############## End Prerequisites Validation ##############

    ############## Start rules processing ##############
    # Process each rule from the configuration. A single Rule may generate multiple Jobs 
    # (e.g., one Job per day) if CleanSourceFiles is enabled.
    foreach ($Rule in $Configurations) {
        # Rule try
        try {
            Add-LogMessage "Starting rule: '$($Rule.Name)'" INFO

            ############## Start rule Prerequisites validation ##############
            # Validate the source path from config.
            if (-not (Test-Path -Path $Rule.SourcePath -PathType Container)) {
                Add-LogMessage "Source directory '$($Rule.SourcePath)' not found. Skipping rule." WARN
                continue
            }

            # Validate the destination path from config.
            if (-not (Test-Path -Path $Rule.DestinationPath -PathType Container)) {
                Add-LogMessage "Destination directory '$($Rule.DestinationPath)' not found. Skipping rule." ERROR
                continue
            }
            Add-LogMessage "Paths for rule '$($Rule.Name)' are validated." INFO

            ############## Start leftover temp directory cleanup ##############
            $CleanupPrefix = if (-not [string]::IsNullOrWhiteSpace($Rule.ArchiveNamePrefix)) { "$($Rule.ArchiveNamePrefix)_" } else { "" }
            $LeftoverDirs = Get-ChildItem -Path $Rule.SourcePath -Directory -Filter "$CleanupPrefix$($env:COMPUTERNAME)_*" -ErrorAction SilentlyContinue

            if ($LeftoverDirs) {
                Add-LogMessage "Found $($LeftoverDirs.Count) leftover temp directory(ies) from a previous interrupted run." WARN
                $RecoveryLevel = if ($null -ne $Rule.CompressionLevel) { [int]$Rule.CompressionLevel } else { $DefaultCompressionLevel }
                foreach ($LeftoverDir in $LeftoverDirs) {
                    try {
                        $LeftoverContents = Get-ChildItem -Path $LeftoverDir.FullName -File -ErrorAction SilentlyContinue
                        if (-not $LeftoverContents) {
                            Add-LogMessage "Leftover temp dir '$($LeftoverDir.Name)' is empty. Removing." WARN
                            Remove-Item -Path $LeftoverDir.FullName -Force -Recurse -ErrorAction SilentlyContinue
                            continue
                        }
                        # The leftover dir name is already the archive base name, so just add '.zip'.
                        $LeftoverArchiveFullPath = Join-Path (Resolve-Path -LiteralPath $Rule.DestinationPath).Path "$($LeftoverDir.Name).zip"
                        Add-LogMessage "Recovering leftover temp dir '$($LeftoverDir.Name)' -> '$LeftoverArchiveFullPath'" WARN

                        # Capture file metadata before archiving for the recovery receipt.
                        $RecoveredFilesInfo = @()
                        foreach ($File in $LeftoverContents) {
                            $RecoveredFilesInfo += [pscustomobject]@{
                                Name             = $File.Name
                                LastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
                            }
                        }

                        # Compress without -sdel, then verify before deleting the source files. Run with the
                        # working directory set to the leftover dir and '*', so only bare file names are stored
                        # (set both the PowerShell location and the process CWD; restore both afterwards).
                        $ZipAddArgs = @('a', '-tzip', '-mm=Deflate', "-mx=$RecoveryLevel")
                        $PrevCwd = [System.Environment]::CurrentDirectory
                        Push-Location -LiteralPath $LeftoverDir.FullName
                        try {
                            [System.Environment]::CurrentDirectory = (Get-Location).Path
                            & $ZipPath $ZipAddArgs $LeftoverArchiveFullPath '*'
                        }
                        finally {
                            Pop-Location
                            [System.Environment]::CurrentDirectory = $PrevCwd
                        }
                        if ($LASTEXITCODE -ge 2) { throw "7-Zip failed with exit code $LASTEXITCODE." }
                        if (-not (Test-Path -Path $LeftoverArchiveFullPath -PathType Leaf)) { throw "7-Zip completed but archive was not created." }

                        & $ZipPath t $LeftoverArchiveFullPath
                        if ($LASTEXITCODE -ne 0) { throw "Archive integrity test failed with exit code $LASTEXITCODE." }

                        if (Test-Path -Path $LeftoverDir.FullName) { Remove-Item -Path $LeftoverDir.FullName -Force -Recurse -ErrorAction SilentlyContinue }

                        # Write a recovery receipt.
                        $RecoveryUTC = (Get-Date).ToUniversalTime()
                        $UFormat = Get-Date -Date $RecoveryUTC -UFormat %s
                        $ReceiptFilePath = "$ReceiptPath\$($LeftoverDir.Name)_recovered_$UFormat.json"
                        $RecoveryReceipt = @{
                            Name      = $LeftoverDir.Name
                            Recovered = $true
                            UTC       = $RecoveryUTC.ToString('o')
                            Archive   = $LeftoverArchiveFullPath
                            Files     = $RecoveredFilesInfo
                        }
                        $RecoveryReceipt | ConvertTo-Json -Depth 3 | Set-Content -Path $ReceiptFilePath -Encoding utf8

                        Add-LogMessage "Leftover temp dir '$($LeftoverDir.Name)' successfully recovered." INFO
                    }
                    catch {
                        Add-LogMessage "Failed to recover leftover temp dir '$($LeftoverDir.Name)'. Error: $_" ERROR
                    }
                }
            }
            ############## End leftover temp directory cleanup ##############

            # Discover all files in the source directory (pattern filtering happens further below).
            $AllFilesInSourceDir = Get-ChildItem -Path $Rule.SourcePath -File -ErrorAction SilentlyContinue

            if (-not $AllFilesInSourceDir) {
                switch ($Rule.Mandatory) {
                    $true { Add-LogMessage "No files found in source directory '$($Rule.SourcePath)'. Nothing to stage." ERROR; continue }
                    $false { Add-LogMessage "No files found in source directory '$($Rule.SourcePath)'. Nothing to stage." INFO; continue }
                }          
            }
            Add-LogMessage "Found $($AllFilesInSourceDir.Count) total files in directory before filtering." INFO

            # Filter files by FileNamePattern from JSON, if provided.
            $FilteredFiles = $null
            if ([string]::IsNullOrWhiteSpace($Rule.FileNamePattern)) {
                Add-LogMessage "FileNamePattern is not defined. Processing all found files." INFO
                $FilteredFiles = $AllFilesInSourceDir
            }
            else {
                Add-LogMessage "Filtering files using pattern: '$($Rule.FileNamePattern)'" INFO                
                $FilteredFiles = $AllFilesInSourceDir | Where-Object { $_.Name -match $Rule.FileNamePattern }
            }

            if (-not $FilteredFiles) {
                switch ($Rule.Mandatory) {
                    $true { Add-LogMessage "No files found in source directory '$($Rule.SourcePath)' that match FileNamePattern. Nothing to stage." ERROR; continue }
                    $false { Add-LogMessage "No files found in source directory '$($Rule.SourcePath)' that match FileNamePattern. Nothing to stage." INFO; continue }
                }          
            }
            Add-LogMessage "$($FilteredFiles.Count) files matched FileNamePattern." INFO
            ############## End rule prerequisites validation ##############

            ############## Start jobs generation ##############
            $Jobs = @()
            if ($Rule.CleanSourceFiles) {
                Add-LogMessage "Rule '$($Rule.Name)' may generate multiple jobs (one per date)." INFO

                # Filter files by date: ignore anything modified today.
                $Today = (Get-Date).Date # Get date with time at 00:00:00
                $FilesToStage = $FilteredFiles | Where-Object { $_.LastWriteTime.Date -lt $Today }

                if (-not $FilesToStage) { Add-LogMessage "No files found for staging (all files are from today or newer)." INFO; continue }
                Add-LogMessage "$($FilesToStage.Count) files remaining after date filter." INFO

                # Group the remaining files by their last modification date.
                $GroupedByDate = $FilesToStage | Group-Object { $_.LastWriteTime.Date.ToString($StandardDateFormat, $InvariantCulture) }
                Add-LogMessage "Files are grouped into $($GroupedByDate.Count) different date(s)." INFO

                # Process each date group.
                foreach ($DateGroup in $GroupedByDate) {
                    Add-LogMessage "Processing date group: '$($DateGroup.Name)'" INFO

                    $BackupDateName = [DateTime]::ParseExact($DateGroup.Name, $StandardDateFormat, $InvariantCulture)
                    $JobName = if (-not [string]::IsNullOrWhiteSpace($Rule.ArchiveNamePrefix)) { "$($Rule.ArchiveNamePrefix)_$($BackupDateName.ToString($StandardDateFormat))" } else { "$($Rule.Name)_$($BackupDateName.ToString($StandardDateFormat))" }

                    # List + .Add() instead of '+=' so building this scales linearly (a day can hold
                    # thousands of files; '+=' reallocates the whole array on every item -> O(n^2)).
                    $FilesToStageWithInfo = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($File in $DateGroup.Group) {
                        $FilesToStageWithInfo.Add([pscustomobject]@{
                                Name             = $File.Name
                                LastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
                            })
                    }

                    $Jobs += [pscustomobject]@{
                        Name       = $JobName
                        BackupDate = $DateGroup.Name
                        UTC        = (Get-Date).ToUniversalTime()
                        FilesInfo  = $FilesToStageWithInfo
                        Files      = $DateGroup.Group
                        SizeBytes  = [int64](($DateGroup.Group | Measure-Object -Property Length -Sum).Sum)
                    }

                    Add-LogMessage "Finished date group: '$($DateGroup.Name)'" INFO
                }
            }
            else { 
                Add-LogMessage "Rule '$($Rule.Name)' generates a single job." INFO

                $JobName = if (-not [string]::IsNullOrWhiteSpace($Rule.ArchiveNamePrefix)) { $Rule.ArchiveNamePrefix } else { $Rule.Name }
                $BackupDateString = (Get-Date).ToString($StandardDateFormat, $InvariantCulture)

                # List + .Add() instead of '+=' (see the rotation branch above) for linear scaling.
                $FilesToStageWithInfo = New-Object 'System.Collections.Generic.List[object]'
                foreach ($File in $FilteredFiles) {
                    $FilesToStageWithInfo.Add([pscustomobject]@{
                            Name             = $File.Name
                            LastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
                        })
                }

                $Jobs += [pscustomobject]@{
                    Name       = $JobName
                    BackupDate = $BackupDateString
                    UTC        = (Get-Date).ToUniversalTime()
                    FilesInfo  = $FilesToStageWithInfo
                    Files      = $FilteredFiles
                    SizeBytes  = [int64](($FilteredFiles | Measure-Object -Property Length -Sum).Sum)
                }
            }

            # Process smallest jobs first: on a tight disk each completed job frees source space,
            # and once one job does not fit, no larger one will either.
            $Jobs = @($Jobs | Sort-Object SizeBytes)

            Add-LogMessage "Ending job generation. Jobs to process: $($Jobs.Count)" INFO
            ############## End jobs generation ##############

            ############## Start jobs execution ##############
            foreach ($Job in $Jobs) {
                # Job Try
                try {
                    ############## Start job execution ##############
                    # Conservative default for the catch block: only a freshly-created partial archive
                    # is safe to delete on failure; an archive that already existed must be preserved.
                    $ArchiveExistedBefore = $true

                    $BackupDate = [DateTime]::ParseExact($Job.BackupDate, $StandardDateFormat, $InvariantCulture)
                    $DateFormat = if (-not [string]::IsNullOrWhiteSpace($Rule.DateFormat)) { $Rule.DateFormat } else { $StandardDateFormat }
                    $Timestamp = $BackupDate.ToString($DateFormat, $InvariantCulture)

                    $Prefix = if (-not [string]::IsNullOrWhiteSpace($Rule.ArchiveNamePrefix)) { "$($Rule.ArchiveNamePrefix)_" } else { "" }
                    $Suffix = if (-not [string]::IsNullOrWhiteSpace($Rule.ArchiveNameSuffix)) { "_$($Rule.ArchiveNameSuffix)" } else { "" }
                    # The temp dir is named after the archive base (suffix included), so if someone zips the
                    # temp dir by hand the resulting name already matches the standard archive name.
                    $ArchiveBaseName = "$Prefix$($env:COMPUTERNAME)_$Timestamp$Suffix"
                    $ArchiveName = "$ArchiveBaseName.zip"
                    # Absolute, so it stays correct when 7-Zip's working directory is switched below.
                    $ArchiveFullPath = Join-Path (Resolve-Path -LiteralPath $Rule.DestinationPath).Path $ArchiveName

                    ############## Start free-space pre-flight ##############
                    # Estimate required space and verify the volume(s) can hold it before staging anything.
                    $ExpectedReductionPct = if ($null -ne $Rule.ExpectedCompressionPercent) { [int]$Rule.ExpectedCompressionPercent } else { 0 }
                    $EstimatedArchiveBytes = [int64]($Job.SizeBytes * (1 - $ExpectedReductionPct / 100.0))

                    # If today's archive already exists, 7-Zip rewrites it on update -> reserve its current size.
                    $ArchiveExistedBefore = Test-Path -Path $ArchiveFullPath -PathType Leaf
                    $ExistingArchiveBytes = if ($ArchiveExistedBefore) { (Get-Item -LiteralPath $ArchiveFullPath).Length } else { 0 }

                    # Required space per volume root:
                    #   destination: estimated archive + rewrite headroom + static buffer
                    #   source (keep mode only): full uncompressed temp copy living alongside the originals
                    $DestRoot = [System.IO.Path]::GetPathRoot((Resolve-Path -Path $Rule.DestinationPath).Path)
                    $SourceRoot = [System.IO.Path]::GetPathRoot((Resolve-Path -Path $Rule.SourcePath).Path)
                    $Requirements = @{ $DestRoot = ($EstimatedArchiveBytes + $ExistingArchiveBytes + $SpaceSafetyBufferBytes) }
                    if (-not $Rule.CleanSourceFiles) {
                        if ($Requirements.ContainsKey($SourceRoot)) { $Requirements[$SourceRoot] += $Job.SizeBytes }
                        else { $Requirements[$SourceRoot] = $Job.SizeBytes }
                    }

                    $SpaceOk = $true
                    foreach ($Root in @($Requirements.Keys)) {
                        try { $FreeBytes = (New-Object System.IO.DriveInfo($Root)).AvailableFreeSpace }
                        catch {
                            Add-LogMessage "Could not determine free space on '$Root'. Proceeding without pre-flight check. Error: $($_.Exception.Message)" WARN
                            continue
                        }
                        if ($FreeBytes -lt $Requirements[$Root]) {
                            Add-LogMessage "Insufficient disk space on '$Root' for job '$($Job.Name)': need ~$([math]::Round($Requirements[$Root] / 1MB, 1)) MB, free $([math]::Round($FreeBytes / 1MB, 1)) MB. Skipping this and all larger remaining jobs in this rule." ERROR
                            $SpaceOk = $false
                        }
                    }
                    # Jobs are sorted ascending by size, so nothing larger will fit either.
                    if (-not $SpaceOk) { break }
                    ############## End free-space pre-flight ##############

                    # There are 2 types of jobs: KEEP or DELETE source files
                    Add-LogMessage "Starting Job: '$($Job.Name)'" INFO

                    # Member enumeration is much cheaper than piping each item through ForEach-Object.
                    $FilePaths = @($Job.Files.FullName)

                    # Create TMP container directory for copy/move files.
                    $TmpContainerDirPath = Join-Path -Path $Rule.SourcePath -ChildPath $ArchiveBaseName
                    New-Item -Path $TmpContainerDirPath -ItemType Directory -Force | Out-Null

                    # Stage files into the temp container directory (move vs copy depends on the rule).
                    switch ($Rule.CleanSourceFiles) {
                        $true {
                            Add-LogMessage "Rule '$($Rule.Name)': clean source files mode (originals removed after archiving)." INFO
                            # Move target files one by one with fallback to copy if locked
                            foreach ($FilePath in $FilePaths) {
                                $DestFilePath = Join-Path $TmpContainerDirPath (Split-Path $FilePath -Leaf)
                                try {
                                    [System.IO.File]::Move($FilePath, $DestFilePath)
                                }
                                catch {
                                    Add-LogMessage "File '$FilePath' is locked. Attempting to copy instead..." WARN
                                    try {
                                        [System.IO.File]::Copy($FilePath, $DestFilePath, $true)
                                    }
                                    catch {
                                        throw "Failed to move or copy locked file '$FilePath'. Error: $($_.Exception.Message)"
                                    }
                                }
                            }
                        }
                        $false {
                            Add-LogMessage "Rule '$($Rule.Name)': keep source files mode (originals preserved)." INFO
                            # Copy files to TMP directory
                            foreach ($FilePath in $FilePaths) {
                                try {
                                    [System.IO.File]::Copy($FilePath, (Join-Path $TmpContainerDirPath (Split-Path $FilePath -Leaf)), $true)
                                }
                                catch {
                                    throw "Failed to copy file '$FilePath'. Error: $($_.Exception.Message)"
                                }
                            }
                        }
                        Default { throw "Unknown configuration for the 'CleanSourceFiles' key in rule '$($Rule.Name)'." }
                    }

                    # Compress the staged files. -sdel is intentionally NOT used: the staged copies must
                    # survive until the archive passes its integrity test, so a failed/corrupt archive
                    # leaves the temp dir intact for the leftover-recovery pass on the next run.
                    # 7-Zip is run with its working directory set to the temp dir and given '*', so the
                    # archive stores bare file names rather than the temp dir's path. Both the PowerShell
                    # location and the process CWD are set (Windows PowerShell uses the latter for native
                    # commands, PowerShell 7 the former); both are restored afterwards.
                    $Level = if ($null -ne $Rule.CompressionLevel) { [int]$Rule.CompressionLevel } else { $DefaultCompressionLevel }
                    $ZipAddArgs = @('a', '-tzip', '-mm=Deflate', "-mx=$Level")
                    $PrevCwd = [System.Environment]::CurrentDirectory
                    Push-Location -LiteralPath $TmpContainerDirPath
                    try {
                        [System.Environment]::CurrentDirectory = (Get-Location).Path
                        & $ZipPath $ZipAddArgs $ArchiveFullPath '*'
                    }
                    finally {
                        Pop-Location
                        [System.Environment]::CurrentDirectory = $PrevCwd
                    }
                    if ($LASTEXITCODE -ge 2) { throw "7-Zip process failed with exit code $LASTEXITCODE for archive '$ArchiveFullPath'." }
                    if (-not (Test-Path -Path $ArchiveFullPath -PathType Leaf)) { throw "7-Zip completed but archive was not created at '$ArchiveFullPath'." }

                    # Verify archive integrity BEFORE deleting the staged source files.
                    & $ZipPath t $ArchiveFullPath
                    if ($LASTEXITCODE -ne 0) { throw "Archive integrity test failed with exit code $LASTEXITCODE for '$ArchiveFullPath'." }

                    # Archive verified: it is now safe to remove the staged files.
                    if (Test-Path -Path $TmpContainerDirPath) { Remove-Item -Path $TmpContainerDirPath -Force -Recurse -ErrorAction SilentlyContinue }

                    ############## End job execution ##############

                    ############## Start receipt generation ##############
                    $UFormat = Get-Date -Date $Job.UTC -UFormat %s
                    $ReceiptFilePath = "$ReceiptPath\$($Job.Name)_$UFormat.json"
                    $JobReceipt = @{
                        Name    = $Job.Name
                        UTC     = $Job.UTC.ToString('o')
                        Archive = $ArchiveFullPath                        
                        Files   = $Job.FilesInfo
                    }

                    $JobReceipt | ConvertTo-Json -Depth 3 | Set-Content -Path $ReceiptFilePath -Encoding utf8
                    ############## End receipt generation ##############                
                }
                # Job Catch
                catch {
                    Add-LogMessage "Job '$($Job.Name)' failed. Error: $_" ERROR
                    # Remove a partial archive only if this job created it (preserve a pre-existing one
                    # that may already hold data from an earlier run on the same day).
                    if (-not $ArchiveExistedBefore -and (Test-Path -Path $ArchiveFullPath -PathType Leaf)) {
                        Add-LogMessage "Removing partial archive '$ArchiveFullPath' left by the failed job." WARN
                        Remove-Item -Path $ArchiveFullPath -Force -ErrorAction SilentlyContinue
                    }
                }
                # Job Finally
                finally {
                    Add-LogMessage "Ending Job: '$($Job.Name)'" INFO
                }
            }
            ############## End jobs execution ##############
        }
        # Rule catch
        catch { Add-LogMessage "Failed to process rule: '$($Rule.Name)'. Error: $_" ERROR }
        # Rule finally
        finally { Add-LogMessage "Finished rule: '$($Rule.Name)'" INFO }
    }
    ############## End rules processing ##############
}
# global catch
catch { Add-LogMessage "CRITICAL: Unhandled error. Script cannot continue. Error: $_" ERROR }
# global finally
finally {
    ############## Finalize: write summary, set exit code, stop logger ##############
    $Stats = Get-LogStats
    if ($Stats.Errors -gt 0) {
        Add-LogMessage "Script finished with $($Stats.Errors) error(s) and $($Stats.Warnings) warning(s)." ERROR
    }
    elseif ($Stats.Warnings -gt 0) {
        Add-LogMessage "Script finished with $($Stats.Warnings) warning(s)." WARN
    }
    else {
        Add-LogMessage "Script finished successfully." INFO
    }
    Add-LogMessage "Stopping Script" INFO
    Stop-LogProcessor
    if ($Stats.Errors -gt 0) { exit 2 }
    elseif ($Stats.Warnings -gt 0) { exit 1 }
}
