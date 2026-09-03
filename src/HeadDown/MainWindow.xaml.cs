using System;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace HeadDown
{
    public partial class MainWindow : Window
    {
        private static readonly Brush ReadyBrush = new SolidColorBrush(Color.FromRgb(116, 226, 151));
        private static readonly Brush LockedBrush = new SolidColorBrush(Color.FromRgb(255, 107, 107));
        private static readonly Brush WarningBrush = new SolidColorBrush(Color.FromRgb(255, 193, 92));
        private static readonly Brush MutedBrush = new SolidColorBrush(Color.FromRgb(150, 160, 180));
        private static readonly Brush GreenButtonBrush = new SolidColorBrush(Color.FromRgb(45, 150, 90));
        private static readonly Brush RedButtonBrush = new SolidColorBrush(Color.FromRgb(220, 70, 70));

        private readonly KeyboardBlocker _keyboardBlocker = new KeyboardBlocker();
        private readonly PowerSettingsManager _powerSettings = new PowerSettingsManager();
        private readonly FocusModeManager _focusMode = new FocusModeManager();
        private readonly DispatcherTimer _restTimer;
        private readonly DispatcherTimer _screenOffTimer;
        private readonly DispatcherTimer _batteryTimer;

        private bool _locked;
        private bool _ecoApplied;
        private DateTime _timerEndsAt;
        private int _screenOffSeconds;

        public MainWindow()
        {
            InitializeComponent();

            ReadyBrush.Freeze();
            LockedBrush.Freeze();
            WarningBrush.Freeze();
            MutedBrush.Freeze();
            GreenButtonBrush.Freeze();
            RedButtonBrush.Freeze();

            _restTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _restTimer.Tick += RestTimer_Tick;

            _screenOffTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _screenOffTimer.Tick += ScreenOffTimer_Tick;

            _batteryTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(15) };
            _batteryTimer.Tick += delegate { UpdateBatteryStatus(); };

            Closing += MainWindow_Closing;
            UpdateBatteryStatus();
            _batteryTimer.Start();
        }

        public void RenderPreview(string outputPath)
        {
            FrameworkElement content = Content as FrameworkElement;
            if (content == null)
                throw new InvalidOperationException("The interface could not be rendered.");

            const int width = 420;
            const int height = 540;
            content.Measure(new Size(width, height));
            content.Arrange(new Rect(0, 0, width, height));
            content.UpdateLayout();

            RenderTargetBitmap bitmap = new RenderTargetBitmap(
                width,
                height,
                96,
                96,
                PixelFormats.Pbgra32);
            bitmap.Render(content);

            string directory = Path.GetDirectoryName(Path.GetFullPath(outputPath));
            if (!Directory.Exists(directory))
                Directory.CreateDirectory(directory);

            PngBitmapEncoder encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using (FileStream stream = File.Create(outputPath))
                encoder.Save(stream);
        }

        private void LockButton_Click(object sender, RoutedEventArgs e)
        {
            if (_locked)
            {
                UnlockKeyboard();
                return;
            }

            int timerMinutes;
            if (TimerEnabledCheckBox.IsChecked == true &&
                (!int.TryParse(TimerMinutesTextBox.Text, out timerMinutes) || timerMinutes < 1 || timerMinutes > 180))
            {
                MessageBox.Show(
                    "Enter a timer length from 1 to 180 minutes.",
                    "HeadDown",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                TimerMinutesTextBox.Focus();
                TimerMinutesTextBox.SelectAll();
                return;
            }

            try
            {
                _keyboardBlocker.Start(MediaKeysCheckBox.IsChecked == true);
            }
            catch (Exception exception)
            {
                MessageBox.Show(
                    exception.Message,
                    "HeadDown",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            _locked = true;
            Topmost = true;
            SessionOptionsPanel.IsEnabled = false;
            StatusText.Text = "KEYBOARD LOCKED";
            StatusText.Foreground = LockedBrush;
            LockButton.Content = "UNLOCK KEYBOARD";
            LockButton.Background = RedButtonBrush;

            if (EcoCheckBox.IsChecked == true)
            {
                _ecoApplied = _powerSettings.EnableEcoMode();
                PowerStateText.Text = _ecoApplied
                    ? "Eco mode: ON"
                    : "Eco mode unavailable on this display/device";
                PowerStateText.Foreground = _ecoApplied ? ReadyBrush : WarningBrush;
            }

            if (FocusCheckBox.IsChecked == true && !_focusMode.Enable())
            {
                StatusDetailText.Text = "Focus mode unavailable; keyboard lock is still active.";
            }

            if (TimerEnabledCheckBox.IsChecked == true)
            {
                timerMinutes = int.Parse(TimerMinutesTextBox.Text);
                _timerEndsAt = DateTime.Now.AddMinutes(timerMinutes);
                UpdateTimerDisplay();
                _restTimer.Start();
            }
            else
            {
                TimerDisplayText.Text = "Timer: off";
            }

            if (ScreenOffCheckBox.IsChecked == true)
            {
                _screenOffSeconds = 10;
                StatusDetailText.Text = "Display turns off in 10 seconds • move the mouse to wake";
                _screenOffTimer.Start();
            }
            else if (FocusCheckBox.IsChecked != true || StatusDetailText.Text.IndexOf("unavailable", StringComparison.OrdinalIgnoreCase) < 0)
            {
                StatusDetailText.Text = "Mouse stays active • click UNLOCK when you are ready";
            }
        }

        private void UnlockKeyboard()
        {
            _screenOffTimer.Stop();
            _restTimer.Stop();
            _keyboardBlocker.Stop();
            _focusMode.Restore();
            if (_ecoApplied)
                _powerSettings.Restore();

            _locked = false;
            _ecoApplied = false;
            Topmost = false;
            SessionOptionsPanel.IsEnabled = true;
            StatusText.Text = "Keyboard ready";
            StatusText.Foreground = ReadyBrush;
            LockButton.Content = "LOCK KEYBOARD";
            LockButton.Background = GreenButtonBrush;
            TimerDisplayText.Text = "Timer: off";
            StatusDetailText.Text = "Mouse stays active. Closing the app also unlocks it.";
            PowerStateText.Text = "Eco mode: OFF";
            PowerStateText.Foreground = MutedBrush;
        }

        private void RestTimer_Tick(object sender, EventArgs e)
        {
            if (!_locked)
            {
                _restTimer.Stop();
                return;
            }

            if (_timerEndsAt <= DateTime.Now)
            {
                _restTimer.Stop();
                _screenOffTimer.Stop();
                MonitorPower.TurnOn();
                _focusMode.Restore();
                if (_ecoApplied)
                {
                    _powerSettings.Restore();
                    _ecoApplied = false;
                }

                StatusText.Text = "HEADS-DOWN TIMER FINISHED";
                StatusText.Foreground = WarningBrush;
                TimerDisplayText.Text = "Timer complete • keyboard is still locked";
                StatusDetailText.Text = "Click UNLOCK KEYBOARD when you are ready.";
                PowerStateText.Text = "Eco mode: OFF";
                PowerStateText.Foreground = MutedBrush;
                WindowState = WindowState.Normal;
                Activate();
                return;
            }

            UpdateTimerDisplay();
        }

        private void UpdateTimerDisplay()
        {
            TimeSpan remaining = _timerEndsAt - DateTime.Now;
            if (remaining < TimeSpan.Zero)
                remaining = TimeSpan.Zero;

            TimerDisplayText.Text = remaining.TotalHours >= 1
                ? string.Format("Timer: {0}:{1:00}:{2:00}", (int)remaining.TotalHours, remaining.Minutes, remaining.Seconds)
                : string.Format("Timer: {0}:{1:00}", remaining.Minutes, remaining.Seconds);
        }

        private void ScreenOffTimer_Tick(object sender, EventArgs e)
        {
            _screenOffSeconds--;
            if (_screenOffSeconds <= 0)
            {
                _screenOffTimer.Stop();
                StatusDetailText.Text = "Display is off • move the mouse to wake it";
                MonitorPower.TurnOff();
            }
            else
            {
                StatusDetailText.Text = string.Format(
                    "Display turns off in {0} seconds • move the mouse to wake",
                    _screenOffSeconds);
            }
        }

        private void UpdateBatteryStatus()
        {
            System.Windows.Forms.PowerStatus power = System.Windows.Forms.SystemInformation.PowerStatus;
            if ((power.BatteryChargeStatus & System.Windows.Forms.BatteryChargeStatus.NoSystemBattery) != 0)
            {
                BatteryText.Text = "Battery: not detected";
                return;
            }

            int percent = (int)Math.Round(power.BatteryLifePercent * 100);
            string source = power.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Online
                ? "plugged in"
                : "on battery";
            BatteryText.Text = string.Format("Battery: {0}% • {1}", percent, source);
        }

        private void TimerEnabledCheckBox_Changed(object sender, RoutedEventArgs e)
        {
            if (TimerMinutesTextBox != null)
                TimerMinutesTextBox.IsEnabled = TimerEnabledCheckBox.IsChecked == true;
        }

        private void TimerMinutesTextBox_PreviewTextInput(object sender, TextCompositionEventArgs e)
        {
            e.Handled = !Regex.IsMatch(e.Text, "^[0-9]+$");
        }

        private void DimButton_Click(object sender, RoutedEventArgs e)
        {
            if (_powerSettings.DimToTenPercent())
            {
                _ecoApplied = true;
                PowerStateText.Text = "Brightness set to 10%";
                PowerStateText.Foreground = ReadyBrush;
            }
            else
            {
                PowerStateText.Text = "Brightness control unavailable for this display";
                PowerStateText.Foreground = WarningBrush;
            }
        }

        private void ScreenOffButton_Click(object sender, RoutedEventArgs e)
        {
            MonitorPower.TurnOff();
        }

        private void RestoreButton_Click(object sender, RoutedEventArgs e)
        {
            _powerSettings.Restore();
            _ecoApplied = false;
            PowerStateText.Text = "Eco mode: OFF";
            PowerStateText.Foreground = MutedBrush;
        }

        private void MinimizeButton_Click(object sender, RoutedEventArgs e)
        {
            WindowState = WindowState.Minimized;
        }

        private void CloseButton_Click(object sender, RoutedEventArgs e)
        {
            Close();
        }

        private void MainWindow_Closing(object sender, System.ComponentModel.CancelEventArgs e)
        {
            _restTimer.Stop();
            _screenOffTimer.Stop();
            _batteryTimer.Stop();
            _keyboardBlocker.Stop();
            _focusMode.Restore();
            if (_ecoApplied)
                _powerSettings.Restore();
        }
    }
}
