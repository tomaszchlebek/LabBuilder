// LabBuilderSetup - entry point (ADR 0011). C# 5, .NET Framework 4.8.
using System;
using System.Threading;
using System.Windows.Forms;

namespace LabBuilderSetup
{
    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += (s, e) => ShowError(e.Exception);
            AppDomain.CurrentDomain.UnhandledException += (s, e) => ShowError(e.ExceptionObject as Exception);

            if (args.Length > 0 && (args[0] == "/?" || args[0] == "--help"))
            {
                MessageBox.Show("LabBuilderSetup.exe [--config <file.psd1>]\n\nWizard that installs LabBuilder and builds the Hyper-V test lab.",
                    "LabBuilder Setup", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 0;
            }
            string preload = null;
            for (int i = 0; i < args.Length - 1; i++) if (args[i] == "--config") preload = args[i + 1];

            Application.Run(new WizardForm(preload));
            return 0;
        }

        static void ShowError(Exception ex)
        {
            MessageBox.Show(ex == null ? "Unknown error" : ex.ToString(), "LabBuilder Setup - unexpected error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
