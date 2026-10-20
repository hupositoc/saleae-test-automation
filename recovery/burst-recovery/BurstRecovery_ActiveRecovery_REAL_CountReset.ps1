# Burst Recovery Active Monitor - REAL USB
# - Real Saleae/Kvaser USB PnP detection
# - Saleae left / CanKing right
# - CanKing: wait after launch, then ENTER
# - Monitoring starts only when user presses ENTER
# - Fast PnP/process monitoring
# - Active USB recovery: scan -> restart-device -> Disable/Enable
# - Saleae process restart if Logic closes
# - Kvaser heartbeat watchdog when heartbeat is visible in CanKing log output
# - Terminal shows fixed status only. Detailed logs go to C:\BurstRecovery\Logs

Set-StrictMode -Version 2.0
$ErrorActionPreference = "SilentlyContinue"

Add-Type -AssemblyName System.Windows.Forms

# ------------------------------------------------------------
# USER SETTINGS
# ------------------------------------------------------------
$logicExe   = "C:\Program Files\Logic\logic.exe"
$cankingExe = "C:\Program Files\Kvaser CanKing\Kvaser CanKing.exe"

$saleaeIdPrefix = "USB\VID_21A9&PID_1006\"
$kvaserIdPrefix = "USB\VID_0BFD&PID_0018\"

# Fast monitoring interval.
$PollMs = 100

# After USB/app recovery, wait this long before R / F9.
$RecoveryDelaySec = 10

# CanKing startup sequence: launch -> wait -> ENTER -> wait.
$CanKingEnterDelaySec = 3
$CanKingAfterEnterDelaySec = 3

# Heartbeat line:
# Heartbeat OK. ID=0x731, State=Operational, Count=4747
$HeartbeatTimeoutSec = 5
$HeartbeatVerifyTimeoutSec = 8
$HeartbeatRegex = 'Heartbeat OK\.\s*ID=0x731,\s*State=Operational,\s*Count=(\d+)'

# Saleae graphio.log:
# [logic_device_node.cpp:444] start capture
# [logic_device_node.cpp:530] stop capture
$SaleaeDataScanMinMs = 250
$SaleaeDataVerifyTimeoutSec = 8

# Optional: if CanKing writes the heartbeat to a separate text/log file,
# enter the full path here. Leave blank to use redirected CanKing stdout/stderr.
$ExternalHeartbeatLogPath = ""

$LogRoot = "C:\BurstRecovery\Logs"

# ------------------------------------------------------------
# ADMIN
# Active USB restart/Disable/Enable requires administrator rights.
# ------------------------------------------------------------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argLine
    exit
}

# ------------------------------------------------------------
# NATIVE WINDOW FUNCTIONS
# ------------------------------------------------------------
if (-not ("BurstRecoveryNative" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class BurstRecoveryNative
{
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool MoveWindow(
        IntPtr hWnd, int X, int Y, int W, int H, bool repaint
    );

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@
}

# ------------------------------------------------------------
# RUNTIME STATE
# ------------------------------------------------------------
$script:logicProcess = $null
$script:cankingProcess = $null
$script:logicRestartNo = 0
$script:cankingRestartNo = 0

$script:saleaeConnected = $false
$script:kvaserConnected = $false
$script:saleaeInstanceId = $null
$script:kvaserInstanceId = $null

$script:cankingStdoutPath = $null
$script:cankingStderrPath = $null

$script:saleaeGraphLogPath = $null
$script:saleaeDataStatus = "WAIT"
$script:saleaeCaptureEverSeen = $false
$script:lastSaleaeStartCaptureAt = $null
$script:lastSaleaeStopCaptureAt = $null
$script:lastSaleaeDataScanAt = [datetime]::MinValue

$script:heartbeatEverSeen = $false
$script:lastHeartbeatCount = $null
$script:lastHeartbeatAt = $null
$script:heartbeatStatus = "WAIT"

$script:screenStatus = "STARTING"
$script:screenMessage = ""
$script:fatalRecoveryFailed = $false

$script:prevSaleaeUsb = $null
$script:prevKvaserUsb = $null
$script:prevLogicApp = $null
$script:prevCanKingApp = $null
$script:prevSaleaeDataStatus = $null
$script:prevHeartbeatStatus = $null

# ------------------------------------------------------------
# LOG FILES
# ------------------------------------------------------------
New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
$runStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:runLogDir = Join-Path $LogRoot $runStamp
New-Item -ItemType Directory -Path $script:runLogDir -Force | Out-Null

$script:monitorLog = Join-Path $script:runLogDir "monitor.log"
$script:usbToolLog = Join-Path $script:runLogDir "usb_recovery_tools.log"
$script:saleaeStdoutPath = Join-Path $script:runLogDir "saleae_stdout.log"
$script:saleaeStderrPath = Join-Path $script:runLogDir "saleae_stderr.log"

function Write-EventLog([string]$message) {
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -LiteralPath $script:monitorLog -Value ("[{0}] {1}" -f $time, $message) -Encoding UTF8
}

function Write-ToolLog([string]$message) {
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -LiteralPath $script:usbToolLog -Value ("[{0}] {1}" -f $time, $message) -Encoding UTF8
}

Write-EventLog "PROGRAM START - REAL USB"
Write-EventLog ("LOG DIRECTORY: {0}" -f $script:runLogDir)

# ------------------------------------------------------------
# FIXED TERMINAL SCREEN
# ------------------------------------------------------------
function Fit([string]$text, [int]$width = 88) {
    if ($null -eq $text) { $text = "" }
    if ($text.Length -gt $width) {
        return $text.Substring(0, $width)
    }
    return $text.PadRight($width)
}

function Is-ProcessAlive($proc) {
    if ($null -eq $proc) { return $false }
    try {
        $proc.Refresh()
        return (-not $proc.HasExited)
    } catch {
        return $false
    }
}

function Draw-Screen([string]$status, [string]$message = "", [bool]$green = $false, [bool]$red = $false) {
    $logicAlive = Is-ProcessAlive $script:logicProcess
    $cankingAlive = Is-ProcessAlive $script:cankingProcess

    $hbText = $script:heartbeatStatus
    if ($script:lastHeartbeatCount -ne $null) {
        $hbText = "{0}  Count={1}" -f $hbText, $script:lastHeartbeatCount
    }

    $kvaserData = "WAIT"
    if ($script:heartbeatEverSeen) {
        if ($script:heartbeatStatus -eq "OK") {
            $kvaserData = "COLLECTING"
        } elseif ($script:heartbeatStatus -eq "LOST") {
            $kvaserData = "STOPPED"
        }
    }

    try { [Console]::SetCursorPosition(0,0) } catch {}

    $lines = @(
        "========================================================================================",
        "                         BURST RECOVERY MONITOR",
        "========================================================================================",
        "",
        (" Saleae USB : {0,-12}     Saleae APP : {1}" -f `
            $(if($script:saleaeConnected){"CONNECT"}else{"DISCONNECT"}), `
            $(if($logicAlive){"RUNNING"}else{"STOPPED"})),
        (" Saleae DATA: {0}" -f $script:saleaeDataStatus),
        "",
        (" Kvaser USB : {0,-12}     CanKing    : {1}" -f `
            $(if($script:kvaserConnected){"CONNECT"}else{"DISCONNECT"}), `
            $(if($cankingAlive){"RUNNING"}else{"STOPPED"})),
        (" Kvaser DATA: {0}" -f $kvaserData),
        (" Heartbeat  : {0}" -f $hbText),
        "",
        "----------------------------------------------------------------------------------------"
    )

    foreach ($line in $lines) {
        Write-Host (Fit $line)
    }

    $statusLine = Fit (" STATUS : {0}" -f $status)
    if ($green) {
        Write-Host $statusLine -ForegroundColor Green
    } elseif ($red) {
        Write-Host $statusLine -ForegroundColor Red
    } else {
        Write-Host $statusLine
    }

    Write-Host (Fit (" MESSAGE: {0}" -f $message))
    Write-Host (Fit (" LOG    : {0}" -f $script:runLogDir))
    Write-Host (Fit "----------------------------------------------------------------------------------------")
    Write-Host (Fit "")
}

function Bring-ConsoleFront {
    $hwnd = [BurstRecoveryNative]::GetConsoleWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return }

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = [Math]::Min(760, $wa.Width)
    $h = [Math]::Min(330, $wa.Height)
    $x = $wa.Left + [int](($wa.Width - $w) / 2)
    $y = $wa.Top + [int](($wa.Height - $h) / 2)

    [void][BurstRecoveryNative]::ShowWindowAsync($hwnd, 9)
    [void][BurstRecoveryNative]::MoveWindow($hwnd, $x, $y, $w, $h, $true)
    [void][BurstRecoveryNative]::SetForegroundWindow($hwnd)
}

# ------------------------------------------------------------
# USB PNP
# One PnP snapshot is used for BOTH devices.
# ------------------------------------------------------------
function Update-UsbSnapshot {
    $all = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)

    $saleae = @(
        $all |
        Where-Object { $_.InstanceId -like "$saleaeIdPrefix*" } |
        Select-Object -First 1
    )

    $kvaser = @(
        $all |
        Where-Object { $_.InstanceId -like "$kvaserIdPrefix*" } |
        Select-Object -First 1
    )

    $script:saleaeConnected = ($saleae.Count -gt 0)
    $script:kvaserConnected = ($kvaser.Count -gt 0)

    if ($script:saleaeConnected) {
        $script:saleaeInstanceId = $saleae[0].InstanceId
    }

    if ($script:kvaserConnected) {
        $script:kvaserInstanceId = $kvaser[0].InstanceId
    }
}

function Resolve-LastKnownInstance([string]$device) {
    $prefix = if ($device -eq "Saleae") { $saleaeIdPrefix } else { $kvaserIdPrefix }

    $match = @(
        Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like "$prefix*" } |
        Select-Object -First 1
    )

    if ($match.Count -gt 0) {
        if ($device -eq "Saleae") {
            $script:saleaeInstanceId = $match[0].InstanceId
            return $script:saleaeInstanceId
        } else {
            $script:kvaserInstanceId = $match[0].InstanceId
            return $script:kvaserInstanceId
        }
    }

    if ($device -eq "Saleae") { return $script:saleaeInstanceId }
    return $script:kvaserInstanceId
}

function Test-DeviceConnected([string]$device) {
    Update-UsbSnapshot
    if ($device -eq "Saleae") { return $script:saleaeConnected }
    return $script:kvaserConnected
}

function Wait-DeviceConnected([string]$device, [int]$timeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
        if (Test-DeviceConnected $device) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }

    return (Test-DeviceConnected $device)
}

function Invoke-PnpUtil([string[]]$arguments) {
    try {
        $result = & "$env:SystemRoot\System32\pnputil.exe" @arguments 2>&1
        Write-ToolLog ("pnputil {0}" -f ($arguments -join " "))
        foreach ($line in @($result)) {
            Write-ToolLog ("  {0}" -f [string]$line)
        }
    } catch {
        Write-ToolLog ("pnputil failed: {0}" -f ($arguments -join " "))
    }
}

function Invoke-UsbRecovery([string]$device, [bool]$forceRestart = $false) {
    $instanceId = Resolve-LastKnownInstance $device

    Write-EventLog ("{0} USB recovery start. ForceRestart={1}, InstanceId={2}" -f `
        $device, $forceRestart, $instanceId)

    # First, ask Windows to rescan hardware immediately.
    Invoke-PnpUtil @("/scan-devices")

    if (-not $forceRestart) {
        if (Wait-DeviceConnected $device 800) {
            Write-EventLog ("{0} USB reconnected after scan-devices." -f $device)
            return $true
        }
    }

    # Restart only the target device. Do not restart the whole USB controller.
    if ($instanceId) {
        Invoke-PnpUtil @("/restart-device", $instanceId)

        if (Wait-DeviceConnected $device 1800) {
            Write-EventLog ("{0} USB reconnected after restart-device." -f $device)
            return $true
        }

        # Fallback: Disable -> Enable the same device node.
        try {
            Write-ToolLog ("Disable-PnpDevice: {0}" -f $instanceId)
            Disable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Milliseconds 350

            Write-ToolLog ("Enable-PnpDevice: {0}" -f $instanceId)
            Enable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        } catch {
            Write-ToolLog ("Disable/Enable failed for: {0}" -f $instanceId)
        }

        Invoke-PnpUtil @("/scan-devices")

        if (Wait-DeviceConnected $device 5000) {
            Write-EventLog ("{0} USB reconnected after Disable/Enable." -f $device)
            return $true
        }
    }

    Write-EventLog ("{0} USB recovery FAILED." -f $device)
    return $false
}

# ------------------------------------------------------------
# APP / WINDOW CONTROL
# ------------------------------------------------------------
function Stop-OldApps {
    Get-Process -Name "logic" -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process -Name "Kvaser CanKing" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
}

function Wait-MainWindow($proc, [int]$timeoutSec = 30) {
    if ($null -eq $proc) { return [IntPtr]::Zero }

    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $proc.Refresh()
            if (-not $proc.HasExited -and $proc.MainWindowHandle -ne 0) {
                return [IntPtr]$proc.MainWindowHandle
            }
        } catch {}

        Start-Sleep -Milliseconds 200
    }

    return [IntPtr]::Zero
}

function Send-KeyByPid([int]$processId, [string]$key, [string]$label) {
    try {
        $w = New-Object -ComObject WScript.Shell

        if ($w.AppActivate($processId)) {
            Start-Sleep -Milliseconds 300
            [System.Windows.Forms.SendKeys]::SendWait($key)
            Write-EventLog ("KEY SENT: {0} -> {1}" -f $label, $key)
            return $true
        }
    } catch {}

    Write-EventLog ("KEY SEND FAILED: {0} -> {1}" -f $label, $key)
    return $false
}

function Start-LogicApp {
    $script:logicRestartNo++

    # New Logic process = new graphio.log session.
    # Keep saleaeCaptureEverSeen armed if capture was already observed before recovery.
    $script:saleaeGraphLogPath = $null
    $script:saleaeDataStatus = "WAIT"
    $script:lastSaleaeStartCaptureAt = $null
    $script:lastSaleaeStopCaptureAt = $null
    $script:lastSaleaeDataScanAt = [datetime]::MinValue

    $stdout = if ($script:logicRestartNo -eq 1) {
        $script:saleaeStdoutPath
    } else {
        Join-Path $script:runLogDir ("saleae_stdout_restart{0}.log" -f ($script:logicRestartNo - 1))
    }

    $stderr = if ($script:logicRestartNo -eq 1) {
        $script:saleaeStderrPath
    } else {
        Join-Path $script:runLogDir ("saleae_stderr_restart{0}.log" -f ($script:logicRestartNo - 1))
    }

    Write-EventLog ("Launching Saleae Logic: {0}" -f $logicExe)

    try {
        $script:logicProcess = Start-Process -FilePath $logicExe `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr `
            -PassThru
    } catch {
        $script:logicProcess = $null
        Write-EventLog "Saleae Logic launch FAILED."
        return $false
    }

    $hwnd = Wait-MainWindow $script:logicProcess 30
    if ($hwnd -eq [IntPtr]::Zero) {
        Write-EventLog "Saleae Logic main window not found."
        return $false
    }

    Write-EventLog ("Saleae Logic RUNNING. PID={0}" -f $script:logicProcess.Id)

    # Resolve the current Logic session graphio.log as soon as it appears.
    $graphDeadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $graphDeadline) {
        if (Resolve-SaleaeGraphLog) {
            Update-SaleaeData $true
            break
        }
        Start-Sleep -Milliseconds 200
    }

    return $true
}

function Start-CanKingApp {
    $script:cankingRestartNo++

    $suffix = if ($script:cankingRestartNo -eq 1) { "" } else { "_restart{0}" -f ($script:cankingRestartNo - 1) }
    $script:cankingStdoutPath = Join-Path $script:runLogDir ("canking_stdout{0}.log" -f $suffix)
    $script:cankingStderrPath = Join-Path $script:runLogDir ("canking_stderr{0}.log" -f $suffix)

    # New process = new heartbeat stream.
    $script:lastHeartbeatCount = $null
    $script:lastHeartbeatAt = $null
    $script:heartbeatStatus = "WAIT"

    Write-EventLog ("Launching CanKing: {0}" -f $cankingExe)

    try {
        $script:cankingProcess = Start-Process -FilePath $cankingExe `
            -RedirectStandardOutput $script:cankingStdoutPath `
            -RedirectStandardError $script:cankingStderrPath `
            -PassThru
    } catch {
        $script:cankingProcess = $null
        Write-EventLog "CanKing launch FAILED."
        return $false
    }

    # User-requested sequence:
    # CanKing launch -> wait -> ENTER -> wait.
    Start-Sleep -Seconds $CanKingEnterDelaySec
    [void](Send-KeyByPid $script:cankingProcess.Id "{ENTER}" "CanKing startup ENTER")
    Start-Sleep -Seconds $CanKingAfterEnterDelaySec

    $hwnd = Wait-MainWindow $script:cankingProcess 30
    if ($hwnd -eq [IntPtr]::Zero) {
        Write-EventLog "CanKing main window not found."
        return $false
    }

    Write-EventLog ("CanKing RUNNING. PID={0}" -f $script:cankingProcess.Id)
    return $true
}

function Arrange-AppWindows {
    if (-not (Is-ProcessAlive $script:logicProcess)) { return }
    if (-not (Is-ProcessAlive $script:cankingProcess)) { return }

    $logicHwnd = Wait-MainWindow $script:logicProcess 5
    $cankingHwnd = Wait-MainWindow $script:cankingProcess 5

    if ($logicHwnd -eq [IntPtr]::Zero -or $cankingHwnd -eq [IntPtr]::Zero) {
        Write-EventLog "Window arrangement skipped: main window handle missing."
        return
    }

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $half = [int]($wa.Width / 2)

    [void][BurstRecoveryNative]::ShowWindowAsync($logicHwnd, 9)
    [void][BurstRecoveryNative]::ShowWindowAsync($cankingHwnd, 9)

    [void][BurstRecoveryNative]::MoveWindow(
        $logicHwnd, $wa.Left, $wa.Top, $half, $wa.Height, $true
    )

    [void][BurstRecoveryNative]::MoveWindow(
        $cankingHwnd, $wa.Left + $half, $wa.Top, $wa.Width - $half, $wa.Height, $true
    )

    Write-EventLog "Window arrangement: Saleae LEFT / CanKing RIGHT."
}

# ------------------------------------------------------------
# SALEAE DATA COLLECTION
# graphio.log contains explicit "start capture" / "stop capture" events.
# Raw graphio lines are NEVER printed in terminal.
# ------------------------------------------------------------
function Resolve-SaleaeGraphLog {
    if ($script:saleaeGraphLogPath -and (Test-Path -LiteralPath $script:saleaeGraphLogPath)) {
        return $script:saleaeGraphLogPath
    }

    $root = Join-Path $env:APPDATA "Logic\logs"
    if (-not (Test-Path -LiteralPath $root)) {
        return $null
    }

    $latest = @(
        Get-ChildItem -LiteralPath $root -Filter "graphio.log" -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    )

    if ($latest.Count -gt 0) {
        $newPath = $latest[0].FullName

        if ($newPath -ne $script:saleaeGraphLogPath) {
            $script:saleaeGraphLogPath = $newPath
            $script:saleaeDataStatus = "WAIT"
            Write-EventLog ("Saleae graphio.log -> {0}" -f $newPath)
        }

        return $script:saleaeGraphLogPath
    }

    return $null
}

function Update-SaleaeData([bool]$force = $false) {
    $now = Get-Date

    if (-not $force) {
        $elapsedMs = ($now - $script:lastSaleaeDataScanAt).TotalMilliseconds
        if ($elapsedMs -lt $SaleaeDataScanMinMs) {
            return
        }
    }

    $script:lastSaleaeDataScanAt = $now

    $path = Resolve-SaleaeGraphLog
    if (-not $path) {
        if (-not (Is-ProcessAlive $script:logicProcess)) {
            $script:saleaeDataStatus = "STOPPED"
        }
        return
    }

    $lines = @(Get-Content -LiteralPath $path -Tail 250 -ErrorAction SilentlyContinue)

    $latestState = $null
    $latestEventAt = $null

    foreach ($line in $lines) {
        $eventType = $null

        if ($line -match '\]\s+start capture\s*$') {
            $eventType = "COLLECTING"
        }
        elseif ($line -match '\]\s+stop capture\s*$') {
            $eventType = "STOPPED"
        }

        if ($eventType -and $line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\]') {
            try {
                $eventAt = [datetime]::ParseExact(
                    $Matches[1],
                    "yyyy-MM-dd HH:mm:ss.fff",
                    [Globalization.CultureInfo]::InvariantCulture
                )

                if ($eventType -eq "COLLECTING") {
                    if ($script:lastSaleaeStartCaptureAt -eq $null -or $eventAt -gt $script:lastSaleaeStartCaptureAt) {
                        $script:lastSaleaeStartCaptureAt = $eventAt
                    }
                }
                else {
                    if ($script:lastSaleaeStopCaptureAt -eq $null -or $eventAt -gt $script:lastSaleaeStopCaptureAt) {
                        $script:lastSaleaeStopCaptureAt = $eventAt
                    }
                }

                if ($latestEventAt -eq $null -or $eventAt -gt $latestEventAt) {
                    $latestEventAt = $eventAt
                    $latestState = $eventType
                }
            } catch {}
        }
    }

    if ($latestState) {
        if ($latestState -eq "COLLECTING") {
            $script:saleaeCaptureEverSeen = $true
        }

        $script:saleaeDataStatus = $latestState
    }
}

function Test-SaleaeCollectingSince([datetime]$since) {
    Update-SaleaeData $true

    return (
        $script:saleaeDataStatus -eq "COLLECTING" -and
        $script:lastSaleaeStartCaptureAt -ne $null -and
        $script:lastSaleaeStartCaptureAt -ge $since
    )
}

function Wait-SaleaeCollectingSince([datetime]$since, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)

    while ((Get-Date) -lt $deadline) {
        Update-UsbSnapshot
        Update-SaleaeData $true

        if (-not $script:saleaeConnected) { return $false }
        if (-not (Is-ProcessAlive $script:logicProcess)) { return $false }

        if (Test-SaleaeCollectingSince $since) {
            return $true
        }

        Start-Sleep -Milliseconds $PollMs
    }

    return $false
}

# ------------------------------------------------------------
# HEARTBEAT
# Reads only log files; raw lines are NEVER printed in terminal.
# ------------------------------------------------------------
function Scan-HeartbeatFile([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    if (-not (Test-Path -LiteralPath $path)) { return }

    $lines = @(Get-Content -LiteralPath $path -Tail 200 -ErrorAction SilentlyContinue)

    foreach ($line in $lines) {
        if ($line -match $HeartbeatRegex) {
            $count = [Int64]$Matches[1]

            # Progress is valid only when Count changes.
            if ($script:lastHeartbeatCount -eq $null -or $count -ne $script:lastHeartbeatCount) {
                $firstHeartbeat = (-not $script:heartbeatEverSeen)

                $script:lastHeartbeatCount = $count
                $script:lastHeartbeatAt = Get-Date
                $script:heartbeatEverSeen = $true
                $script:heartbeatStatus = "OK"

                if ($firstHeartbeat) {
                    Write-EventLog ("Kvaser HEARTBEAT WATCHDOG ARMED. ID=0x731 Count={0}" -f $count)
                }
            }
        }
    }
}

function Update-Heartbeat {
    Scan-HeartbeatFile $script:cankingStdoutPath
    Scan-HeartbeatFile $script:cankingStderrPath

    if (-not [string]::IsNullOrWhiteSpace($ExternalHeartbeatLogPath)) {
        Scan-HeartbeatFile $ExternalHeartbeatLogPath
    }

    if ($script:lastHeartbeatAt -ne $null) {
        $age = ((Get-Date) - $script:lastHeartbeatAt).TotalSeconds

        if ($age -gt $HeartbeatTimeoutSec) {
            $script:heartbeatStatus = "LOST"
        } else {
            $script:heartbeatStatus = "OK"
        }
    } else {
        $script:heartbeatStatus = "WAIT"
    }
}

function Wait-HeartbeatProgress([Nullable[Int64]]$beforeCount, [int]$timeoutSec) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)

    while ((Get-Date) -lt $deadline) {
        Update-UsbSnapshot
        Update-Heartbeat

        if (-not $script:kvaserConnected) { return $false }
        if (-not (Is-ProcessAlive $script:cankingProcess)) { return $false }

        if ($script:lastHeartbeatCount -ne $null) {
            if ($beforeCount -eq $null -or $script:lastHeartbeatCount -ne $beforeCount.Value) {
                if ($script:heartbeatStatus -eq "OK") {
                    return $true
                }
            }
        }

        Start-Sleep -Milliseconds $PollMs
    }

    return $false
}

# ------------------------------------------------------------
# STATE CHANGE LOGGING
# ------------------------------------------------------------
function Log-StateChanges {
    $logicAlive = Is-ProcessAlive $script:logicProcess
    $cankingAlive = Is-ProcessAlive $script:cankingProcess

    if ($script:prevSaleaeUsb -ne $null -and $script:prevSaleaeUsb -ne $script:saleaeConnected) {
        Write-EventLog ("Saleae USB -> {0}" -f $(if($script:saleaeConnected){"CONNECT"}else{"DISCONNECT"}))
    }

    if ($script:prevKvaserUsb -ne $null -and $script:prevKvaserUsb -ne $script:kvaserConnected) {
        Write-EventLog ("Kvaser USB -> {0}" -f $(if($script:kvaserConnected){"CONNECT"}else{"DISCONNECT"}))
    }

    if ($script:prevLogicApp -ne $null -and $script:prevLogicApp -ne $logicAlive) {
        Write-EventLog ("Saleae APP -> {0}" -f $(if($logicAlive){"RUNNING"}else{"STOPPED"}))
    }

    if ($script:prevCanKingApp -ne $null -and $script:prevCanKingApp -ne $cankingAlive) {
        Write-EventLog ("CanKing APP -> {0}" -f $(if($cankingAlive){"RUNNING"}else{"STOPPED"}))
    }

    if ($script:prevSaleaeDataStatus -ne $null -and $script:prevSaleaeDataStatus -ne $script:saleaeDataStatus) {
        Write-EventLog ("Saleae DATA -> {0}" -f $script:saleaeDataStatus)
    }

    if ($script:prevHeartbeatStatus -ne $null -and $script:prevHeartbeatStatus -ne $script:heartbeatStatus) {
        Write-EventLog ("Kvaser HEARTBEAT -> {0}" -f $script:heartbeatStatus)
    }

    $script:prevSaleaeUsb = $script:saleaeConnected
    $script:prevKvaserUsb = $script:kvaserConnected
    $script:prevLogicApp = $logicAlive
    $script:prevCanKingApp = $cankingAlive
    $script:prevSaleaeDataStatus = $script:saleaeDataStatus
    $script:prevHeartbeatStatus = $script:heartbeatStatus
}

# ------------------------------------------------------------
# RECOVERY
# ------------------------------------------------------------
function Show-RecoveryCountdown(
    [int]$seconds,
    [string]$label,
    [bool]$needSaleae,
    [bool]$needKvaser,
    [bool]$saleaeUsbDisconnectFault
) {
    $sec = $seconds

    while ($sec -ge 1) {
        $until = (Get-Date).AddSeconds(1)
        $restartCountdown = $false

        while ((Get-Date) -lt $until) {
            Update-UsbSnapshot
            Update-SaleaeData
            Update-Heartbeat
            Log-StateChanges

            # If either USB drops DURING the recovery countdown,
            # recover that device and restart the full countdown.
            if (-not $script:saleaeConnected) {
                $needSaleae = $true
                $saleaeUsbDisconnectFault = $true

                Write-EventLog ("{0}: Saleae USB disconnected during countdown. Countdown RESET." -f $label)
                Draw-Screen "RECOVERING" "Saleae USB DISCONNECT during countdown - restarting recovery timer"

                [void](Invoke-UsbRecovery "Saleae" $false)
                [void](Ensure-AppsAfterUsb)

                $restartCountdown = $true
                break
            }

            if (-not $script:kvaserConnected) {
                $needKvaser = $true

                Write-EventLog ("{0}: Kvaser USB disconnected during countdown. Countdown RESET." -f $label)
                Draw-Screen "RECOVERING" "Kvaser USB DISCONNECT during countdown - restarting recovery timer"

                if (Is-ProcessAlive $script:cankingProcess) {
                    [void](Send-KeyByPid $script:cankingProcess.Id "{F12}" "CanKing F12")
                }

                [void](Invoke-UsbRecovery "Kvaser" $false)
                [void](Ensure-AppsAfterUsb)

                $restartCountdown = $true
                break
            }

            Draw-Screen "RECOVERING" ("{0} - Recovery in {1} sec" -f $label, $sec)
            Start-Sleep -Milliseconds $PollMs
        }

        if ($restartCountdown) {
            $sec = $seconds
            Write-EventLog ("{0}: Recovery countdown restarted from {1} sec." -f $label, $seconds)
            continue
        }

        $sec--
    }

    return [PSCustomObject]@{
        NeedSaleae = $needSaleae
        NeedKvaser = $needKvaser
        SaleaeUsbDisconnectFault = $saleaeUsbDisconnectFault
    }
}

function Ensure-AppsAfterUsb {
    $ok = $true

    if (-not (Is-ProcessAlive $script:logicProcess)) {
        Write-EventLog "Saleae Logic is not running. Restarting application."
        if (-not (Start-LogicApp)) { $ok = $false }
    }

    if (-not (Is-ProcessAlive $script:cankingProcess)) {
        Write-EventLog "CanKing is not running. Restarting application."
        if (-not (Start-CanKingApp)) { $ok = $false }
    }

    Arrange-AppWindows
    return $ok
}

function Invoke-Recovery([bool]$needSaleae, [bool]$needKvaser, [string]$reason) {
    Write-EventLog ("================ RECOVERY START ================ Reason={0}" -f $reason)
    Draw-Screen "RECOVERING" $reason

    $heartbeatWasAvailable = $script:heartbeatEverSeen
    $heartbeatBefore = $script:lastHeartbeatCount
    $saleaeDataWasArmed = $script:saleaeCaptureEverSeen
    $saleaeRecoveryStartedAt = Get-Date

    # USB disconnect has priority over graphio DATA state.
    # If USB dropped, a remaining COLLECTING state can be stale.
    $saleaeUsbDisconnectFault = ($reason -like "*Saleae USB DISCONNECT*")

    # Kvaser stop request first.
    if ($needKvaser -and (Is-ProcessAlive $script:cankingProcess)) {
        [void](Send-KeyByPid $script:cankingProcess.Id "{F12}" "CanKing F12")
    }

    # ---------- STAGE 1 ----------
    $stage1ok = $true

    Update-UsbSnapshot

    if ($needSaleae -and -not $script:saleaeConnected) {
        if (-not (Invoke-UsbRecovery "Saleae" $false)) {
            $stage1ok = $false
        }
    }

    # If heartbeat itself failed, force a Kvaser device restart even if PnP still says CONNECT.
    $heartbeatTriggered = ($reason -like "*Heartbeat*")

    if ($needKvaser) {
        if (-not $script:kvaserConnected -or $heartbeatTriggered) {
            if (-not (Invoke-UsbRecovery "Kvaser" $heartbeatTriggered)) {
                $stage1ok = $false
            }
        }
    }

    Update-UsbSnapshot

    if ($needSaleae -and -not $script:saleaeConnected) { $stage1ok = $false }
    if ($needKvaser -and -not $script:kvaserConnected) { $stage1ok = $false }

    if (-not (Ensure-AppsAfterUsb)) {
        $stage1ok = $false
    }

    if ($stage1ok) {
        $countdownResult = Show-RecoveryCountdown `
            $RecoveryDelaySec "Stage 1" $needSaleae $needKvaser $saleaeUsbDisconnectFault

        $needSaleae = [bool]$countdownResult.NeedSaleae
        $needKvaser = [bool]$countdownResult.NeedKvaser
        $saleaeUsbDisconnectFault = [bool]$countdownResult.SaleaeUsbDisconnectFault

        $saleaeRWasSent = $false
        $saleaeRSentAt = $null

        if ($needSaleae -and (Is-ProcessAlive $script:logicProcess)) {
            Update-SaleaeData $true

            if ($saleaeUsbDisconnectFault) {
                # Even if graphio still says COLLECTING, USB disconnect makes that state untrusted.
                Write-EventLog ("Stage 1: Saleae USB disconnect fault. DATA={0}. R forced." -f $script:saleaeDataStatus)
                $saleaeRSentAt = Get-Date
                $saleaeRWasSent = Send-KeyByPid $script:logicProcess.Id "r" "Saleae R"
            }
            elseif (Test-SaleaeCollectingSince $saleaeRecoveryStartedAt) {
                Write-EventLog "Stage 1: Saleae DATA already COLLECTING without USB disconnect. R SKIPPED."
            }
            else {
                $saleaeRSentAt = Get-Date
                $saleaeRWasSent = Send-KeyByPid $script:logicProcess.Id "r" "Saleae R"
            }
        }

        if ($needKvaser -and (Is-ProcessAlive $script:cankingProcess)) {
            $heartbeatBefore = $script:lastHeartbeatCount
            [void](Send-KeyByPid $script:cankingProcess.Id "{F9}" "CanKing F9")
        }

        Start-Sleep -Milliseconds 800
        Update-UsbSnapshot
        Update-SaleaeData $true
        Update-Heartbeat

        $saleaeVerified = (-not $needSaleae) -or `
            ($script:saleaeConnected -and (Is-ProcessAlive $script:logicProcess))

        if ($needSaleae -and $saleaeDataWasArmed -and $saleaeVerified) {
            if ($saleaeRWasSent -and $saleaeRSentAt -ne $null) {
                $saleaeVerified = Wait-SaleaeCollectingSince $saleaeRSentAt $SaleaeDataVerifyTimeoutSec
                if (-not $saleaeVerified) {
                    Write-EventLog "Stage 1: Saleae DATA was NOT restored after R."
                }
            }
            else {
                $saleaeVerified = Test-SaleaeCollectingSince $saleaeRecoveryStartedAt
                if (-not $saleaeVerified) {
                    Write-EventLog "Stage 1: Saleae DATA is not confirmed COLLECTING."
                }
            }
        }

        $kvaserBaseVerified = (-not $needKvaser) -or `
            ($script:kvaserConnected -and (Is-ProcessAlive $script:cankingProcess))

        $kvaserHeartbeatVerified = $true

        if ($needKvaser -and $heartbeatWasAvailable) {
            $kvaserHeartbeatVerified = Wait-HeartbeatProgress $heartbeatBefore $HeartbeatVerifyTimeoutSec
            if (-not $kvaserHeartbeatVerified) {
                Write-EventLog "Stage 1: Kvaser heartbeat was NOT restored after F9."
            }
        }

        if ($saleaeVerified -and $kvaserBaseVerified -and $kvaserHeartbeatVerified) {
            Write-EventLog "RECOVERY COMPLETE - Stage 1"
            Write-EventLog "================= RECOVERY END ================="
            Draw-Screen "RECOVERY COMPLETE" "Stage 1 OK" $true
            Start-Sleep -Seconds 1
            return $true
        }
    }

    # ---------- STAGE 2 ----------
    Write-EventLog "Stage 1 did not verify. Starting Stage 2."
    Draw-Screen "RECOVERING" "Stage 2 - USB + application restart"

    if ($needKvaser -and (Is-ProcessAlive $script:cankingProcess)) {
        [void](Send-KeyByPid $script:cankingProcess.Id "{F12}" "CanKing F12")
    }

    if ($needSaleae) {
        [void](Invoke-UsbRecovery "Saleae" $true)

        if (Is-ProcessAlive $script:logicProcess) {
            try { $script:logicProcess | Stop-Process -Force } catch {}
            Start-Sleep -Milliseconds 500
        }

        [void](Start-LogicApp)
    }

    if ($needKvaser) {
        [void](Invoke-UsbRecovery "Kvaser" $true)

        if (Is-ProcessAlive $script:cankingProcess) {
            try { $script:cankingProcess | Stop-Process -Force } catch {}
            Start-Sleep -Milliseconds 500
        }

        [void](Start-CanKingApp)
    }

    Arrange-AppWindows
    Update-UsbSnapshot

    $stage2base = $true
    if ($needSaleae) {
        $stage2base = $stage2base -and $script:saleaeConnected -and (Is-ProcessAlive $script:logicProcess)
    }
    if ($needKvaser) {
        $stage2base = $stage2base -and $script:kvaserConnected -and (Is-ProcessAlive $script:cankingProcess)
    }

    if ($stage2base) {
        $countdownResult2 = Show-RecoveryCountdown `
            $RecoveryDelaySec "Stage 2" $needSaleae $needKvaser $saleaeUsbDisconnectFault

        $needSaleae = [bool]$countdownResult2.NeedSaleae
        $needKvaser = [bool]$countdownResult2.NeedKvaser
        $saleaeUsbDisconnectFault = [bool]$countdownResult2.SaleaeUsbDisconnectFault

        $saleaeRWasSent2 = $false
        $saleaeRSentAt2 = $null
        if ($needSaleae) {
            Update-SaleaeData $true

            if ($saleaeUsbDisconnectFault) {
                # Same rule in Stage 2: any Saleae USB drop forces R.
                Write-EventLog ("Stage 2: Saleae USB disconnect fault. DATA={0}. R forced." -f $script:saleaeDataStatus)
                $saleaeRSentAt2 = Get-Date
                $saleaeRWasSent2 = Send-KeyByPid $script:logicProcess.Id "r" "Saleae R"
            }
            elseif (Test-SaleaeCollectingSince $saleaeRecoveryStartedAt) {
                Write-EventLog "Stage 2: Saleae DATA already COLLECTING without USB disconnect. R SKIPPED."
            }
            else {
                $saleaeRSentAt2 = Get-Date
                $saleaeRWasSent2 = Send-KeyByPid $script:logicProcess.Id "r" "Saleae R"
            }
        }

        $stage2HeartbeatBefore = $script:lastHeartbeatCount

        if ($needKvaser) {
            [void](Send-KeyByPid $script:cankingProcess.Id "{F9}" "CanKing F9")
        }

        Start-Sleep -Milliseconds 800
        Update-UsbSnapshot
        Update-SaleaeData $true
        Update-Heartbeat

        $saleaeVerified2 = (-not $needSaleae) -or `
            ($script:saleaeConnected -and (Is-ProcessAlive $script:logicProcess))

        if ($needSaleae -and $saleaeDataWasArmed -and $saleaeVerified2) {
            if ($saleaeRWasSent2 -and $saleaeRSentAt2 -ne $null) {
                $saleaeVerified2 = Wait-SaleaeCollectingSince $saleaeRSentAt2 $SaleaeDataVerifyTimeoutSec
                if (-not $saleaeVerified2) {
                    Write-EventLog "Stage 2: Saleae DATA was NOT restored after R."
                }
            }
            else {
                $saleaeVerified2 = Test-SaleaeCollectingSince $saleaeRecoveryStartedAt
                if (-not $saleaeVerified2) {
                    Write-EventLog "Stage 2: Saleae DATA is not confirmed COLLECTING."
                }
            }
        }

        $kvaserBaseVerified2 = (-not $needKvaser) -or `
            ($script:kvaserConnected -and (Is-ProcessAlive $script:cankingProcess))

        $kvaserHeartbeatVerified2 = $true

        if ($needKvaser -and $heartbeatWasAvailable) {
            $kvaserHeartbeatVerified2 = Wait-HeartbeatProgress $stage2HeartbeatBefore $HeartbeatVerifyTimeoutSec
        }

        if ($saleaeVerified2 -and $kvaserBaseVerified2 -and $kvaserHeartbeatVerified2) {
            Write-EventLog "RECOVERY COMPLETE - Stage 2"
            Write-EventLog "================= RECOVERY END ================="
            Draw-Screen "RECOVERY COMPLETE" "Stage 2 OK" $true
            Start-Sleep -Seconds 1
            return $true
        }
    }

    Write-EventLog ("RECOVERY FAILED. Reason={0}" -f $reason)
    Write-EventLog "================ RECOVERY FAILED ================"
    Draw-Screen "RECOVERY FAILED" $reason $false $true
    $script:fatalRecoveryFailed = $true
    return $false
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------
function Main {
    try { [Console]::CursorVisible = $false } catch {}

    # STEP 1: do NOT launch applications until BOTH USB devices are present.
    $lastStartupWarning = $null

    while ($true) {
        Update-UsbSnapshot

        if ($script:saleaeConnected -and $script:kvaserConnected) {
            Draw-Screen "USB READY" "Saleae / Kvaser CONNECT"
            Write-EventLog ("Initial USB check OK. Saleae={0}, Kvaser={1}" -f `
                $script:saleaeInstanceId, $script:kvaserInstanceId)
            break
        }

        $nowText = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Draw-Screen "WAIT USB" ("[{0}] 장비가 연결돼있지 않습니다. 연결 상태를 확인하세요." -f $nowText)

        $stateText = "Saleae={0}, Kvaser={1}" -f $script:saleaeConnected, $script:kvaserConnected
        if ($stateText -ne $lastStartupWarning) {
            Write-EventLog ("STARTUP USB NOT READY: {0}" -f $stateText)
            $lastStartupWarning = $stateText
        }

        Start-Sleep -Milliseconds $PollMs
    }

    # STEP 2: both connected -> start Saleae and CanKing.
    Stop-OldApps

    Draw-Screen "LAUNCHING" "Starting Saleae Logic..."
    if (-not (Start-LogicApp)) {
        Draw-Screen "START FAILED" "Saleae Logic could not start." $false $true
        return
    }

    Draw-Screen "LAUNCHING" "Starting CanKing... wait -> ENTER"
    if (-not (Start-CanKingApp)) {
        Draw-Screen "START FAILED" "CanKing could not start." $false $true
        return
    }

    # STEP 3: Saleae left / CanKing right.
    Arrange-AppWindows
    Bring-ConsoleFront

    # STEP 4: user prepares applications; ENTER starts monitoring.
    while ($true) {
        Update-UsbSnapshot
        Update-SaleaeData
        Update-Heartbeat
        Log-StateChanges

        $logicAlive = Is-ProcessAlive $script:logicProcess
        $cankingAlive = Is-ProcessAlive $script:cankingProcess

        if (-not $script:saleaeConnected -or -not $script:kvaserConnected) {
            Draw-Screen "PREPARE" "USB DISCONNECT - CONNECT 상태가 되어야 시작할 수 있습니다."
        } elseif (-not $logicAlive -or -not $cankingAlive) {
            Draw-Screen "PREPARE" "Application STOPPED - 프로그램 상태를 확인하세요."
        } else {
            Draw-Screen "READY" "사용자 준비 후 이 CMD 창에서 ENTER = MONITORING START"

            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true).Key
                if ($key -eq [ConsoleKey]::Enter) {
                    break
                }
            }
        }

        Start-Sleep -Milliseconds $PollMs
    }

    Write-EventLog "MONITORING START"
    $script:screenStatus = "MONITORING"

    # Initial previous states for change-only logging.
    Update-UsbSnapshot
    Update-SaleaeData $true
    Update-Heartbeat
    Log-StateChanges

    $heartbeatScanCounter = 0

    # STEP 5: fast monitoring + active recovery.
    while ($true) {
        Update-UsbSnapshot

        $heartbeatScanCounter++
        if ($heartbeatScanCounter -ge 5) {
            Update-SaleaeData
            Update-Heartbeat
            $heartbeatScanCounter = 0
        }

        Log-StateChanges

        $logicAlive = Is-ProcessAlive $script:logicProcess
        $cankingAlive = Is-ProcessAlive $script:cankingProcess

        if ($script:fatalRecoveryFailed) {
            Draw-Screen "RECOVERY FAILED" "자동복구 2단계 실패. 상세 원인은 monitor.log 확인." $false $true
            Start-Sleep -Milliseconds $PollMs
            continue
        }

        $saleaeDataStopped = $script:saleaeCaptureEverSeen -and ($script:saleaeDataStatus -eq "STOPPED")
        $needSaleae = (-not $script:saleaeConnected) -or (-not $logicAlive) -or $saleaeDataStopped

        $heartbeatLost = $script:heartbeatEverSeen -and ($script:heartbeatStatus -eq "LOST")
        $needKvaser = (-not $script:kvaserConnected) -or (-not $cankingAlive) -or $heartbeatLost

        if ($needSaleae -or $needKvaser) {
            $reasons = @()

            if (-not $script:saleaeConnected) { $reasons += "Saleae USB DISCONNECT" }
            if (-not $logicAlive) { $reasons += "Saleae APP STOPPED" }
            if ($saleaeDataStopped) { $reasons += "Saleae DATA STOPPED" }
            if (-not $script:kvaserConnected) { $reasons += "Kvaser USB DISCONNECT" }
            if (-not $cankingAlive) { $reasons += "CanKing APP STOPPED" }
            if ($heartbeatLost) { $reasons += "Kvaser Heartbeat LOST" }

            $reason = $reasons -join " / "
            [void](Invoke-Recovery $needSaleae $needKvaser $reason)

            Update-UsbSnapshot
            Update-Heartbeat
            Log-StateChanges
            continue
        }

        Draw-Screen "MONITORING" "USB / APP / Saleae DATA / Kvaser Heartbeat monitoring"
        Start-Sleep -Milliseconds $PollMs
    }
}

try {
    Main
}
finally {
    try { [Console]::CursorVisible = $true } catch {}
    Write-EventLog "PROGRAM END"
}
