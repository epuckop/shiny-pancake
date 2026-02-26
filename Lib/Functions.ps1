# =============================================================================
# Functions.ps1
# Helper functions for PowerShell Log Collector & Archiver.
# Contains no execution logic and produces no side effects.
# =============================================================================

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped entry to the daily log file.

    .DESCRIPTION
        Appends a formatted log entry to a date-named file in the logs\ directory
        relative to $script:RootPath. Intended to replace Write-Host across the project.
        Optionally echoes the entry to the console when $script:VerboseLogging is $true.

    .PARAMETER Message
        The message text to log.

    .PARAMETER Level
        Severity level of the entry. Accepted values: INFO, WARN, ERROR, DEBUG.
        Defaults to INFO.

    .EXAMPLE
        Write-Log -Message "Processing rule: AppLogs" -Level INFO
        Write-Log -Message "Source path not found" -Level WARN
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )

    $logDir = Join-Path $script:RootPath "logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null
    }

    $logFile = Join-Path $logDir ((Get-Date -Format "yyyy-MM-dd") + ".log")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    $utf8NoBOM = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::AppendAllText($logFile, "$logEntry`r`n", $utf8NoBOM)

    if ($script:VerboseLogging) {
        Write-Host $logEntry
    }
}

# -----------------------------------------------------------------------------
# 7-Zip
# -----------------------------------------------------------------------------

function Get-SevenZipPath {
    <#
    .SYNOPSIS
        Locates the 7z.exe executable on the system.

    .DESCRIPTION
        Searches standard installation directories and the Windows registry for 7z.exe.
        Throws a terminating exception if 7-Zip is not found, halting script execution.

    .OUTPUTS
        [string] Full path to 7z.exe.

    .EXAMPLE
        $script:SevenZipPath = Get-SevenZipPath
    #>

    $candidates = @(
        (Join-Path $env:ProgramFiles "7-Zip\7z.exe")
    )

    # Program Files (x86) exists only on 64-bit systems
    if (${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe"
    }

    # Registry — HKLM 64-bit and 32-bit (WOW6432Node) keys
    $registryKeys = @(
        "HKLM:\SOFTWARE\7-Zip",
        "HKLM:\SOFTWARE\WOW6432Node\7-Zip"
    )

    foreach ($key in $registryKeys) {
        if (Test-Path $key) {
            $regValue = Get-ItemProperty -Path $key -Name "Path" -ErrorAction SilentlyContinue
            if ($regValue -and $regValue.Path) {
                $candidates += Join-Path $regValue.Path "7z.exe"
            }
        }
    }

    foreach ($path in $candidates) {
        if (Test-Path $path) {
            return $path
        }
    }

    throw "7-Zip executable (7z.exe) not found. Ensure 7-Zip is installed on this server."
}
