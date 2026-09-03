using System;
using System.Linq;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace HeadDown
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            DispatcherUnhandledException += OnDispatcherUnhandledException;
            base.OnStartup(e);

            MainWindow window = new MainWindow();
            int previewArgument = Array.FindIndex(
                e.Args,
                argument => string.Equals(argument, "--render-preview", StringComparison.OrdinalIgnoreCase));
            if (previewArgument >= 0 && previewArgument + 1 < e.Args.Length)
            {
                window.RenderPreview(e.Args[previewArgument + 1]);
                window.Close();
                Shutdown(0);
                return;
            }

            if (e.Args.Any(argument => string.Equals(argument, "--smoke-test", StringComparison.OrdinalIgnoreCase)))
            {
                new WindowInteropHelper(window).EnsureHandle();
                window.Close();
                Shutdown(0);
                return;
            }

            MainWindow = window;
            window.Show();
        }

        private static void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            MessageBox.Show(
                "HeadDown ran into an unexpected error:\n\n" + e.Exception.Message,
                "HeadDown",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            e.Handled = true;
        }
    }
}
