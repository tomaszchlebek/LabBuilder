// LabBuilderSetup - embedded application payload (ADR 0011). C# 5.
using System;
using System.IO;
using System.IO.Compression;
using System.Reflection;

namespace LabBuilderSetup
{
    public static class Payload
    {
        const string ResourceName = "LabBuilderSetup.payload.zip";

        public static string Version
        {
            get
            {
                var a = Assembly.GetExecutingAssembly().GetCustomAttributes(typeof(AssemblyInformationalVersionAttribute), false);
                return a.Length > 0 ? ((AssemblyInformationalVersionAttribute)a[0]).InformationalVersion : "dev";
            }
        }

        /// <summary>Extracts the payload into target. Files are overwritten; output\ and config\lab.config.psd1 are never in the payload.</summary>
        public static void ExtractTo(string target)
        {
            Directory.CreateDirectory(target);
            string root = Path.GetFullPath(target).TrimEnd('\\') + "\\";
            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
            {
                if (s == null) throw new InvalidOperationException("Payload resource missing - rebuild with installer\\build.ps1.");
                using (var zip = new ZipArchive(s, ZipArchiveMode.Read))
                {
                    foreach (var e in zip.Entries)
                    {
                        string dest = Path.GetFullPath(Path.Combine(root, e.FullName.Replace('/', '\\')));
                        if (!dest.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Invalid payload path: " + e.FullName);
                        if (e.FullName.EndsWith("/")) { Directory.CreateDirectory(dest); continue; }
                        Directory.CreateDirectory(Path.GetDirectoryName(dest));
                        if (File.Exists(dest)) File.SetAttributes(dest, FileAttributes.Normal);
                        e.ExtractToFile(dest, true);
                    }
                }
            }
        }
    }
}
