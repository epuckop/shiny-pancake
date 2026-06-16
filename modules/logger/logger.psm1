<#
.SYNOPSIS
    Provides a set of functions for thread-safe, asynchronous logging.
.DESCRIPTION
    This module implements a producer-consumer pattern for logging from multiple PowerShell threads or runspaces.
    It is fully self-contained and manages its own state.
.NOTES
    Author: Dmitry Goldenberg
#>

#-----------------------------------------------------------------------------------
# Private Module State (using the $script scope)
#-----------------------------------------------------------------------------------
$script:LogQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[string]
# Note: use New-Object (not [type]::new(), which requires PowerShell 5+) to keep PowerShell 4 compatibility.
$script:StopEvent = New-Object System.Threading.ManualResetEventSlim -ArgumentList $false
$script:LoggerPowerShell = $null
$script:LoggerRunspace = $null
$script:LoggerHandle = $null
$script:WarnCount = 0
$script:ErrorCount = 0

# The script block for the consumer thread. It defines parameters it expects to receive.
$script:LoggerScript = {
    param($Queue, $LogPath, $StopEvent)

    # Main consumer loop: processes the queue until the stop event is set.
    while (-not $StopEvent.IsSet) {
        $Message = $null
        while ($Queue.TryDequeue([ref]$Message)) { Add-Content -Path $LogPath -Value $Message -Encoding UTF8 }
        # Suppress Wait()'s boolean return so it does not leak into the runspace output stream.
        $null = $StopEvent.Wait(100)
    }

    # Final cleanup: ensure any messages remaining in the queue after the stop event is set are written.
    $Message = $null
    while ($Queue.TryDequeue([ref]$Message)) { Add-Content -Path $LogPath -Value $Message -Encoding UTF8 }
}

#-----------------------------------------------------------------------------------
# Public Functions
#-----------------------------------------------------------------------------------

function Add-LogMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet("INFO", "WARN", "ERROR", "DEBUG")][string]$Level = "INFO"
    )
    if ($Level -eq 'WARN') { $script:WarnCount++ }
    elseif ($Level -eq 'ERROR') { $script:ErrorCount++ }
    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    $LogEntry = "[$Timestamp]   [$Level]    [Thread-$ThreadId]  $Message"
    $script:LogQueue.Enqueue($LogEntry)
}

function Start-LogProcessor {
    param( [Parameter(Mandatory = $true)][string]$LogFilePath )

    $LogDirectory = Split-Path -Path $LogFilePath -Parent
    if (-not (Test-Path -Path $LogDirectory)) { $null = New-Item -Path $LogDirectory -ItemType Directory -Force }

    $script:WarnCount = 0
    $script:ErrorCount = 0
    $script:StopEvent.Reset()
    $Rs = [runspacefactory]::CreateRunspace()
    $Rs.Open()

    $Ps = [powershell]::Create()
    $Ps.Runspace = $Rs
    $null = $Ps.AddScript($script:LoggerScript).AddArgument($script:LogQueue).AddArgument($LogFilePath).AddArgument($script:StopEvent)

    $script:LoggerHandle = $Ps.BeginInvoke()
    $script:LoggerPowerShell = $Ps
    $script:LoggerRunspace = $Rs
    Add-LogMessage "Log processor started. Writing to: $LogFilePath" INFO
}

function Stop-LogProcessor {
    $script:StopEvent.Set()

    if ($script:LoggerPowerShell -and $script:LoggerHandle) {
        # Wrap shutdown so a background write error surfaced by EndInvoke never escapes
        # (the global finally must always reach its exit-code logic). Output is suppressed.
        try { $null = $script:LoggerPowerShell.EndInvoke($script:LoggerHandle) }
        catch { [Console]::Error.WriteLine("Logger background ended with an error: $($_.Exception.Message)") }
        finally {
            $script:LoggerPowerShell.Dispose()
            $script:LoggerRunspace.Dispose()
        }
    }
}

function Get-LogStats {
    return [pscustomobject]@{
        Warnings = $script:WarnCount
        Errors   = $script:ErrorCount
    }
}

Export-ModuleMember -Function Add-LogMessage, Start-LogProcessor, Stop-LogProcessor, Get-LogStats