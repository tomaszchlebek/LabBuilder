// LabBuilderSetup - runs Windows PowerShell scripts of the payload (ADR 0011). C# 5.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

namespace LabBuilderSetup
{
    public class RunResult
    {
        public int ExitCode;
        public List<string> Lines = new List<string>();
    }

    public static class PsRunner
    {
        public static string PowerShellExe
        {
            get { return Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"); }
        }

        static string Quote(string s) { return "\"" + s.Replace("\"", "\\\"") + "\""; }

        public static string FileArgs(string script, params string[] args)
        {
            var sb = new StringBuilder("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ");
            sb.Append(Quote(script));
            foreach (var a in args)
            {
                sb.Append(' ');
                sb.Append(a.StartsWith("-") ? a : Quote(a));
            }
            return sb.ToString();
        }

        static ProcessStartInfo Info(string arguments, string workDir)
        {
            var psi = new ProcessStartInfo(PowerShellExe, arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.RedirectStandardInput = true;
            psi.WorkingDirectory = workDir;
            return psi;
        }

        /// <summary>Runs a script and waits; collects stdout and stderr lines.</summary>
        public static RunResult Run(string arguments, string workDir, int timeoutMs)
        {
            var result = new RunResult();
            using (var p = new Process())
            {
                p.StartInfo = Info(arguments, workDir);
                var gate = new object();
                p.OutputDataReceived += (s, e) => { if (e.Data != null) lock (gate) result.Lines.Add(e.Data); };
                p.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (gate) result.Lines.Add("ERROR: " + e.Data); };
                p.Start();
                p.StandardInput.Close();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                if (!p.WaitForExit(timeoutMs))
                {
                    try { p.Kill(); } catch { }
                    result.ExitCode = -1;
                    result.Lines.Add("ERROR: timed out");
                    return result;
                }
                p.WaitForExit();
                result.ExitCode = p.ExitCode;
            }
            return result;
        }

        /// <summary>Starts a long-running script. The optional secret is written to stdin (never on the command line).</summary>
        public static Process Start(string arguments, string workDir, string stdinSecret, Action<string> onLine, Action<int> onExit)
        {
            var p = new Process();
            p.StartInfo = Info(arguments, workDir);
            p.EnableRaisingEvents = true;
            p.OutputDataReceived += (s, e) => { if (e.Data != null) onLine(e.Data); };
            p.ErrorDataReceived += (s, e) => { if (e.Data != null) onLine("ERROR: " + e.Data); };
            p.Exited += (s, e) => { p.WaitForExit(); onExit(p.ExitCode); };
            p.Start();
            if (!string.IsNullOrEmpty(stdinSecret)) p.StandardInput.WriteLine(stdinSecret);
            p.StandardInput.Close();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            return p;
        }

        /// <summary>Stops a process and its children (curl, etc.).</summary>
        public static void KillTree(Process p)
        {
            try
            {
                var k = Process.Start(new ProcessStartInfo("taskkill.exe", "/T /F /PID " + p.Id) { CreateNoWindow = true, UseShellExecute = false });
                if (k != null) k.WaitForExit(15000);
            }
            catch { try { p.Kill(); } catch { } }
        }
    }
}
