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
$script:StopEvent = [System.Threading.ManualResetEventSlim]::new($false)
$script:LoggerPowerShell = $null
$script:LoggerRunspace = $null
$script:LoggerHandle = $null

# The script block for the consumer thread. It defines parameters it expects to receive.
$script:LoggerScript = {
    param($Queue, $LogPath, $StopEvent)

    # Main consumer loop: processes the queue until the stop event is set.
    while (-not $StopEvent.IsSet) {
        $Message = $null
        while ($Queue.TryDequeue([ref]$Message)) { Add-Content -Path $LogPath -Value $Message -Encoding UTF8 }
        $StopEvent.Wait(100)
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
    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    $LogEntry = "[$Timestamp]   [$Level]    [Thread-$ThreadId]  $Message"
    $script:LogQueue.Enqueue($LogEntry)
}

function Start-LogProcessor {
    param( [Parameter(Mandatory = $true)][string]$LogFilePath )

    $LogDirectory = Split-Path -Path $LogFilePath -Parent
    if (-not (Test-Path -Path $LogDirectory)) { New-Item -Path $LogDirectory -ItemType Directory -Force }

    $script:StopEvent.Reset()
    $Rs = [runspacefactory]::CreateRunspace()
    $Rs.Open()

    $Ps = [powershell]::Create()
    $Ps.Runspace = $Rs
    $null = $Ps.AddScript($script:LoggerScript).AddArgument($script:LogQueue).AddArgument($LogFilePath).AddArgument($script:StopEvent)

    $script:LoggerHandle = $Ps.BeginInvoke()
    $script:LoggerPowerShell = $Ps
    $script:LoggerRunspace = $Rs

    Write-Host "Log processor started. Writing to: $LogFilePath"
}

function Stop-LogProcessor {
    Write-Host "Stopping the log processor..."
    $script:StopEvent.Set()

    if ($script:LoggerPowerShell -and $script:LoggerHandle) {
        $script:LoggerPowerShell.EndInvoke($script:LoggerHandle)
        $script:LoggerPowerShell.Dispose()
        $script:LoggerRunspace.Dispose()
    }
    Write-Host "Log processor stopped. Remaining queue items: $($script:LogQueue.Count)"
}

Export-ModuleMember -Function Add-LogMessage, Start-LogProcessor, Stop-LogProcessor