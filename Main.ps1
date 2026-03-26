<#
.SYNOPSIS
    This script provides a multi-stage process for archiving and rotating log files based on a JSON configuration.
.DESCRIPTION
    The script operates in several distinct stages for each rule defined in the configuration file.
.PARAMETER JsonConfigPath
    Path to the JSON file containing archiving rules. Defaults to 'configurations\directories_list.json'.
.PARAMETER LogFile
    Path to the log file for this execution. Defaults to a dated file in the 'logs\' directory.
.NOTES
    Author: Dmitry Goldenberg
    Compatibility: Windows PowerShell 4 and later.
#>

param(
    [string]$JsonConfigPath = (Join-Path $PSScriptRoot "configurations\directories_list.json"),
    [string]$LogFile = (Join-Path $PSScriptRoot "logs\log_$(Get-Date -Format "yyyy-MM-dd").log")
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
$ZipArgumentsSDel = @(
    'a',
    '-tzip',
    '-mm=Deflate',
    '-mx=9',
    '-sdel'
)

# Receipt path
$ReceiptPath = (Join-Path $PSScriptRoot "receipt\$(Get-Date -Format "yyyy-MM-dd")")

###################################################
########## Ending Script global settings ##########
###################################################

######################################################
############## Import requested modules ##############
######################################################

# Import logger
try { Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules\logger') -ErrorAction Stop }
catch { throw "Critical Error: 'modules\logger' not found or failed to load. Script cannot continue. `nError: $_" }

# Import file reader
try { Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules\fileimport') -ErrorAction Stop }
catch { throw "Critical Error: 'modules\fileimport' not found or failed to load. Script cannot continue. `nError: $_" }

#################################################
############## Starting main logic ##############
#################################################

# global try
try {
    ############## Start logger ##############
    Start-LogProcessor -LogFilePath $LogFile
    Add-LogMessage "Starting Script" INFO

    ############## Start Prerequisites Validation ##############
    # Description: Running pre-flight checks to ensure the environment is ready for execution.

    # Check for 7-Zip and verify it is functional
    if (-not (Test-Path -Path $ZipPath -PathType Leaf)) {
        Add-LogMessage "Prerequisite failed: 7-Zip executable not found at '$ZipPath'." ERROR
        throw "Prerequisite failed: 7-Zip executable not found at '$ZipPath'."
    }

    $ZipOutput = & $ZipPath 2>&1
    if ($LASTEXITCODE -eq 0) {
        $ZipVersion = ($ZipOutput | Select-String '7-Zip').Line.Trim()
        Add-LogMessage "Prerequisite succeed: 7-Zip is functional. $ZipVersion" INFO
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
    }

    if (-not $ConfigValid) {
        throw "CRITICAL: Configuration validation failed. Fix the config and re-run."
    }
    Add-LogMessage "Configuration validation passed: $($Configurations.Count) rule(s) validated." INFO

    # Create folder for receipt
    if (-not (Test-Path -Path $ReceiptPath -PathType Container)) { New-Item -Path $ReceiptPath -ItemType Directory -Force }
    ############## End Prerequisites Validation ##############

    ############## Start rules processing ##############
    # Process each rule from the configuration. A single Rule may generate multiple Jobs 
    # (e.g., one Job per day) if CleanSourceFiles is enabled.
    foreach ($Rule in $Configurations) {
        # Rule try
        try {
            Add-LogMessage "Starting rule: '$($Rule.Name)'" INFO

            ############## Start rule Prerequisites validation ##############
            # Validate source paths from config.            
            if (-not (Test-Path -Path $Rule.SourcePath -PathType Container)) {
                Add-LogMessage "Source directory '$($Rule.SourcePath)' not found. Skipping rule." WARN
                continue
            }

            # Validate destination paths from config.
            if (-not (Test-Path -Path $Rule.DestinationPath -PathType Container)) {
                Add-LogMessage "Destination directory '$($Rule.DestinationPath)' is not found. Skipping rule." ERROR
                continue
            }
            Add-LogMessage "Paths for rule '$($Rule.Name)' are validated." INFO

            # Validate target files existence & target files list preparation
            # Get all files from the source directory.
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
                Add-LogMessage "This rule '$($Rule.Name)' can have few jobs" INFO

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
                    Add-LogMessage "Starting processing date group: '$($DateGroup.Name)'" INFO
                    
                    $BackupDateName = [DateTime]::ParseExact($DateGroup.Name, $StandardDateFormat, $InvariantCulture)
                    $JobName = if (-not [string]::IsNullOrWhiteSpace($Rule.ArchiveNamePrefix)) { "$($Rule.ArchiveNamePrefix)_$($BackupDateName.ToString($StandardDateFormat))" } else { "$($Rule.Name)_$($BackupDateName.ToString($StandardDateFormat))" }

                    $FilesToStageWithInfo = @()
                    foreach ($File in $DateGroup.Group) {
                        $FilesToStageWithInfo += [pscustomobject]@{
                            Name             = $File.Name
                            LastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
                        }                            
                    }

                    $Jobs += [pscustomobject]@{
                        Name       = $JobName
                        BackupDate = $DateGroup.Name
                        UTC        = (Get-Date).ToUniversalTime()
                        FilesInfo  = $FilesToStageWithInfo
                        Files      = $DateGroup.Group
                    }                        

                    Add-LogMessage "Ending processing date group: '$($DateGroup.Name)'" INFO
                }
            }
            else { 
                Add-LogMessage "This rule '$($Rule.Name)' have only one job." INFO

                $JobName = if (-not [string]::IsNullOrWhiteSpace($Rule.ArchiveNamePrefix)) { $Rule.ArchiveNamePrefix } else { $Rule.Name }
                $BackupDateString = (Get-Date).ToString($StandardDateFormat, $InvariantCulture)

                $FilesToStageWithInfo = @()
                foreach ($File in $FilteredFiles) {
                    $FilesToStageWithInfo += [pscustomobject]@{
                        Name             = $File.Name
                        LastWriteTimeUtc = $File.LastWriteTimeUtc.ToString('o')
                    }                            
                }

                $Jobs += [pscustomobject]@{
                    Name       = $JobName
                    BackupDate = $BackupDateString
                    UTC        = (Get-Date).ToUniversalTime()
                    FilesInfo  = $FilesToStageWithInfo
                    Files      = $FilteredFiles
                }                        
            }

            Add-LogMessage "Ending job generation. Jobs to process: $($Jobs.Count)" INFO
            ############## End jobs generation ##############

            ############## Start jobs execution ##############
            foreach ($Job in $Jobs) {
                # Job Try
                try {                    
                    ############## Start job execution ##############                    
                    $BackupDate = [DateTime]::ParseExact($Job.BackupDate, $StandardDateFormat, $InvariantCulture)
                    $DateFormat = if (-not [string]::IsNullOrWhiteSpace($Rule.DateFormat)) { $Rule.DateFormat } else { $StandardDateFormat }
                    $Timestamp = $BackupDate.ToString($DateFormat, $InvariantCulture)

                    $Prefix = if (-not [string]::IsNullOrWhiteSpace($Rule.ArchiveNamePrefix)) { "$($Rule.ArchiveNamePrefix)_" } else { "" }
                    $Suffix = if (-not [string]::IsNullOrWhiteSpace($Rule.ArchiveNameSuffix)) { "_$($Rule.ArchiveNameSuffix)" } else { "" }
                    $ArchiveName = "$Prefix$($env:COMPUTERNAME)_$Timestamp$Suffix.zip"
                    $ArchiveFullPath = Join-Path -Path $Rule.DestinationPath -ChildPath $ArchiveName

                    # There are 2 types of jobs: KEEP or DELETE source files
                    Add-LogMessage "Starting Job: '$($Job.Name)'" INFO

                    $FilePaths = $Job.Files | ForEach-Object { $_.FullName }

                    # Create TMP container directory for copy/move files.
                    $TmpContainerDirPath = Join-Path -Path $Rule.SourcePath -ChildPath "$Prefix$($env:COMPUTERNAME)_$Timestamp"
                    New-Item -Path $TmpContainerDirPath -ItemType Directory -Force

                    switch ($Rule.CleanSourceFiles) {
                        $true {
                            Add-LogMessage "Rule name: '$($Rule.Name)'. Clean source files" INFO
                            # Move target files to it
                            Move-Item -Path $FilePaths -Destination $TmpContainerDirPath -Force -ErrorAction Stop
                            # Compress that directory with remove src flag
                            & $ZipPath $ZipArgumentsSDel $ArchiveFullPath (Join-Path $TmpContainerDirPath "*")
                            if ($LASTEXITCODE -ge 2) { throw "7-Zip process failed with exit code $LASTEXITCODE for archive '$ArchiveFullPath'." }
                            if (-not (Test-Path -Path $ArchiveFullPath -PathType Leaf)) { throw "7-Zip completed but archive was not created at '$ArchiveFullPath'." }
                            # remove empty TMP directory
                            if (Test-Path -Path $TmpContainerDirPath) { Remove-Item -Path $TmpContainerDirPath -Force -ErrorAction SilentlyContinue }
                        }
                        $false {
                            Add-LogMessage "Rule name: '$($Rule.Name)'. Keep source files" INFO
                            # Copy files to TMP directory
                            Copy-Item -LiteralPath $FilePaths -Destination $TmpContainerDirPath -Force -ErrorAction Stop
                            # Compress that directory with remove src flag
                            & $ZipPath $ZipArgumentsSDel $ArchiveFullPath (Join-Path $TmpContainerDirPath "*")
                            if ($LASTEXITCODE -ge 2) { throw "7-Zip process failed with exit code $LASTEXITCODE for archive '$ArchiveFullPath'." }
                            if (-not (Test-Path -Path $ArchiveFullPath -PathType Leaf)) { throw "7-Zip completed but archive was not created at '$ArchiveFullPath'." }
                            # remove TMP directory
                            if (Test-Path -Path $TmpContainerDirPath) { Remove-Item -Path $TmpContainerDirPath -Force -ErrorAction SilentlyContinue }
                        }
                        Default { Add-LogMessage "Rule name: '$($Rule.Name)'. Unknown configuration for the 'CleanSourceFiles' key." ERROR; continue }
                    }

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
                    Add-LogMessage "ERROR Job: '$($Job.Name)'. Error: $_" ERROR
                }
                # Job Finally
                finally {
                    Add-LogMessage "Ending Job: '$($Job.Name)'" INFO
                }
            }
            ############## End jobs execution ##############
        }
        # Rule catch
        catch { Add-LogMessage "Failed to process rule: '$($Rule.Name)'. Error: $_" WARN }
        # Rule finally
        finally { Add-LogMessage "Finished rule: '$($Rule.Name)'" INFO }
    }
    ############## End rules processing ##############
}
# global catch
catch { throw "Critical Error: Script cannot continue. Error: $_" }
# global finally
finally {
    ############## Stop logger ##############
    try { Add-LogMessage "Stopping Script" INFO }
    finally { Write-Host "Stopping Script" }    
    Stop-LogProcessor
}
