# HeadDown v1.2 - mouse-controlled keyboard rest mode for Windows 10/11
# No installation or administrator rights are required.

param([switch]$SmokeTest)

if ($PSVersionTable.PSVersion.Major -lt 5) {
    [System.Windows.Forms.MessageBox]::Show('HeadDown requires Windows PowerShell 5.1 or newer.', 'HeadDown')
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

trap {
    [System.Windows.Forms.MessageBox]::Show(
        "HeadDown ran into an error:`r`n`r`n$($_.Exception.Message)",
        'HeadDown',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

# Keep the native helper independent of Windows Forms/Drawing references so it
# compiles reliably with the older C# compiler included in Windows PowerShell 5.1.
Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class KeyboardBlocker
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
    private static readonly LowLevelKeyboardProc Callback = HookCallback;
    private static IntPtr hook = IntPtr.Zero;

    public static bool IsLocked { get { return hook != IntPtr.Zero; } }
    public static bool AllowMediaKeys { get; set; }

    public static bool Lock()
    {
        if (IsLocked) return true;
        using (Process process = Process.GetCurrentProcess())
        using (ProcessModule module = process.MainModule)
        {
            hook = SetWindowsHookEx(WH_KEYBOARD_LL, Callback, GetModuleHandle(module.ModuleName), 0);
        }
        return hook != IntPtr.Zero;
    }

    public static void Unlock()
    {
        if (!IsLocked) return;
        UnhookWindowsHookEx(hook);
        hook = IntPtr.Zero;
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int message = wParam.ToInt32();
            if (message == WM_KEYDOWN || message == WM_KEYUP ||
                message == WM_SYSKEYDOWN || message == WM_SYSKEYUP)
            {
                int key = Marshal.ReadInt32(lParam);
                if (AllowMediaKeys && IsMediaKey(key))
                    return CallNextHookEx(hook, nCode, wParam, lParam);
                return (IntPtr)1;
            }
        }
        return CallNextHookEx(hook, nCode, wParam, lParam);
    }

    private static bool IsMediaKey(int key)
    {
        return key == 0xAD || // volume mute
               key == 0xAE || // volume down
               key == 0xAF || // volume up
               key == 0xB0 || // next track
               key == 0xB1 || // previous track
               key == 0xB2 || // stop
               key == 0xB3;   // play/pause
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc callback, IntPtr module, uint threadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string moduleName);
}

public static class MonitorPower
{
    private const int HWND_BROADCAST = 0xffff;
    private const int WM_SYSCOMMAND = 0x0112;
    private const int SC_MONITORPOWER = 0xF170;

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    public static void TurnOff()
    {
        SendMessage((IntPtr)HWND_BROADCAST, WM_SYSCOMMAND, (IntPtr)SC_MONITORPOWER, (IntPtr)2);
    }

    public static void TurnOn()
    {
        SendMessage((IntPtr)HWND_BROADCAST, WM_SYSCOMMAND, (IntPtr)SC_MONITORPOWER, (IntPtr)(-1));
    }
}

public static class SettingsBroadcast
{
    private const int HWND_BROADCAST = 0xffff;
    private const int WM_SETTINGCHANGE = 0x001A;
    private const int SMTO_ABORTIFHUNG = 0x0002;

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam,
        uint flags, uint timeout, out IntPtr result);

    public static void Notify()
    {
        IntPtr result;
        SendMessageTimeout((IntPtr)HWND_BROADCAST, WM_SETTINGCHANGE,
            IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 1000, out result);
    }
}
"@ -ErrorAction Stop

$script:PowerSaverGuid = 'a1841308-3541-4fab-bc81-f71556f20b4a'
$script:OriginalPowerScheme = $null
$script:OriginalBrightness = $null
$script:Locked = $false
$script:EcoApplied = $false
$script:Countdown = 0
$script:RestSeconds = 0
$script:FocusApplied = $false
$script:ToastPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications'
$script:FocusMarkerName = 'HeadDownOriginalToastEnabled'
$script:OriginalToastExists = $false
$script:OriginalToastEnabled = $null

function Invoke-PowerCfg {
    param([string]$Arguments)
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = 'powercfg.exe'
        $startInfo.Arguments = $Arguments
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ($stdout + $stderr) }
    }
    catch {
        return [pscustomobject]@{ ExitCode = -1; Output = $_.Exception.Message }
    }
}

function Get-ActivePowerScheme {
    $result = Invoke-PowerCfg '/getactivescheme'
    $match = [regex]::Match($result.Output, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($match.Success) { return $match.Value }
    return $null
}

function Get-InternalBrightness {
    try {
        $brightness = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $brightness) { return [int]$brightness.CurrentBrightness }
    }
    catch { }
    return $null
}

function Set-InternalBrightness {
    param([ValidateRange(0,100)][int]$Level)
    try {
        $methods = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods -ErrorAction Stop
        if ($null -eq $methods) { return $false }
        foreach ($method in $methods) {
            $null = $method.WmiSetBrightness(0, [byte]$Level)
        }
        return $true
    }
    catch { return $false }
}

function Capture-NotificationSetting {
    try {
        $settings = Get-ItemProperty -Path $script:ToastPath -ErrorAction Stop
        $property = $settings.PSObject.Properties['ToastEnabled']
        if ($null -ne $property) {
            $script:OriginalToastExists = $true
            $script:OriginalToastEnabled = [int]$property.Value
        }
    }
    catch { }
}

function Recover-StaleFocusMode {
    try {
        $settings = Get-ItemProperty -Path $script:ToastPath -ErrorAction Stop
        $marker = $settings.PSObject.Properties[$script:FocusMarkerName]
        if ($null -eq $marker) { return }

        $previous = [int]$marker.Value
        if ($previous -eq -1) {
            Remove-ItemProperty -Path $script:ToastPath -Name ToastEnabled -ErrorAction SilentlyContinue
        }
        else {
            Set-ItemProperty -Path $script:ToastPath -Name ToastEnabled -Value $previous -Type DWord -ErrorAction Stop
        }
        Remove-ItemProperty -Path $script:ToastPath -Name $script:FocusMarkerName -ErrorAction SilentlyContinue
        [SettingsBroadcast]::Notify()
    }
    catch { }
}

function Enable-FocusMode {
    try {
        $null = New-Item -Path $script:ToastPath -Force -ErrorAction Stop
        $previous = if ($script:OriginalToastExists) { $script:OriginalToastEnabled } else { -1 }
        Set-ItemProperty -Path $script:ToastPath -Name $script:FocusMarkerName -Value $previous -Type DWord -ErrorAction Stop
        Set-ItemProperty -Path $script:ToastPath -Name ToastEnabled -Value 0 -Type DWord -ErrorAction Stop
        [SettingsBroadcast]::Notify()
        $script:FocusApplied = $true
        return $true
    }
    catch { return $false }
}

function Restore-FocusMode {
    if (-not $script:FocusApplied) { return }
    try {
        if ($script:OriginalToastExists) {
            Set-ItemProperty -Path $script:ToastPath -Name ToastEnabled -Value $script:OriginalToastEnabled -Type DWord -ErrorAction Stop
        }
        else {
            Remove-ItemProperty -Path $script:ToastPath -Name ToastEnabled -ErrorAction SilentlyContinue
        }
        Remove-ItemProperty -Path $script:ToastPath -Name $script:FocusMarkerName -ErrorAction SilentlyContinue
        [SettingsBroadcast]::Notify()
    }
    catch { }
    $script:FocusApplied = $false
}

function Update-RestTimerDisplay {
    if ($script:RestSeconds -le 0) {
        $timerDisplayLabel.Text = 'Timer: off'
        return
    }
    $time = [TimeSpan]::FromSeconds($script:RestSeconds)
    if ($time.TotalHours -ge 1) {
        $timerDisplayLabel.Text = ('Timer: {0}:{1:00}:{2:00}' -f [int]$time.TotalHours, $time.Minutes, $time.Seconds)
    }
    else {
        $timerDisplayLabel.Text = ('Timer: {0}:{1:00}' -f $time.Minutes, $time.Seconds)
    }
}

function Set-LabelState {
    param([bool]$IsLocked)
    if ($IsLocked) {
        $statusLabel.Text = 'KEYBOARD LOCKED'
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 107, 107)
        $toggleButton.Text = 'UNLOCK KEYBOARD'
        $toggleButton.BackColor = [System.Drawing.Color]::FromArgb(220, 70, 70)
        $toggleButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(235, 82, 82)
        $form.TopMost = $true
    }
    else {
        $statusLabel.Text = 'Keyboard ready'
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(116, 226, 151)
        $toggleButton.Text = 'LOCK KEYBOARD'
        $toggleButton.BackColor = [System.Drawing.Color]::FromArgb(45, 150, 90)
        $toggleButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(52, 170, 101)
        $countdownLabel.Text = 'Mouse stays active. Closing the app also unlocks it.'
        $timerDisplayLabel.Text = 'Timer: off'
    }
}

function Enable-EcoMode {
    $changed = $false
    $result = Invoke-PowerCfg "/setactive $script:PowerSaverGuid"
    if ($result.ExitCode -eq 0) { $changed = $true }

    if (Set-InternalBrightness -Level 10) { $changed = $true }
    $script:EcoApplied = $changed

    if ($changed) {
        $powerStateLabel.Text = 'Eco mode: ON (power saver + 10% brightness)'
        $powerStateLabel.ForeColor = [System.Drawing.Color]::FromArgb(116, 226, 151)
    }
    else {
        $powerStateLabel.Text = 'Eco mode unavailable on this display/device'
        $powerStateLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 193, 92)
    }
}

function Restore-PowerSettings {
    if ($script:OriginalPowerScheme) {
        $null = Invoke-PowerCfg "/setactive $script:OriginalPowerScheme"
    }
    if ($null -ne $script:OriginalBrightness) {
        $null = Set-InternalBrightness -Level $script:OriginalBrightness
    }
    $script:EcoApplied = $false
    $powerStateLabel.Text = 'Eco mode: OFF'
    $powerStateLabel.ForeColor = [System.Drawing.Color]::FromArgb(180, 188, 202)
}

function Unlock-Keyboard {
    $screenOffTimer.Stop()
    $restTimer.Stop()
    $script:RestSeconds = 0
    [KeyboardBlocker]::Unlock()
    $script:Locked = $false
    if ($script:EcoApplied) { Restore-PowerSettings }
    Restore-FocusMode
    Set-LabelState -IsLocked $false
}

function Lock-Keyboard {
    [KeyboardBlocker]::AllowMediaKeys = $mediaKeysCheck.Checked
    if (-not [KeyboardBlocker]::Lock()) {
        [System.Windows.Forms.MessageBox]::Show(
            'Windows could not start the keyboard lock. Try closing and reopening HeadDown.',
            'HeadDown',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $script:Locked = $true
    Set-LabelState -IsLocked $true
    if ($ecoCheck.Checked) { Enable-EcoMode }
    if ($focusCheck.Checked) {
        if (-not (Enable-FocusMode)) {
            $countdownLabel.Text = 'Focus mode unavailable; other lock features are active.'
        }
    }

    if ($timerCheck.Checked) {
        $script:RestSeconds = [int]$timerMinutes.Value * 60
        Update-RestTimerDisplay
        $restTimer.Start()
    }
    else {
        $script:RestSeconds = 0
        $timerDisplayLabel.Text = 'Timer: off'
    }

    if ($screenOffCheck.Checked) {
        $script:Countdown = 10
        $countdownLabel.Text = "Display turns off in $script:Countdown seconds - move the mouse to wake it"
        $screenOffTimer.Start()
    }
}

function Update-BatteryStatus {
    $power = [System.Windows.Forms.SystemInformation]::PowerStatus
    if ($power.BatteryChargeStatus.ToString().Contains('NoSystemBattery')) {
        $batteryLabel.Text = 'Battery: not detected'
        return
    }

    $percent = [math]::Round($power.BatteryLifePercent * 100)
    $source = if ($power.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online) { 'plugged in' } else { 'on battery' }
    $batteryLabel.Text = "Battery: $percent% - $source"
}

# Capture settings before the app changes anything.
$script:OriginalPowerScheme = Get-ActivePowerScheme
$script:OriginalBrightness = Get-InternalBrightness
Recover-StaleFocusMode
Capture-NotificationSetting

$bg = [System.Drawing.Color]::FromArgb(15, 17, 23)
$panelBg = [System.Drawing.Color]::FromArgb(25, 29, 38)
$text = [System.Drawing.Color]::FromArgb(235, 238, 245)
$muted = [System.Drawing.Color]::FromArgb(150, 160, 180)
$border = [System.Drawing.Color]::FromArgb(54, 61, 76)
$accent = [System.Drawing.Color]::FromArgb(108, 99, 255)

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'HeadDown'
$form.ClientSize = New-Object System.Drawing.Size(380, 450)
$form.MinimumSize = New-Object System.Drawing.Size(360, 400)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bg
$form.ForeColor = $text
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true
$form.AutoScaleMode = 'Font'
$form.AutoScroll = $true
$form.AutoScrollMinSize = New-Object System.Drawing.Size(0, 440)
$form.SizeGripStyle = 'Show'

$accentBar = New-Object System.Windows.Forms.Panel
$accentBar.Location = New-Object System.Drawing.Point(0, 0)
$accentBar.Size = New-Object System.Drawing.Size(380, 4)
$accentBar.BackColor = $accent
$accentBar.Anchor = 'Top, Left, Right'
$form.Controls.Add($accentBar)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'HeadDown'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$titleLabel.ForeColor = $text
$titleLabel.Location = New-Object System.Drawing.Point(16, 12)
$titleLabel.AutoSize = $true
$form.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = 'Rest without accidental input'
$subtitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$subtitleLabel.ForeColor = $muted
$subtitleLabel.Location = New-Object System.Drawing.Point(18, 44)
$subtitleLabel.AutoSize = $true
$form.Controls.Add($subtitleLabel)

$versionLabel = New-Object System.Windows.Forms.Label
$versionLabel.Text = 'v1.2'
$versionLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$versionLabel.ForeColor = $accent
$versionLabel.Location = New-Object System.Drawing.Point(320, 19)
$versionLabel.Size = New-Object System.Drawing.Size(42, 20)
$versionLabel.TextAlign = 'MiddleRight'
$versionLabel.Anchor = 'Top, Right'
$form.Controls.Add($versionLabel)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(16, 66)
$statusPanel.Size = New-Object System.Drawing.Size(348, 126)
$statusPanel.BackColor = $panelBg
$statusPanel.BorderStyle = 'FixedSingle'
$statusPanel.Anchor = 'Top, Left, Right'
$form.Controls.Add($statusPanel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$statusLabel.Location = New-Object System.Drawing.Point(12, 8)
$statusLabel.Size = New-Object System.Drawing.Size(322, 20)
$statusLabel.TextAlign = 'MiddleCenter'
$statusLabel.Anchor = 'Top, Left, Right'
$statusPanel.Controls.Add($statusLabel)

$toggleButton = New-Object System.Windows.Forms.Button
$toggleButton.Location = New-Object System.Drawing.Point(13, 31)
$toggleButton.Size = New-Object System.Drawing.Size(320, 47)
$toggleButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$toggleButton.ForeColor = [System.Drawing.Color]::White
$toggleButton.FlatStyle = 'Flat'
$toggleButton.FlatAppearance.BorderSize = 0
$toggleButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$toggleButton.Anchor = 'Top, Left, Right'
$statusPanel.Controls.Add($toggleButton)

$timerDisplayLabel = New-Object System.Windows.Forms.Label
$timerDisplayLabel.Text = 'Timer: off'
$timerDisplayLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$timerDisplayLabel.ForeColor = $text
$timerDisplayLabel.Location = New-Object System.Drawing.Point(9, 81)
$timerDisplayLabel.Size = New-Object System.Drawing.Size(328, 20)
$timerDisplayLabel.TextAlign = 'MiddleCenter'
$timerDisplayLabel.Anchor = 'Top, Left, Right'
$statusPanel.Controls.Add($timerDisplayLabel)

$countdownLabel = New-Object System.Windows.Forms.Label
$countdownLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$countdownLabel.ForeColor = $muted
$countdownLabel.Location = New-Object System.Drawing.Point(9, 101)
$countdownLabel.Size = New-Object System.Drawing.Size(328, 19)
$countdownLabel.TextAlign = 'MiddleCenter'
$countdownLabel.Anchor = 'Top, Left, Right'
$statusPanel.Controls.Add($countdownLabel)

$settingsPanel = New-Object System.Windows.Forms.Panel
$settingsPanel.Location = New-Object System.Drawing.Point(16, 202)
$settingsPanel.Size = New-Object System.Drawing.Size(348, 112)
$settingsPanel.BackColor = $panelBg
$settingsPanel.BorderStyle = 'FixedSingle'
$settingsPanel.Anchor = 'Top, Left, Right'
$form.Controls.Add($settingsPanel)

$settingsHeading = New-Object System.Windows.Forms.Label
$settingsHeading.Text = 'SESSION OPTIONS'
$settingsHeading.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8)
$settingsHeading.ForeColor = $accent
$settingsHeading.Location = New-Object System.Drawing.Point(11, 6)
$settingsHeading.AutoSize = $true
$settingsPanel.Controls.Add($settingsHeading)

$batteryPanel = New-Object System.Windows.Forms.Panel
$batteryPanel.Location = New-Object System.Drawing.Point(16, 322)
$batteryPanel.Size = New-Object System.Drawing.Size(348, 82)
$batteryPanel.BackColor = $panelBg
$batteryPanel.BorderStyle = 'FixedSingle'
$batteryPanel.Anchor = 'Top, Left, Right'
$form.Controls.Add($batteryPanel)

$batteryLabel = New-Object System.Windows.Forms.Label
$batteryLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$batteryLabel.ForeColor = $text
$batteryLabel.Location = New-Object System.Drawing.Point(11, 5)
$batteryLabel.Size = New-Object System.Drawing.Size(324, 20)
$batteryLabel.Anchor = 'Top, Left, Right'
$batteryPanel.Controls.Add($batteryLabel)

$timerCheck = New-Object System.Windows.Forms.CheckBox
$timerCheck.Text = 'Silent heads-down timer'
$timerCheck.Checked = $true
$timerCheck.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$timerCheck.ForeColor = $text
$timerCheck.FlatStyle = 'Flat'
$timerCheck.Location = New-Object System.Drawing.Point(11, 25)
$timerCheck.Size = New-Object System.Drawing.Size(200, 24)
$settingsPanel.Controls.Add($timerCheck)

$timerMinutes = New-Object System.Windows.Forms.NumericUpDown
$timerMinutes.Minimum = 1
$timerMinutes.Maximum = 180
$timerMinutes.Value = 20
$timerMinutes.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$timerMinutes.ForeColor = $text
$timerMinutes.BackColor = $panelBg
$timerMinutes.BorderStyle = 'FixedSingle'
$timerMinutes.Location = New-Object System.Drawing.Point(268, 25)
$timerMinutes.Size = New-Object System.Drawing.Size(48, 24)
$timerMinutes.Anchor = 'Top, Right'
$settingsPanel.Controls.Add($timerMinutes)

$minutesLabel = New-Object System.Windows.Forms.Label
$minutesLabel.Text = 'min'
$minutesLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$minutesLabel.ForeColor = $muted
$minutesLabel.Location = New-Object System.Drawing.Point(319, 28)
$minutesLabel.Anchor = 'Top, Right'
$minutesLabel.AutoSize = $true
$settingsPanel.Controls.Add($minutesLabel)

$focusCheck = New-Object System.Windows.Forms.CheckBox
$focusCheck.Text = 'Silence notifications'
$focusCheck.Checked = $true
$focusCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$focusCheck.ForeColor = $text
$focusCheck.FlatStyle = 'Flat'
$focusCheck.Location = New-Object System.Drawing.Point(11, 53)
$focusCheck.Size = New-Object System.Drawing.Size(150, 24)
$settingsPanel.Controls.Add($focusCheck)

$mediaKeysCheck = New-Object System.Windows.Forms.CheckBox
$mediaKeysCheck.Text = 'Keep media keys'
$mediaKeysCheck.Checked = $true
$mediaKeysCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$mediaKeysCheck.ForeColor = $text
$mediaKeysCheck.FlatStyle = 'Flat'
$mediaKeysCheck.Location = New-Object System.Drawing.Point(197, 53)
$mediaKeysCheck.Size = New-Object System.Drawing.Size(138, 24)
$mediaKeysCheck.Anchor = 'Top, Right'
$settingsPanel.Controls.Add($mediaKeysCheck)

$ecoCheck = New-Object System.Windows.Forms.CheckBox
$ecoCheck.Text = 'Use eco mode'
$ecoCheck.Checked = $true
$ecoCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$ecoCheck.ForeColor = $text
$ecoCheck.FlatStyle = 'Flat'
$ecoCheck.Location = New-Object System.Drawing.Point(11, 79)
$ecoCheck.Size = New-Object System.Drawing.Size(150, 24)
$settingsPanel.Controls.Add($ecoCheck)

$screenOffCheck = New-Object System.Windows.Forms.CheckBox
$screenOffCheck.Text = 'Screen off in 10 sec'
$screenOffCheck.Checked = $true
$screenOffCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$screenOffCheck.ForeColor = $text
$screenOffCheck.FlatStyle = 'Flat'
$screenOffCheck.Location = New-Object System.Drawing.Point(197, 79)
$screenOffCheck.Size = New-Object System.Drawing.Size(138, 24)
$screenOffCheck.Anchor = 'Top, Right'
$settingsPanel.Controls.Add($screenOffCheck)

$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 8000
$toolTip.InitialDelay = 400
$toolTip.ReshowDelay = 100
$toolTip.SetToolTip($timerCheck, 'Run a silent countdown while the keyboard is locked.')
$toolTip.SetToolTip($focusCheck, 'Temporarily silence normal Windows toast notifications.')
$toolTip.SetToolTip($mediaKeysCheck, 'Allow volume and playback keys while normal typing stays blocked.')
$toolTip.SetToolTip($ecoCheck, 'Use Power Saver and dim supported built-in displays while locked.')
$toolTip.SetToolTip($screenOffCheck, 'Turn the display off 10 seconds after locking; move the mouse to wake it.')

$powerStateLabel = New-Object System.Windows.Forms.Label
$powerStateLabel.Text = 'Eco mode: OFF'
$powerStateLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$powerStateLabel.ForeColor = $muted
$powerStateLabel.Location = New-Object System.Drawing.Point(11, 25)
$powerStateLabel.Size = New-Object System.Drawing.Size(324, 17)
$powerStateLabel.Anchor = 'Top, Left, Right'
$batteryPanel.Controls.Add($powerStateLabel)

function New-PowerButton {
    param([string]$Caption)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Caption
    $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
    $button.ForeColor = $text
    $button.BackColor = $panelBg
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = $border
    $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(39, 45, 58)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Dock = 'Fill'
    $button.Margin = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
    return $button
}

$powerButtonsPanel = New-Object System.Windows.Forms.TableLayoutPanel
$powerButtonsPanel.Location = New-Object System.Drawing.Point(7, 45)
$powerButtonsPanel.Size = New-Object System.Drawing.Size(332, 29)
$powerButtonsPanel.Anchor = 'Top, Left, Right'
$powerButtonsPanel.ColumnCount = 3
$powerButtonsPanel.RowCount = 1
$powerButtonsPanel.BackColor = $panelBg
$powerButtonsPanel.Padding = New-Object System.Windows.Forms.Padding(0)
foreach ($columnWidth in @(33.33, 33.33, 33.34)) {
    $columnStyle = New-Object System.Windows.Forms.ColumnStyle
    $columnStyle.SizeType = [System.Windows.Forms.SizeType]::Percent
    $columnStyle.Width = [single]$columnWidth
    $powerButtonsPanel.ColumnStyles.Add($columnStyle) | Out-Null
}
$batteryPanel.Controls.Add($powerButtonsPanel)

$dimButton = New-PowerButton -Caption 'DIM 10%'
$screenButton = New-PowerButton -Caption 'SCREEN OFF'
$restoreButton = New-PowerButton -Caption 'RESTORE'
$powerButtonsPanel.Controls.Add($dimButton, 0, 0)
$powerButtonsPanel.Controls.Add($screenButton, 1, 0)
$powerButtonsPanel.Controls.Add($restoreButton, 2, 0)

$footerLabel = New-Object System.Windows.Forms.Label
$footerLabel.Text = 'The mouse always works. Ctrl+Alt+Delete is kept by Windows.'
$footerLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$footerLabel.ForeColor = $muted
$footerLabel.Location = New-Object System.Drawing.Point(16, 412)
$footerLabel.Size = New-Object System.Drawing.Size(348, 24)
$footerLabel.TextAlign = 'MiddleCenter'
$footerLabel.Anchor = 'Top, Left, Right'
$form.Controls.Add($footerLabel)

$screenOffTimer = New-Object System.Windows.Forms.Timer
$screenOffTimer.Interval = 1000
$screenOffTimer.Add_Tick({
    $script:Countdown--
    if ($script:Countdown -le 0) {
        $screenOffTimer.Stop()
        $countdownLabel.Text = 'Display is off - move the mouse to wake it'
        [MonitorPower]::TurnOff()
    }
    else {
        $countdownLabel.Text = "Display turns off in $script:Countdown seconds - move the mouse to wake it"
    }
})

$restTimer = New-Object System.Windows.Forms.Timer
$restTimer.Interval = 1000
$restTimer.Add_Tick({
    if (-not $script:Locked) {
        $restTimer.Stop()
        return
    }

    $script:RestSeconds--
    if ($script:RestSeconds -le 0) {
        $restTimer.Stop()
        $screenOffTimer.Stop()
        $script:RestSeconds = 0
        [MonitorPower]::TurnOn()
        if ($script:EcoApplied) { Restore-PowerSettings }
        Restore-FocusMode
        $statusLabel.Text = 'HEADS-DOWN TIMER FINISHED'
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 193, 92)
        $timerDisplayLabel.Text = 'Timer complete - keyboard is still locked'
        $countdownLabel.Text = 'Click UNLOCK KEYBOARD when you are ready.'
        $form.WindowState = 'Normal'
        $form.Activate()
    }
    else {
        Update-RestTimerDisplay
    }
})

$batteryTimer = New-Object System.Windows.Forms.Timer
$batteryTimer.Interval = 15000
$batteryTimer.Add_Tick({ Update-BatteryStatus })

$timerCheck.Add_CheckedChanged({
    $timerMinutes.Enabled = $timerCheck.Checked
})

$toggleButton.Add_Click({
    if ($script:Locked) { Unlock-Keyboard } else { Lock-Keyboard }
})

$dimButton.Add_Click({
    if (Set-InternalBrightness -Level 10) {
        $script:EcoApplied = $true
        $powerStateLabel.Text = 'Brightness set to 10%'
        $powerStateLabel.ForeColor = [System.Drawing.Color]::FromArgb(116, 226, 151)
    }
    else {
        $powerStateLabel.Text = 'Brightness control is unavailable for this display'
        $powerStateLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 193, 92)
    }
})

$screenButton.Add_Click({ [MonitorPower]::TurnOff() })
$restoreButton.Add_Click({ Restore-PowerSettings })

$form.Add_FormClosing({
    $screenOffTimer.Stop()
    $restTimer.Stop()
    $batteryTimer.Stop()
    [KeyboardBlocker]::Unlock()
    if ($script:EcoApplied) { Restore-PowerSettings }
    Restore-FocusMode
})

Set-LabelState -IsLocked $false
Update-BatteryStatus

if ($SmokeTest) {
    $null = $form.Handle
    $screenOffTimer.Stop()
    $restTimer.Stop()
    $batteryTimer.Stop()
    [KeyboardBlocker]::Unlock()
    $form.Dispose()
    Write-Output 'HeadDown Windows PowerShell 5.1 smoke test passed.'
    exit 0
}

$batteryTimer.Start()
[System.Windows.Forms.Application]::Run($form)
