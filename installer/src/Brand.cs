// LabBuilderSetup - ITOM Solutions branding (www.itomsol.com). C# 5.
// Mark and colours are the same as the IT Portal product branding (IT Notifications ADR 0014):
// lime #C6F277 rounded square with an ink #111A24 "i"; wordmark in Segoe UI.
using System.Drawing;
using System.IO;
using System.Reflection;

namespace LabBuilderSetup
{
    static class Brand
    {
        public static readonly Color Ink = Color.FromArgb(0x11, 0x1A, 0x24);     // #111A24
        public static readonly Color Lime = Color.FromArgb(0xC6, 0xF2, 0x77);    // #C6F277
        public static readonly Color Muted = Color.FromArgb(0x9A, 0xA6, 0xB2);   // secondary text on ink

        public const string ResourceName = "LabBuilderSetup.itom-mark.png";

        // Embedded by installer\build.ps1 from installer\branding\itom-mark.png; null if missing (UI still works).
        public static Image Mark()
        {
            try
            {
                using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
                {
                    if (s == null) return null;
                    var ms = new MemoryStream();
                    s.CopyTo(ms);
                    ms.Position = 0;
                    return Image.FromStream(ms);   // stream must stay open for the image's lifetime
                }
            }
            catch { return null; }
        }
    }
}
