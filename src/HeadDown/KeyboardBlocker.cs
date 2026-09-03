using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace HeadDown
{
    internal sealed class KeyboardBlocker : IDisposable
    {
        private const int WhKeyboardLl = 13;
        private const int WmKeyDown = 0x0100;
        private const int WmKeyUp = 0x0101;
        private const int WmSysKeyDown = 0x0104;
        private const int WmSysKeyUp = 0x0105;

        private readonly LowLevelKeyboardProc _callback;
        private IntPtr _hook = IntPtr.Zero;
        private bool _allowMediaKeys;

        public KeyboardBlocker()
        {
            _callback = HookCallback;
        }

        public bool IsLocked
        {
            get { return _hook != IntPtr.Zero; }
        }

        public void Start(bool allowMediaKeys)
        {
            _allowMediaKeys = allowMediaKeys;
            if (IsLocked)
                return;

            using (Process process = Process.GetCurrentProcess())
            using (ProcessModule module = process.MainModule)
            {
                _hook = SetWindowsHookEx(
                    WhKeyboardLl,
                    _callback,
                    GetModuleHandle(module.ModuleName),
                    0);
            }

            if (_hook == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows could not start the keyboard lock.");
        }

        public void Stop()
        {
            if (!IsLocked)
                return;

            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }

        public void Dispose()
        {
            Stop();
        }

        private IntPtr HookCallback(int code, IntPtr messagePointer, IntPtr dataPointer)
        {
            if (code >= 0)
            {
                int message = messagePointer.ToInt32();
                if (message == WmKeyDown || message == WmKeyUp ||
                    message == WmSysKeyDown || message == WmSysKeyUp)
                {
                    int virtualKey = Marshal.ReadInt32(dataPointer);
                    if (_allowMediaKeys && IsMediaKey(virtualKey))
                        return CallNextHookEx(_hook, code, messagePointer, dataPointer);

                    return (IntPtr)1;
                }
            }

            return CallNextHookEx(_hook, code, messagePointer, dataPointer);
        }

        private static bool IsMediaKey(int key)
        {
            return key == 0xAD || // Volume mute
                   key == 0xAE || // Volume down
                   key == 0xAF || // Volume up
                   key == 0xB0 || // Next track
                   key == 0xB1 || // Previous track
                   key == 0xB2 || // Stop
                   key == 0xB3;   // Play/pause
        }

        private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr messagePointer, IntPtr dataPointer);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr SetWindowsHookEx(
            int hookType,
            LowLevelKeyboardProc callback,
            IntPtr module,
            uint threadId);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hook);

        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(
            IntPtr hook,
            int code,
            IntPtr messagePointer,
            IntPtr dataPointer);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr GetModuleHandle(string moduleName);
    }
}
