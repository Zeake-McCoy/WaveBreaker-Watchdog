cls
#region Configuration

# List of applications to monitor, including their full paths and process names
$ApplicationsToMonitor = @(
    @{ Name = "Nexus Controller"; Path = "C:\Users\admin\Desktop\ControllerV3\NGController.exe"; ProcessName = "NGController" },
    @{ Name = "WB Instance Lobby"; Path = "C:\NEXUS-V3\Server_WB-Instance-Lobby\Torch.Server.exe"; ProcessName = "Torch.Server" },
    @{ Name = "WB Instance Root"; Path = "C:\NEXUS-V3\Server_WB-Instance-Root\Torch.Server.exe"; ProcessName = "Torch.Server" },
    @{ Name = "WB Instance 1"; Path = "C:\NEXUS-V3\Server_WB-Instance-1\Torch.Server.exe"; ProcessName = "Torch.Server" },
    @{ Name = "WB Instance 2"; Path = "C:\NEXUS-V3\Server_WB-Instance-2\Torch.Server.exe"; ProcessName = "Torch.Server" },
    @{ Name = "WB Instance 3"; Path = "C:\NEXUS-V3\Server_WB-Instance-3\Torch.Server.exe"; ProcessName = "Torch.Server" },
    @{ Name = "WB Instance 4"; Path = "C:\NEXUS-V3\Server_WB-Instance-4\Torch.Server.exe"; ProcessName = "Torch.Server" }
#    @{ Name = "WB Creative"; Path = "C:\NEXUS-V3\Server_WB-Instance-Creative\Torch.Server.exe"; ProcessName = "Torch.Server" }
)

# Discord Webhook URL
$DiscordWebhookUrl = "<YOUR_DISCORD_WEBHOOK_URL>"

# How often to check (in seconds)
$CheckIntervalSeconds = 60

# How often to pause for restarts (in hours)
$PauseIntervalHours = 6

# Duration of the pause (in minutes)
$PauseDurationMinutes = 5

# Threshold for CPU usage to consider an app frozen (e.g., 0.1%)
$FrozenCpuThreshold = 0.9

# Process termination verification settings
$TerminationPollSeconds = 5
$TerminationWaitSeconds = 20

# Anchor time for pause intervals (e.g., 3 AM, aligning with server restarts)
$AnchorTime = [datetime]::ParseExact("02:59", "HH:mm", $null)

#endregion ------------------------------------------------------------------

#region Helper Function for Discord Notifications
function Send-DiscordNotification {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message
    )

    Write-Host "[DISCORD NOTIFICATION] Sending message: $Message" -ForegroundColor Blue -BackgroundColor DarkYellow

    if (-not $DiscordWebhookUrl) {
        Write-Host "[DISCORD NOTIFICATION] Discord Webhook URL is not configured. Skipping notification." -ForegroundColor Blue -BackgroundColor Yellow
        return
    }

    $payload = @{
        content = $Message
    }

    try {
        Invoke-RestMethod -Uri $DiscordWebhookUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 100) -ContentType 'application/json'
        Write-Host "[DISCORD NOTIFICATION] Message sent successfully." -ForegroundColor Blue -BackgroundColor Green
    } catch {
        Write-Host "[DISCORD NOTIFICATION] Failed to send Discord notification: $($_.Exception.Message)" -ForegroundColor Cyan -BackgroundColor Red
    }
}
#endregion ------------------------------------------------------------------

#region Webhook Test Function
function Test-DiscordWebhook {
    Write-Host "Attempting to send a test message to Discord..." -ForegroundColor Blue -BackgroundColor Gray

    $TestMessage = "**WB Watchdog** Starting Script and Testing Webhook."

    if (-not $DiscordWebhookUrl) {
        Write-Host "Discord Webhook URL is not configured. Please update the `$DiscordWebhookUrl variable with your actual webhook URL." -ForegroundColor Cyan -BackgroundColor Red
        return $false # Indicate failure
    }

    # Prepare the payload for the Discord API
    $payload = @{
        content = $TestMessage
    }

    try {
        # Send the message using Invoke-RestMethod
        Invoke-RestMethod -Uri $DiscordWebhookUrl -Method Post -Body ($payload | ConvertTo-Json -Depth 100) -ContentType 'application/json'
        Write-Host "[SUCCESS] Test message sent to Discord successfully! Check your Discord channel." -ForegroundColor Blue -BackgroundColor Green
        return $true # Indicate success
    } catch {
        # If an error occurs, display the error message
        Write-Host "[ERROR] Failed to send test message to Discord." -ForegroundColor Cyan -BackgroundColor Red
        Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Blue -BackgroundColor Yellow
        Write-Host "Please ensure the webhook URL is correct and that your server has internet access." -ForegroundColor Blue -BackgroundColor Yellow
        return $false # Indicate failure
    }
}
#endregion ------------------------------------------------------------------

#region Process Recovery Helpers
function Get-MatchingProcesses {
    param(
        [Parameter(Mandatory=$true)][string]$ProcessName,
        [Parameter(Mandatory=$true)][string]$ProcessPath
    )

    @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $ProcessPath } catch { $false }
    })
}

function Stop-AndVerifyProcesses {
    param(
        [Parameter(Mandatory=$true)][int[]]$ProcessIds,
        [Parameter(Mandatory=$true)][string]$AppName,
        [Parameter(Mandatory=$true)][string]$ProcessName,
        [Parameter(Mandatory=$true)][string]$ProcessPath
    )

    $targetIds = @($ProcessIds | Select-Object -Unique)
    if ($targetIds.Count -eq 0) { return $true }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        foreach ($id in $targetIds) {
            $stillThere = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($stillThere) {
                try {
                    Write-Host "[RECOVERY] Force-stopping '$AppName' PID $id (attempt $attempt)." -ForegroundColor Yellow
                    Stop-Process -Id $id -Force -ErrorAction Stop
                } catch {
                    Write-Host "[RECOVERY] Stop request for PID $id reported: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }

        $deadline = (Get-Date).AddSeconds($TerminationWaitSeconds)
        do {
            Start-Sleep -Seconds $TerminationPollSeconds
            $remaining = @($targetIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
            if ($remaining.Count -eq 0) {
                Write-Host "[RECOVERY] All targeted PIDs for '$AppName' have exited." -ForegroundColor Green
                return $true
            }
            Write-Host "[RECOVERY] '$AppName' still has targeted PID(s): $($remaining -join ', '). Polling again..." -ForegroundColor Yellow
        } while ((Get-Date) -lt $deadline)

        if ($attempt -eq 1) {
            Write-Host "[RECOVERY] 20-second wait expired for '$AppName'. Issuing one more forced termination attempt." -ForegroundColor Yellow
        }
    }

    $remaining = @($targetIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($remaining.Count -gt 0) {
        $message = ":x: **Watchdog could not terminate $AppName**. Remaining PID(s): $($remaining -join ', '). Restart aborted."
        Write-Host "[RECOVERY] $message" -ForegroundColor Red
        Send-DiscordNotification -Message $message
        return $false
    }
    return $true
}

function Start-VerifiedApplication {
    param(
        [Parameter(Mandatory=$true)][string]$AppName,
        [Parameter(Mandatory=$true)][string]$ProcessName,
        [Parameter(Mandatory=$true)][string]$ProcessPath,
        [Parameter(Mandatory=$true)][string]$Reason
    )

    # Recheck immediately before launch; never create a duplicate knowingly.
    $existing = @(Get-MatchingProcesses -ProcessName $ProcessName -ProcessPath $ProcessPath)
    if ($existing.Count -gt 0) {
        Write-Host "[RECOVERY] Restart of '$AppName' aborted: matching PID(s) appeared: $($existing.Id -join ', ')." -ForegroundColor Red
        return $false
    }

    try {
        Write-Host "[RECOVERY] Starting '$AppName' after $Reason." -ForegroundColor Yellow
        Start-Process -FilePath $ProcessPath -ErrorAction Stop
        $message = ":white_check_mark: **$AppName** ($ProcessName) was restarted after $Reason."
        Send-DiscordNotification -Message $message
        return $true
    } catch {
        $message = ":x: **Error restarting $AppName** ($ProcessName): $($_.Exception.Message)"
        Write-Host "[RECOVERY] $message" -ForegroundColor Red
        Send-DiscordNotification -Message $message
        return $false
    }
}
#endregion ------------------------------------------------------------------

#region Main Script Logic

Write-Host "[MAIN] Starting Wavebreaker Watchdog Script..." -ForegroundColor Cyan -BackgroundColor Magenta

# Test the Discord webhook connectivity
$webhookTestResult = Test-DiscordWebhook

if (-not $webhookTestResult) {
    Write-Host "[MAIN] Webhook test failed. Exiting script." -ForegroundColor Blue -BackgroundColor Red
    exit # Exit the script if the webhook test fails
}

# Initialize lastPauseTriggerTime to a value that ensures the first check is not immediately a pause
# I want the first pause to occur at the first scheduled interval *after* the script starts, 
# considering the anchor time.
$currentTime = Get-Date
$lastPauseTriggerTime = $AnchorTime
while ($lastPauseTriggerTime -lt $currentTime) {
    $lastPauseTriggerTime = $lastPauseTriggerTime.AddHours($PauseIntervalHours)
}
$lastPauseTriggerTime = $lastPauseTriggerTime.AddHours(-$PauseIntervalHours) # Subtract one interval
Write-Host "[MAIN] Initialized last pause trigger time to: $lastPauseTriggerTime" -ForegroundColor Blue -BackgroundColor Gray


while ($true) {
    $currentTime = Get-Date
    Write-Host "[MAIN] Current time: $currentTime. Checking status..." -ForegroundColor Blue -BackgroundColor Gray

    # Pause Logic
    Write-Host "[MAIN] Checking pause logic. Last pause trigger: $lastPauseTriggerTime. Current time: $currentTime." -ForegroundColor Blue -BackgroundColor Gray

    # Calculate the next scheduled pause time based on the anchor and interval
    $nextScheduledPause = $AnchorTime
    while ($nextScheduledPause -lt $currentTime) {
        $nextScheduledPause = $nextScheduledPause.AddHours($PauseIntervalHours)
    }

    # Check if the current time is within the pause window (i.e., after the last pause trigger and before the next scheduled pause)
    # also need to consider the case where the script starts *during* a pause window.
    # A simpler approach is to check if the current time falls into any of the 6-hour intervals starting from AnchorTime.
    
    $isPauseTime = $false
    $tempCheckTime = $AnchorTime
    while ($tempCheckTime -lt $currentTime.AddHours(1)) { # Check a bit into the future to catch current pauses
        if ($currentTime -ge $tempCheckTime -and $currentTime -lt $tempCheckTime.AddMinutes($PauseDurationMinutes)) {
            $isPauseTime = $true
            break
        }
        $tempCheckTime = $tempCheckTime.AddHours($PauseIntervalHours)
    }

    if ($isPauseTime) {
        Write-Host "[MAIN] Currently within a scheduled pause period (for $PauseDurationMinutes minutes). Skipping application checks." -ForegroundColor Blue -BackgroundColor Yellow
        # Optionally send a notification that we are in a pause period, but avoid spamming
        # Need to consider adding a flag to only send this once per pause period.

        # Send status message upon restart cycle
        $pauseMessage = ":zzz: **WB Watchdog** is entering a pause period for scheduled application restarts. Monitoring will resume shortly."
        Send-DiscordNotification -Message $pauseMessage
        
        # Sleep for the pause duration
        $PauseDurationSeconds = $PauseDurationMinutes * 60  # Calculate pause duration in seconds
        Write-Host "[MAIN] Sleeping for $PauseDurationSeconds seconds during pause." -ForegroundColor Blue -BackgroundColor DarkYellow
        Start-Sleep -Seconds $PauseDurationSeconds
    } 
    else {
        # If not in a pause period, proceed with application monitoring
        Write-Host "[MAIN] Not in a pause period. Proceeding with application monitoring." -ForegroundColor Blue -BackgroundColor Gray

# Application Monitoring
Write-Host "[MAIN] Starting application monitoring loop." -ForegroundColor Blue -BackgroundColor Gray
foreach ($app in $ApplicationsToMonitor) {
    $processName = $app.ProcessName
    $processPath = $app.Path
    $appName = $app.Name

    Write-Host "[MONITOR] Checking application: '$appName' (Process: '$processName', Path: '$processPath')" -ForegroundColor Blue -BackgroundColor Gray

    $processes = @(Get-MatchingProcesses -ProcessName $processName -ProcessPath $processPath)

    # Duplicate detection runs before CPU sampling. Terminate every matching PID.
    if ($processes.Count -gt 1) {
        $duplicateIds = @($processes | ForEach-Object { [int]$_.Id })
        Write-Host "[MONITOR] DUPLICATE DETECTED for '$appName'. Matching PIDs: $($duplicateIds -join ', '). Terminating all." -ForegroundColor Red
        $stopped = Stop-AndVerifyProcesses -ProcessIds $duplicateIds -AppName $appName -ProcessName $processName -ProcessPath $processPath
        if ($stopped) {
            # Recheck path after termination; if anything remains, do not start another copy.
            $remainingMatches = @(Get-MatchingProcesses -ProcessName $processName -ProcessPath $processPath)
            if ($remainingMatches.Count -eq 0) {
                [void](Start-VerifiedApplication -AppName $appName -ProcessName $processName -ProcessPath $processPath -Reason "duplicate-process cleanup")
            } else {
                $message = ":x: **$appName** still has matching PID(s) after duplicate cleanup: $(($remainingMatches | ForEach-Object Id) -join ', '). Restart aborted."
                Write-Host "[MONITOR] $message" -ForegroundColor Red
                Send-DiscordNotification -Message $message
            }
        }
        continue
    }

    if ($processes.Count -eq 0) {
        Write-Host "[MONITOR] '$appName' is NOT running. Attempting to start..." -ForegroundColor Yellow
        [void](Start-VerifiedApplication -AppName $appName -ProcessName $processName -ProcessPath $processPath -Reason "it was not running")
        continue
    }

    # Exactly one matching process remains.
    $process = $processes[0]
    Write-Host "[MONITOR] '$appName' is running. PID: $($process.Id)." -ForegroundColor Green

    # Exclude Nexus Controller from freeze check.
    if ($appName -eq "Nexus Controller") {
        Write-Host "[MONITOR] Skipping freeze check for Nexus Controller." -ForegroundColor Yellow
        continue
    }

    # CPU sampling remains unchanged (5-second sample).
    $sampleInterval = 5
    try {
        $startCpuTime = (Get-Process -Id $process.Id -ErrorAction Stop).CPU
        Start-Sleep -Seconds $sampleInterval
        $sampledProcess = Get-Process -Id $process.Id -ErrorAction Stop
        $endCpuTime = $sampledProcess.CPU
        $cpuUsage = (($endCpuTime - $startCpuTime) / $sampleInterval) * 100
    } catch {
        Write-Host "[MONITOR] PID $($process.Id) exited or became unavailable during CPU sampling. Next cycle will re-evaluate." -ForegroundColor Yellow
        continue
    }

    Write-Host "[MONITOR] CPU Usage for '$appName': $cpuUsage%." -ForegroundColor Green

    if ($cpuUsage -lt $FrozenCpuThreshold) {
        Write-Host "[MONITOR] '$appName' appears frozen (CPU < $($FrozenCpuThreshold)%)." -ForegroundColor Red
        $stopped = Stop-AndVerifyProcesses -ProcessIds @([int]$process.Id) -AppName $appName -ProcessName $processName -ProcessPath $processPath
        if ($stopped) {
            # If a matching process appeared during termination, clean it up too before restart.
            $lateMatches = @(Get-MatchingProcesses -ProcessName $processName -ProcessPath $processPath)
            if ($lateMatches.Count -gt 0) {
                $lateIds = @($lateMatches | ForEach-Object { [int]$_.Id })
                Write-Host "[MONITOR] Matching PID(s) appeared during freeze recovery: $($lateIds -join ', '). Terminating before restart." -ForegroundColor Yellow
                $stopped = Stop-AndVerifyProcesses -ProcessIds $lateIds -AppName $appName -ProcessName $processName -ProcessPath $processPath
            }
            if ($stopped) {
                $finalMatches = @(Get-MatchingProcesses -ProcessName $processName -ProcessPath $processPath)
                if ($finalMatches.Count -eq 0) {
                    [void](Start-VerifiedApplication -AppName $appName -ProcessName $processName -ProcessPath $processPath -Reason "freeze recovery")
                } else {
                    $message = ":x: **$appName** still has matching PID(s) after freeze recovery: $(($finalMatches | ForEach-Object Id) -join ', '). Restart aborted."
                    Write-Host "[MONITOR] $message" -ForegroundColor Red
                    Send-DiscordNotification -Message $message
                }
            }
        }
    } else {
        Write-Host "[MONITOR] '$appName' is running normally (CPU >= $($FrozenCpuThreshold)%)." -ForegroundColor Green
    }
}

    # Wait for the next check
    Write-Host "[MAIN] Finished checking applications. Sleeping for $CheckIntervalSeconds seconds..." -ForegroundColor Blue -BackgroundColor Gray
    Start-Sleep -Seconds $CheckIntervalSeconds
    }
}

#endregion ------------------------------------------------------------------
