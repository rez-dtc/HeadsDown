# HeadDown - mouse-controlled keyboard rest mode for Windows 10/11
# No installation or administrator rights are required.

if ($PSVersionTable.PSVersion.Major -lt 5) {
    [System.Windows.Forms.MessageBox]::Show('HeadDown requires Windows PowerShell 5.1 or newer.', 'HeadDown')
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class RoundedPanel : Panel
{
    public int Radius { get; set; }

    public RoundedPanel()
    {
        Radius = 18;
        Resize += delegate { UpdateRegion(); };
    }

    private void UpdateRegion()
    {
        if (Width < 2 || Height < 2) return;
        int diameter = Math.Max(2, Radius * 2);
        GraphicsPath path = new GraphicsPath();
        path.AddArc(0, 0, diameter, diameter, 180, 90);
        path.AddArc(Width - diameter, 0, diameter, diameter, 270, 90);
        path.AddArc(Width - diameter, Height - diameter, diameter, diameter, 0, 90);
        path.AddArc(0, Height - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        Region previous = Region;
        Region = new Region(path);
        if (previous != null) previous.Dispose();
        path.Dispose();
    }
}

public class RoundedButton : Button
{
    public int Radius { get; set; }

    public RoundedButton()
    {
        Radius = 12;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Resize += delegate { UpdateRegion(); };
    }

    private void UpdateRegion()
    {
        if (Width < 2 || Height < 2) return;
        int diameter = Math.Max(2, Radius * 2);
        GraphicsPath path = new GraphicsPath();
        path.AddArc(0, 0, diameter, diameter, 180, 90);
        path.AddArc(Width - diameter, 0, diameter, diameter, 270, 90);
        path.AddArc(Width - diameter, Height - diameter, diameter, diameter, 0, 90);
        path.AddArc(0, Height - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        Region previous = Region;
        Region = new Region(path);
        if (previous != null) previous.Dispose();
        path.Dispose();
    }
}

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
"@

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
$form = New-Object System.Windows.Forms.Form
$form.Text = 'HeadDown'
$form.Size = New-Object System.Drawing.Size(400, 690)
$form.MinimumSize = New-Object System.Drawing.Size(400, 690)
$form.MaximumSize = New-Object System.Drawing.Size(400, 690)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bg
$form.ForeColor = $text
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.AutoScaleMode = 'Dpi'

$accentBar = New-Object System.Windows.Forms.Panel
$accentBar.Location = New-Object System.Drawing.Point(0, 0)
$accentBar.Size = New-Object System.Drawing.Size(400, 4)
$accentBar.BackColor = $accent
$form.Controls.Add($accentBar)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'HeadDown'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 20)
$titleLabel.ForeColor = $text
$titleLabel.Location = New-Object System.Drawing.Point(22, 20)
$titleLabel.AutoSize = $true
$form.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = 'Rest without accidental input'
$subtitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$subtitleLabel.ForeColor = $muted
$subtitleLabel.Location = New-Object System.Drawing.Point(24, 59)
$subtitleLabel.AutoSize = $true
$form.Controls.Add($subtitleLabel)

$statusPanel = New-Object RoundedPanel
$statusPanel.Radius = 18
$statusPanel.Location = New-Object System.Drawing.Point(20, 90)
$statusPanel.Size = New-Object System.Drawing.Size(346, 174)
$statusPanel.BackColor = $panelBg
$form.Controls.Add($statusPanel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$statusLabel.Location = New-Object System.Drawing.Point(14, 12)
$statusLabel.Size = New-Object System.Drawing.Size(318, 24)
$statusLabel.TextAlign = 'MiddleCenter'
$statusPanel.Controls.Add($statusLabel)

$toggleButton = New-Object RoundedButton
$toggleButton.Radius = 13
$toggleButton.Location = New-Object System.Drawing.Point(16, 44)
$toggleButton.Size = New-Object System.Drawing.Size(314, 54)
$toggleButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$toggleButton.ForeColor = [System.Drawing.Color]::White
$toggleButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$statusPanel.Controls.Add($toggleButton)

$timerDisplayLabel = New-Object System.Windows.Forms.Label
$timerDisplayLabel.Text = 'Timer: off'
$timerDisplayLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$timerDisplayLabel.ForeColor = $text
$timerDisplayLabel.Location = New-Object System.Drawing.Point(10, 105)
$timerDisplayLabel.Size = New-Object System.Drawing.Size(326, 24)
$timerDisplayLabel.TextAlign = 'MiddleCenter'
$statusPanel.Controls.Add($timerDisplayLabel)

$countdownLabel = New-Object System.Windows.Forms.Label
$countdownLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$countdownLabel.ForeColor = $muted
$countdownLabel.Location = New-Object System.Drawing.Point(10, 135)
$countdownLabel.Size = New-Object System.Drawing.Size(326, 23)
$countdownLabel.TextAlign = 'MiddleCenter'
$statusPanel.Controls.Add($countdownLabel)

$batteryLabel = New-Object System.Windows.Forms.Label
$batteryLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$batteryLabel.ForeColor = $text
$batteryLabel.Location = New-Object System.Drawing.Point(24, 279)
$batteryLabel.Size = New-Object System.Drawing.Size(340, 25)
$form.Controls.Add($batteryLabel)

$timerCheck = New-Object System.Windows.Forms.CheckBox
$timerCheck.Text = 'Use silent heads-down timer'
$timerCheck.Checked = $true
$timerCheck.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$timerCheck.ForeColor = $text
$timerCheck.FlatStyle = 'Flat'
$timerCheck.Location = New-Object System.Drawing.Point(24, 312)
$timerCheck.Size = New-Object System.Drawing.Size(245, 24)
$form.Controls.Add($timerCheck)

$timerMinutes = New-Object System.Windows.Forms.NumericUpDown
$timerMinutes.Minimum = 1
$timerMinutes.Maximum = 180
$timerMinutes.Value = 20
$timerMinutes.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$timerMinutes.ForeColor = $text
$timerMinutes.BackColor = $panelBg
$timerMinutes.BorderStyle = 'FixedSingle'
$timerMinutes.Location = New-Object System.Drawing.Point(44, 342)
$timerMinutes.Size = New-Object System.Drawing.Size(72, 26)
$form.Controls.Add($timerMinutes)

$minutesLabel = New-Object System.Windows.Forms.Label
$minutesLabel.Text = 'minutes'
$minutesLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$minutesLabel.ForeColor = $muted
$minutesLabel.Location = New-Object System.Drawing.Point(124, 345)
$minutesLabel.AutoSize = $true
$form.Controls.Add($minutesLabel)

$focusCheck = New-Object System.Windows.Forms.CheckBox
$focusCheck.Text = 'Focus mode - silence notifications while locked'
$focusCheck.Checked = $true
$focusCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$focusCheck.ForeColor = $text
$focusCheck.FlatStyle = 'Flat'
$focusCheck.Location = New-Object System.Drawing.Point(24, 378)
$focusCheck.Size = New-Object System.Drawing.Size(345, 24)
$form.Controls.Add($focusCheck)

$mediaKeysCheck = New-Object System.Windows.Forms.CheckBox
$mediaKeysCheck.Text = 'Keep volume and playback media keys working'
$mediaKeysCheck.Checked = $true
$mediaKeysCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$mediaKeysCheck.ForeColor = $text
$mediaKeysCheck.FlatStyle = 'Flat'
$mediaKeysCheck.Location = New-Object System.Drawing.Point(24, 408)
$mediaKeysCheck.Size = New-Object System.Drawing.Size(345, 24)
$form.Controls.Add($mediaKeysCheck)

$ecoCheck = New-Object System.Windows.Forms.CheckBox
$ecoCheck.Text = 'Use eco mode while keyboard is locked'
$ecoCheck.Checked = $true
$ecoCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$ecoCheck.ForeColor = $text
$ecoCheck.FlatStyle = 'Flat'
$ecoCheck.Location = New-Object System.Drawing.Point(24, 438)
$ecoCheck.Size = New-Object System.Drawing.Size(340, 24)
$form.Controls.Add($ecoCheck)

$screenOffCheck = New-Object System.Windows.Forms.CheckBox
$screenOffCheck.Text = 'Turn display off 10 seconds after locking'
$screenOffCheck.Checked = $true
$screenOffCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$screenOffCheck.ForeColor = $text
$screenOffCheck.FlatStyle = 'Flat'
$screenOffCheck.Location = New-Object System.Drawing.Point(24, 468)
$screenOffCheck.Size = New-Object System.Drawing.Size(340, 24)
$form.Controls.Add($screenOffCheck)

$powerStateLabel = New-Object System.Windows.Forms.Label
$powerStateLabel.Text = 'Eco mode: OFF'
$powerStateLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$powerStateLabel.ForeColor = $muted
$powerStateLabel.Location = New-Object System.Drawing.Point(24, 500)
$powerStateLabel.Size = New-Object System.Drawing.Size(346, 22)
$form.Controls.Add($powerStateLabel)

function New-PowerButton {
    param([string]$Caption, [int]$X, [int]$Width)
    $button = New-Object RoundedButton
    $button.Radius = 10
    $button.Text = $Caption
    $button.Location = New-Object System.Drawing.Point($X, 532)
    $button.Size = New-Object System.Drawing.Size($Width, 40)
    $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
    $button.ForeColor = $text
    $button.BackColor = $panelBg
    $button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(39, 45, 58)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($button)
    return $button
}

$dimButton = New-PowerButton -Caption 'DIM TO 10%' -X 20 -Width 108
$screenButton = New-PowerButton -Caption 'SCREEN OFF' -X 138 -Width 108
$restoreButton = New-PowerButton -Caption 'RESTORE' -X 256 -Width 110

$footerLabel = New-Object System.Windows.Forms.Label
$footerLabel.Text = 'The mouse always works. Ctrl+Alt+Delete is kept by Windows.'
$footerLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$footerLabel.ForeColor = $muted
$footerLabel.Location = New-Object System.Drawing.Point(20, 590)
$footerLabel.Size = New-Object System.Drawing.Size(346, 34)
$footerLabel.TextAlign = 'MiddleCenter'
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
$batteryTimer.Start()
[System.Windows.Forms.Application]::Run($form)
