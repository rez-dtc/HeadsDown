using System;
using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32;

namespace HeadDown
{
    internal static class MonitorPower
    {
        private const int HwndBroadcast = 0xffff;
        private const int WmSysCommand = 0x0112;
        private const int ScMonitorPower = 0xF170;

        public static void TurnOff()
        {
            SendMessage((IntPtr)HwndBroadcast, WmSysCommand, (IntPtr)ScMonitorPower, (IntPtr)2);
        }

        public static void TurnOn()
        {
            SendMessage((IntPtr)HwndBroadcast, WmSysCommand, (IntPtr)ScMonitorPower, (IntPtr)(-1));
        }

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wordParameter, IntPtr longParameter);
    }

    internal sealed class PowerSettingsManager
    {
        private const string PowerSaverGuid = "a1841308-3541-4fab-bc81-f71556f20b4a";
        private readonly string _originalPowerScheme;
        private readonly int? _originalBrightness;

        public PowerSettingsManager()
        {
            _originalPowerScheme = GetActivePowerScheme();
            _originalBrightness = GetInternalBrightness();
        }

        public bool EnableEcoMode()
        {
            bool changed = false;
            if (RunPowerCfg("/setactive " + PowerSaverGuid).Item1 == 0)
                changed = true;
            if (SetInternalBrightness(10))
                changed = true;
            return changed;
        }

        public bool DimToTenPercent()
        {
            return SetInternalBrightness(10);
        }

        public void Restore()
        {
            if (!string.IsNullOrWhiteSpace(_originalPowerScheme))
                RunPowerCfg("/setactive " + _originalPowerScheme);
            if (_originalBrightness.HasValue)
                SetInternalBrightness(_originalBrightness.Value);
        }

        private static string GetActivePowerScheme()
        {
            Tuple<int, string> result = RunPowerCfg("/getactivescheme");
            Match match = Regex.Match(
                result.Item2 ?? string.Empty,
                "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}");
            return match.Success ? match.Value : null;
        }

        private static Tuple<int, string> RunPowerCfg(string arguments)
        {
            try
            {
                ProcessStartInfo info = new ProcessStartInfo
                {
                    FileName = "powercfg.exe",
                    Arguments = arguments,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                using (Process process = Process.Start(info))
                {
                    string output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
                    process.WaitForExit();
                    return Tuple.Create(process.ExitCode, output);
                }
            }
            catch (Exception exception)
            {
                return Tuple.Create(-1, exception.Message);
            }
        }

        private static int? GetInternalBrightness()
        {
            try
            {
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(
                    "root\\WMI",
                    "SELECT CurrentBrightness FROM WmiMonitorBrightness"))
                {
                    foreach (ManagementObject monitor in searcher.Get())
                    {
                        using (monitor)
                            return Convert.ToInt32(monitor["CurrentBrightness"]);
                    }
                }
            }
            catch
            {
            }

            return null;
        }

        private static bool SetInternalBrightness(int level)
        {
            try
            {
                using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(
                    "root\\WMI",
                    "SELECT * FROM WmiMonitorBrightnessMethods"))
                {
                    bool changed = false;
                    foreach (ManagementObject monitor in searcher.Get())
                    {
                        using (monitor)
                        {
                            monitor.InvokeMethod(
                                "WmiSetBrightness",
                                new object[] { UInt32.MaxValue, (byte)level });
                            changed = true;
                        }
                    }
                    return changed;
                }
            }
            catch
            {
                return false;
            }
        }
    }

    internal sealed class FocusModeManager
    {
        private const string RegistryPath = @"Software\Microsoft\Windows\CurrentVersion\PushNotifications";
        private const string ToastValue = "ToastEnabled";
        private const string RecoveryValue = "HeadDownOriginalToastEnabled";

        private bool _originalExists;
        private int _originalValue;
        private bool _applied;

        public FocusModeManager()
        {
            RecoverStaleSetting();
            CaptureOriginalSetting();
        }

        public bool Enable()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RegistryPath))
                {
                    key.SetValue(RecoveryValue, _originalExists ? _originalValue : -1, RegistryValueKind.DWord);
                    key.SetValue(ToastValue, 0, RegistryValueKind.DWord);
                }
                BroadcastSettingChange();
                _applied = true;
                return true;
            }
            catch
            {
                return false;
            }
        }

        public void Restore()
        {
            if (!_applied)
                return;

            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RegistryPath))
                {
                    if (_originalExists)
                        key.SetValue(ToastValue, _originalValue, RegistryValueKind.DWord);
                    else
                        key.DeleteValue(ToastValue, false);
                    key.DeleteValue(RecoveryValue, false);
                }
                BroadcastSettingChange();
            }
            catch
            {
            }
            finally
            {
                _applied = false;
            }
        }

        private static void RecoverStaleSetting()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RegistryPath))
                {
                    object previousValue = key.GetValue(RecoveryValue, null);
                    if (previousValue == null)
                        return;

                    int previous = Convert.ToInt32(previousValue);
                    if (previous == -1)
                        key.DeleteValue(ToastValue, false);
                    else
                        key.SetValue(ToastValue, previous, RegistryValueKind.DWord);
                    key.DeleteValue(RecoveryValue, false);
                }
                BroadcastSettingChange();
            }
            catch
            {
            }
        }

        private void CaptureOriginalSetting()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RegistryPath))
                {
                    object value = key.GetValue(ToastValue, null);
                    _originalExists = value != null;
                    if (_originalExists)
                        _originalValue = Convert.ToInt32(value);
                }
            }
            catch
            {
                _originalExists = false;
            }
        }

        private static void BroadcastSettingChange()
        {
            IntPtr result;
            SendMessageTimeout(
                (IntPtr)0xffff,
                0x001A,
                IntPtr.Zero,
                IntPtr.Zero,
                0x0002,
                1000,
                out result);
        }

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(
            IntPtr window,
            uint message,
            IntPtr wordParameter,
            IntPtr longParameter,
            uint flags,
            uint timeout,
            out IntPtr result);
    }
}
