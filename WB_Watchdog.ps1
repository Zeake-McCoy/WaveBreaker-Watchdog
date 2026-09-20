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
$DiscordWebhookUrl = "https://discord.com/api/webhooks/1406344831311020064/p31ms4hBERk8_bfXXYVknQcyLIkCcMSMjnZfDHJgspKy7l7_rWVPXtr_5qhTZ78fxE94"

# How often to check (in seconds)
$CheckIntervalSeconds = 60

# How often to pause for restarts (in hours)
$PauseIntervalHours = 6

# Duration of the pause (in minutes)
$PauseDurationMinutes = 5

# Threshold for CPU usage to consider an app frozen (e.g., 0.1%)
$FrozenCpuThreshold = 0.9

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

    # Get process by name and then filter by path
    $process = Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $processPath}

    if (-not $process) {
        # Process is not running, attempt to start it
        Write-Host "[MONITOR] '$appName' ($processName) at '$processPath' is NOT running. Attempting to start..." -ForegroundColor Cyan -BackgroundColor Red
        try {
            Write-Host "[MONITOR] Executing: Start-Process -FilePath '$processPath'" -ForegroundColor Blue -BackgroundColor Yellow
            Start-Process -FilePath $processPath
            $message = ":white_check_mark: **$appName** ($processName) was not running and has been restarted."
            Send-DiscordNotification -Message $message
            Write-Host "[MONITOR] Successfully started '$appName'. Notification sent." -ForegroundColor Blue -BackgroundColor DarkYellow
        } catch {
            Write-Host "[MONITOR] ERROR starting '$appName' ($processName) at '$processPath': $($_.Exception.Message)" -ForegroundColor Cyan -BackgroundColor Red
            $message = ":x: **Error starting $appName** ($processName) : $($_.Exception.Message)"
            Send-DiscordNotification -Message $message
            Write-Host "[MONITOR] Error notification sent for '$appName'." -ForegroundColor Cyan -BackgroundColor Red
        }
    } else {
        # Process is running, check if it's frozen
        Write-Host "[MONITOR] '$appName' ($processName) at '$processPath' is running. PID: $($process.Id)." -ForegroundColor Blue -BackgroundColor Green

        # Exclude Nexus Controller from freeze check
        if ($appName -eq "Nexus Controller") {
            Write-Host "[MONITOR] Skipping freeze check for Nexus Controller." -ForegroundColor Blue -BackgroundColor DarkYellow
        } else {
            # Calculate CPU usage over a defined interval
            $sampleInterval = 5  # seconds
            $startCpuTime = $process.CPU
            Start-Sleep -Seconds $sampleInterval
            $endCpuTime = (Get-Process -Id $process.Id).CPU

            # Calculate CPU usage percentage
            $cpuUsage = (($endCpuTime - $startCpuTime) / $sampleInterval) * 100

            Write-Host "[MONITOR] CPU Usage for '$appName': $cpuUsage%." -ForegroundColor Blue -BackgroundColor Green

            # Check if CPU usage is below the threshold
            if ($cpuUsage -lt $FrozenCpuThreshold) {
                Write-Host "[MONITOR] '$appName' ($processName) at '$processPath' appears to be frozen (CPU < $($FrozenCpuThreshold)%). Attempting to restart..." -ForegroundColor Cyan -BackgroundColor Red
                try {
                    Write-Host "[MONITOR] Attempting to stop process '$processName' (PID: $($process.Id))." -ForegroundColor Blue -BackgroundColor Yellow
                    Stop-Process -Id $process.Id -Force
                    Write-Host "[MONITOR] Process '$processName' (PID: $($process.Id)) stopped. Waiting 5 seconds before restart..." -ForegroundColor Blue -BackgroundColor Yellow
                    Start-Sleep -Seconds 5 # Give it a moment to close

                    Write-Host "[MONITOR] Executing: Start-Process -FilePath '$processPath'" -ForegroundColor Blue -BackgroundColor Yellow
                    Start-Process -FilePath $processPath
                    $message = ":warning: **$appName** ($processName) was detected as frozen and has been restarted."
                    Send-DiscordNotification -Message $message
                    Write-Host "[MONITOR] Successfully restarted '$appName' after freeze. Notification sent." -ForegroundColor Blue -BackgroundColor DarkYellow
                } catch {
                    Write-Host "[MONITOR] ERROR restarting frozen '$appName' ($processName) at '$processPath': $($_.Exception.Message)" -ForegroundColor Cyan -BackgroundColor Red
                    $message = ":x: **Error restarting frozen $appName** ($processName) : $($_.Exception.Message)"
                    Send-DiscordNotification -Message $message
                    Write-Host "[MONITOR] Error notification sent for frozen '$appName'." -ForegroundColor Cyan -BackgroundColor Red
                }
            } else {
                Write-Host "[MONITOR] '$appName' ($processName) at '$processPath' is running normally (CPU >= $($FrozenCpuThreshold)%)." -ForegroundColor Blue -BackgroundColor DarkGreen
            }
        }
    }
}

    # Wait for the next check
    Write-Host "[MAIN] Finished checking applications. Sleeping for $CheckIntervalSeconds seconds..." -ForegroundColor Blue -BackgroundColor Gray
    Start-Sleep -Seconds $CheckIntervalSeconds
    }
}

#endregion ------------------------------------------------------------------
