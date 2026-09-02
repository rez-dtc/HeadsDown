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
                return (IntPtr)1;
        }
        return CallNextHookEx(hook, nCode, wParam, lParam);
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
}
"@

$script:PowerSaverGuid = 'a1841308-3541-4fab-bc81-f71556f20b4a'
$script:OriginalPowerScheme = $null
$script:OriginalBrightness = $null
$script:Locked = $false
$script:EcoApplied = $false
$script:Countdown = 0

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
    [KeyboardBlocker]::Unlock()
    $script:Locked = $false
    if ($script:EcoApplied) { Restore-PowerSettings }
    Set-LabelState -IsLocked $false
}

function Lock-Keyboard {
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

$bg = [System.Drawing.Color]::FromArgb(24, 27, 34)
$panelBg = [System.Drawing.Color]::FromArgb(34, 38, 47)
$text = [System.Drawing.Color]::FromArgb(235, 238, 245)
$muted = [System.Drawing.Color]::FromArgb(170, 178, 193)
$border = [System.Drawing.Color]::FromArgb(64, 70, 84)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'HeadDown'
$form.Size = New-Object System.Drawing.Size(380, 520)
$form.MinimumSize = New-Object System.Drawing.Size(380, 520)
$form.MaximumSize = New-Object System.Drawing.Size(380, 520)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bg
$form.ForeColor = $text
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.AutoScaleMode = 'Dpi'

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'HeadDown'
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$titleLabel.ForeColor = $text
$titleLabel.Location = New-Object System.Drawing.Point(22, 18)
$titleLabel.AutoSize = $true
$form.Controls.Add($titleLabel)

$subtitleLabel = New-Object System.Windows.Forms.Label
$subtitleLabel.Text = 'Keyboard rest mode'
$subtitleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$subtitleLabel.ForeColor = $muted
$subtitleLabel.Location = New-Object System.Drawing.Point(24, 53)
$subtitleLabel.AutoSize = $true
$form.Controls.Add($subtitleLabel)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(20, 82)
$statusPanel.Size = New-Object System.Drawing.Size(326, 142)
$statusPanel.BackColor = $panelBg
$form.Controls.Add($statusPanel)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$statusLabel.Location = New-Object System.Drawing.Point(14, 14)
$statusLabel.Size = New-Object System.Drawing.Size(298, 24)
$statusLabel.TextAlign = 'MiddleCenter'
$statusPanel.Controls.Add($statusLabel)

$toggleButton = New-Object System.Windows.Forms.Button
$toggleButton.Location = New-Object System.Drawing.Point(16, 47)
$toggleButton.Size = New-Object System.Drawing.Size(294, 54)
$toggleButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$toggleButton.ForeColor = [System.Drawing.Color]::White
$toggleButton.FlatStyle = 'Flat'
$toggleButton.FlatAppearance.BorderSize = 0
$toggleButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$statusPanel.Controls.Add($toggleButton)

$countdownLabel = New-Object System.Windows.Forms.Label
$countdownLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$countdownLabel.ForeColor = $muted
$countdownLabel.Location = New-Object System.Drawing.Point(10, 109)
$countdownLabel.Size = New-Object System.Drawing.Size(306, 23)
$countdownLabel.TextAlign = 'MiddleCenter'
$statusPanel.Controls.Add($countdownLabel)

$batteryLabel = New-Object System.Windows.Forms.Label
$batteryLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$batteryLabel.ForeColor = $text
$batteryLabel.Location = New-Object System.Drawing.Point(24, 242)
$batteryLabel.Size = New-Object System.Drawing.Size(320, 25)
$form.Controls.Add($batteryLabel)

$ecoCheck = New-Object System.Windows.Forms.CheckBox
$ecoCheck.Text = 'Use eco mode while keyboard is locked'
$ecoCheck.Checked = $true
$ecoCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$ecoCheck.ForeColor = $text
$ecoCheck.Location = New-Object System.Drawing.Point(24, 276)
$ecoCheck.Size = New-Object System.Drawing.Size(320, 24)
$form.Controls.Add($ecoCheck)

$screenOffCheck = New-Object System.Windows.Forms.CheckBox
$screenOffCheck.Text = 'Turn display off 10 seconds after locking'
$screenOffCheck.Checked = $true
$screenOffCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
$screenOffCheck.ForeColor = $text
$screenOffCheck.Location = New-Object System.Drawing.Point(24, 306)
$screenOffCheck.Size = New-Object System.Drawing.Size(330, 24)
$form.Controls.Add($screenOffCheck)

$powerStateLabel = New-Object System.Windows.Forms.Label
$powerStateLabel.Text = 'Eco mode: OFF'
$powerStateLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$powerStateLabel.ForeColor = $muted
$powerStateLabel.Location = New-Object System.Drawing.Point(24, 339)
$powerStateLabel.Size = New-Object System.Drawing.Size(326, 22)
$form.Controls.Add($powerStateLabel)

function New-PowerButton {
    param([string]$Caption, [int]$X, [int]$Width)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Caption
    $button.Location = New-Object System.Drawing.Point($X, 373)
    $button.Size = New-Object System.Drawing.Size($Width, 40)
    $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
    $button.ForeColor = $text
    $button.BackColor = $panelBg
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderColor = $border
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $form.Controls.Add($button)
    return $button
}

$dimButton = New-PowerButton -Caption 'DIM TO 10%' -X 20 -Width 101
$screenButton = New-PowerButton -Caption 'SCREEN OFF' -X 130 -Width 105
$restoreButton = New-PowerButton -Caption 'RESTORE' -X 244 -Width 102

$footerLabel = New-Object System.Windows.Forms.Label
$footerLabel.Text = 'The mouse always works. Ctrl+Alt+Delete is kept by Windows.'
$footerLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$footerLabel.ForeColor = $muted
$footerLabel.Location = New-Object System.Drawing.Point(20, 438)
$footerLabel.Size = New-Object System.Drawing.Size(330, 34)
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

$batteryTimer = New-Object System.Windows.Forms.Timer
$batteryTimer.Interval = 15000
$batteryTimer.Add_Tick({ Update-BatteryStatus })

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
    $batteryTimer.Stop()
    [KeyboardBlocker]::Unlock()
    if ($script:EcoApplied) { Restore-PowerSettings }
})

Set-LabelState -IsLocked $false
Update-BatteryStatus
$batteryTimer.Start()
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)
