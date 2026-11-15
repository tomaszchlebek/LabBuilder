// LabBuilderSetup - wizard UI (ADR 0011). C# 5, WinForms, no designer.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace LabBuilderSetup
{
    public class WizardForm : Form
    {
        class Page
        {
            public string Step;
            public string Title;
            public string Subtitle;
            public Control Content;
            public Func<bool> Leave;     // validate + store; false = stay
            public Action Enter;
            public Func<bool> Hidden;    // true = page not needed now: skipped by Next/Back and not listed in the steps
        }

        bool IsHidden(int i) { return pages[i].Hidden != null && pages[i].Hidden(); }

        // next/previous page that is not hidden (Welcome, Summary and Build are never hidden)
        int Neighbour(int from, int dir)
        {
            int i = from + dir;
            while (i > 0 && i < pages.Count - 1 && IsHidden(i)) i += dir;
            return i;
        }

        static readonly Regex NameRx = new Regex(@"^(?![0-9]+$)[A-Za-z0-9][A-Za-z0-9-]{0,14}$");
        static readonly Regex FqdnRx = new Regex(@"^(?=.{3,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$");
        static readonly string[] Phases = { "Preflight", "Iso", "BaseImages", "Network", "DomainControllers", "MemberServers", "Workstations", "Validate" };

        LabSettings S = new LabSettings();
        readonly List<Page> pages = new List<Page>();
        int current = -1;
        readonly string toolsDir;          // payload extracted to %TEMP% for validation / loading
        Process build;
        bool buildFinished;

        // chrome
        Label lblTitle, lblSubtitle;
        Panel content;
        FlowLayoutPanel steps;
        Button btnBack, btnNext, btnCancel, btnLoad, btnSave;

        // controls
        TextBox tInstall, tLabName, tLabRoot, tLibrary, tWin10Iso, tFqdn, tNetBios, tPw1, tPw2, tSwitch, tPrefix, tWsPrefix, tGroups, tIsoFolder, tShare, tSummary, tLog;
        TextBox tSqlInstance, tSqlDb, tSqlCollation;
        NumericUpDown nSqlPort;
        RadioButton rSqlWin, rSqlMixed;
        ComboBox cbWsOs;
        CheckedListBox clSqlSys, clSqlOwners;
        Label lblSqlState;
        RadioButton rGen, rEnter, rPrivate, rInternal, rDownload, rIsoFolder, rLocalAdminNo, rLocalAdminYes;
        NumericUpDown nDcCount, nMsCount, nWsCount, nWsOctet, nWsCpu, nWsMem, nWsDisk, nAdmins, nUsers, nPwLen, nDhcpStart, nDhcpEnd;
        DataGridView gDc, gMs;
        CheckBox cHttps, cConfigOnly;
        ListView lvPrereq, lvPhases;
        Label lblDisk, lblValidation, lblBuildStatus;
        Button bOpenOut, bOpenSummary, bOpenReport;
        string lastValidationOutput = "";
        bool lastValidationOk;

        public WizardForm(string preloadConfig)
        {
            Text = "LabBuilder Setup " + Payload.Version + " - Hyper-V TEST environment";
            Font = new Font("Segoe UI", 9F);
            AutoScaleMode = AutoScaleMode.Font;
            ClientSize = new Size(1000, 680);
            MinimumSize = new Size(900, 600);
            StartPosition = FormStartPosition.CenterScreen;
            // 1.1.1: opens maximised; the window stays freely resizable (Sizable border, maximise box) and every page
            // stretches with it (anchored grids/lists, notes wrap to the page width).
            FormBorderStyle = FormBorderStyle.Sizable;
            MaximizeBox = true;
            WindowState = FormWindowState.Maximized;
            try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

            toolsDir = Path.Combine(Path.GetTempPath(), "LabBuilderSetup-" + Process.GetCurrentProcess().Id);
            try { Payload.ExtractTo(toolsDir); }
            catch (Exception ex) { MessageBox.Show("Cannot unpack the application files: " + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error); }

            BuildChrome();
            BuildPages();
            if (!string.IsNullOrEmpty(preloadConfig)) LoadConfig(preloadConfig);
            ShowPage(0);
            FormClosing += OnClosing;
            FormClosed += (s, e) => { try { Directory.Delete(toolsDir, true); } catch { } };
        }

        // =====================================================================================
        // Chrome
        // =====================================================================================

        void BuildChrome()
        {
            // ITOM Solutions branding (www.itomsol.com; same mark and colours as the IT Portal, its ADR 0014).
            // The form does not auto-scale pixel sizes (no AutoScaleDimensions) while fonts follow the display scaling, so
            // every size here is either Px()-scaled or measured from its text - nothing wraps or clips at 100-200 %.
            var fBrand = new Font("Segoe UI Semibold", 14F);
            var fStep = new Font("Segoe UI Semibold", 9.5F);
            var fSmall = new Font("Segoe UI", 8F);
            int markSize = Px(40), gap = Px(10), padL = Px(14), padR = Px(10);
            Func<string, Font, Size> measure = (txt, fnt) => TextRenderer.MeasureText(txt, fnt, new Size(int.MaxValue, int.MaxValue), TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
            var szBrand = measure("LabBuilder", fBrand);
            var szBy = measure("by ITOM Solutions", Font);
            int brandW = markSize + gap + Math.Max(szBrand.Width, szBy.Width);
            int textW = Math.Max(brandW, Math.Max(measure("Hyper-V TEST environment", Font).Width,
                        Math.Max(measure("Better operations. Better outcomes.", fSmall).Width, measure("\u25B6 Domain controllers", fStep).Width + Px(12))));
            var left = new Panel { Dock = DockStyle.Left, Width = Math.Max(Px(200), padL + textW + padR + Px(8)), BackColor = Brand.Ink, Padding = new Padding(padL, Px(14), padR, Px(10)) };

            int brandH = Math.Max(markSize, szBrand.Height + szBy.Height + Px(2));
            var brandRow = new Panel { Dock = DockStyle.Top, Height = brandH, BackColor = Brand.Ink };
            var mark = new PictureBox { Bounds = new Rectangle(0, (brandH - markSize) / 2, markSize, markSize), SizeMode = PictureBoxSizeMode.Zoom, Image = Brand.Mark() };
            var brand = new Label { Text = "LabBuilder", ForeColor = Color.White, Font = fBrand, AutoSize = true, UseMnemonic = false, Location = new Point(markSize + gap - Px(2), (brandH - szBrand.Height - szBy.Height) / 2 - Px(2)) };
            var brandBy = new Label { Text = "by ITOM Solutions", ForeColor = Brand.Lime, AutoSize = true, Location = new Point(markSize + gap, brand.Top + szBrand.Height + Px(2)) };
            brandRow.Controls.Add(mark); brandRow.Controls.Add(brand); brandRow.Controls.Add(brandBy);
            var brand2 = new Label { Text = "Hyper-V TEST environment", ForeColor = Brand.Muted, Dock = DockStyle.Top, AutoSize = false, Height = measure("Hy", Font).Height + Px(14), TextAlign = ContentAlignment.BottomLeft };
            steps = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(0, Px(12), 0, 0) };
            steps.Resize += (s, e) => { foreach (Control c in steps.Controls) c.Width = Math.Max(Px(120), steps.ClientSize.Width - 8); };
            var foot = new TableLayoutPanel { Dock = DockStyle.Bottom, AutoSize = true, ColumnCount = 1, BackColor = Brand.Ink };
            var site = new LinkLabel { Text = "www.itomsol.com", AutoSize = true, LinkColor = Brand.Lime, ActiveLinkColor = Color.White, VisitedLinkColor = Brand.Lime, LinkBehavior = LinkBehavior.HoverUnderline, Margin = new Padding(0, 0, 0, Px(2)) };
            site.LinkClicked += (s, e) => { try { Process.Start("https://www.itomsol.com"); } catch { } };
            var tagline = new Label { Text = "Better operations. Better outcomes.", ForeColor = Brand.Muted, AutoSize = true, Font = fSmall, Margin = new Padding(0, 0, 0, Px(2)) };
            var ver = new Label { Text = "Version " + Payload.Version, ForeColor = Brand.Muted, AutoSize = true, Font = fSmall, Margin = new Padding(0) };
            foot.Controls.Add(site, 0, 0); foot.Controls.Add(tagline, 0, 1); foot.Controls.Add(ver, 0, 2);
            left.Controls.Add(steps); left.Controls.Add(foot); left.Controls.Add(brand2); left.Controls.Add(brandRow);

            var fTitle = new Font("Segoe UI Semibold", 13F);
            int titleH = measure("Wg", fTitle).Height + Px(6), subH = measure("Wg", Font).Height + Px(6);
            var header = new Panel { Dock = DockStyle.Top, Height = titleH + subH + Px(16), BackColor = Color.White, Padding = new Padding(Px(16), Px(10), Px(16), Px(6)) };
            lblSubtitle = new Label { Dock = DockStyle.Top, Height = subH, ForeColor = Color.DimGray, UseMnemonic = false };
            lblTitle = new Label { Dock = DockStyle.Top, Height = titleH, Font = fTitle, ForeColor = Brand.Ink, UseMnemonic = false };
            header.Controls.Add(lblSubtitle); header.Controls.Add(lblTitle);
            var sep = new Label { Dock = DockStyle.Top, Height = Px(3), BackColor = Brand.Lime };   // brand accent line

            var bottom = new Panel { Dock = DockStyle.Bottom, Height = 52, Padding = new Padding(12, 10, 12, 10) };
            btnCancel = new Button { Text = "Cancel", Width = 96, Height = 30, Margin = new Padding(16, 0, 0, 0) };
            btnNext = new Button { Text = "Next >", Width = 120, Height = 30, Margin = new Padding(6, 0, 0, 0) };
            btnBack = new Button { Text = "< Back", Width = 96, Height = 30, Margin = new Padding(0) };
            // Right-to-left flow: first added is right-most -> [< Back] [Next >]   [Cancel]
            var right = new FlowLayoutPanel { Dock = DockStyle.Right, FlowDirection = FlowDirection.RightToLeft, Width = 360, WrapContents = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
            right.Controls.Add(btnCancel); right.Controls.Add(btnNext); right.Controls.Add(btnBack);
            btnLoad = new Button { Text = "Load configuration...", Width = 150, Height = 30, Margin = new Padding(0, 0, 6, 0) };
            btnSave = new Button { Text = "Save configuration...", Width = 150, Height = 30, Margin = new Padding(0) };
            var leftButtons = new FlowLayoutPanel { Dock = DockStyle.Left, Width = 330, WrapContents = false, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
            // Buttons grow to fit their text at any display scaling (fixed widths wrapped "Load configuration..." at 150 %).
            foreach (var b in new[] { btnCancel, btnNext, btnBack, btnLoad, btnSave }) { b.AutoSize = true; b.AutoSizeMode = AutoSizeMode.GrowOnly; }
            leftButtons.Controls.Add(btnLoad); leftButtons.Controls.Add(btnSave);
            bottom.Controls.Add(right); bottom.Controls.Add(leftButtons);

            btnBack.Click += (s, e) => { if (current > 0) ShowPage(Neighbour(current, -1)); };
            btnNext.Click += (s, e) => Next();
            btnCancel.Click += (s, e) => Close();
            btnLoad.Click += (s, e) => { using (var d = new OpenFileDialog { Filter = "Lab configuration (*.psd1)|*.psd1" }) if (d.ShowDialog(this) == DialogResult.OK) LoadConfig(d.FileName); };
            btnSave.Click += (s, e) => SaveConfigAs();

            content = new Panel { Dock = DockStyle.Fill, Padding = new Padding(16, 12, 16, 4) };
            Controls.Add(content); Controls.Add(sep); Controls.Add(header); Controls.Add(bottom); Controls.Add(left);
            AcceptButton = null;
        }

        void ShowPage(int index)
        {
            if (index < 0 || index >= pages.Count) return;
            current = index;
            var p = pages[index];
            content.Controls.Clear();
            p.Content.Dock = DockStyle.Fill;
            content.Controls.Add(p.Content);
            lblTitle.Text = p.Title; lblSubtitle.Text = p.Subtitle;
            steps.Controls.Clear();
            for (int i = 0; i < pages.Count; i++)
            {
                if (i != index && IsHidden(i)) continue;
                steps.Controls.Add(new Label
                {
                    Text = (i < index ? "\u2713 " : (i == index ? "\u25B6 " : "   ")) + pages[i].Step,
                    ForeColor = i == index ? Brand.Lime : (i < index ? Color.White : Brand.Muted),
                    Font = i == index ? new Font("Segoe UI Semibold", 9.5F) : new Font("Segoe UI", 9.5F),
                    // created after the form was scaled, so sizes are DPI-scaled by hand
                    AutoSize = false, Width = Math.Max(Px(120), steps.ClientSize.Width - 8), Height = Px(26), UseMnemonic = false
                });
            }
            bool isBuild = p.Step == "Build";
            bool isSummary = p.Step == "Summary";
            btnBack.Enabled = index > 0 && !isBuild;
            btnLoad.Visible = btnSave.Visible = !isBuild;
            btnNext.Text = isSummary ? (cConfigOnly.Checked ? "Install" : "Install && build") : (isBuild ? "Close" : "Next >");
            btnNext.Enabled = !isBuild || buildFinished;
            if (p.Enter != null) p.Enter();
            if (isSummary) btnNext.Enabled = lastValidationOk;
        }

        void Next()
        {
            var p = pages[current];
            if (p.Step == "Build") { Close(); return; }
            if (p.Leave != null && !p.Leave()) return;
            if (p.Step == "Summary") { InstallAndBuild(); return; }
            ShowPage(Neighbour(current, +1));
        }

        void OnClosing(object sender, FormClosingEventArgs e)
        {
            if (build != null && !build.HasExited)
            {
                if (MessageBox.Show(this, "The lab build is still running. Stop it?\n\nThe build can be resumed later by running the wizard again or scripts\\Invoke-LabBuild.ps1.",
                        Text, MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) { e.Cancel = true; return; }
                PsRunner.KillTree(build);
                return;
            }
            if (!buildFinished && current < pages.Count - 1 &&
                MessageBox.Show(this, "Exit the setup wizard?", Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) e.Cancel = true;
        }

        // =====================================================================================
        // Layout helpers
        // =====================================================================================

        // ListView column widths are pixels and are not scaled by WinForms; scale them to the display DPI.
        static int Px(int logical) { using (var gr = Graphics.FromHwnd(IntPtr.Zero)) return (int)Math.Round(logical * gr.DpiX / 96f); }

        static TableLayoutPanel Grid()
        {
            var t = new TableLayoutPanel { ColumnCount = 2, AutoScroll = true, Padding = new Padding(0, 4, 8, 4) };
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 230));
            t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            t.Resize += (s, e) => WrapNotes(t);
            return t;
        }

        // Notes (and other labels tagged "wrap") wrap at the page width, so text uses a maximised window
        // and still fits a small one. Capped for readability on very wide screens.
        static void WrapNotes(TableLayoutPanel t)
        {
            int w = Math.Max(Px(360), Math.Min(Px(1100), t.ClientSize.Width - Px(30)));
            foreach (Control c in t.Controls)
            {
                if (!"wrap".Equals(c.Tag)) continue;
                int indent = t.GetColumn(c) == 1 ? 230 : 0;
                c.MaximumSize = new Size(Math.Max(Px(240), w - indent), 0);
            }
        }

        static void Row(TableLayoutPanel t, string label, Control c)
        {
            t.RowCount++;
            t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            var l = new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left | AnchorStyles.Top, Margin = new Padding(3, 7, 3, 3) };
            t.Controls.Add(l, 0, t.RowCount - 1);
            c.Margin = new Padding(3, 3, 3, 3);
            t.Controls.Add(c, 1, t.RowCount - 1);
        }

        static void Full(TableLayoutPanel t, Control c)
        {
            t.RowCount++;
            t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            c.Margin = new Padding(3, 3, 3, 3);
            t.Controls.Add(c, 0, t.RowCount - 1);
            t.SetColumnSpan(c, 2);
        }

        static Label Note(TableLayoutPanel t, string text)
        {
            t.RowCount++;
            t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            var l = new Label { Text = text, AutoSize = true, MaximumSize = new Size(720, 0), ForeColor = Color.DimGray, Margin = new Padding(3, 4, 3, 10), Tag = "wrap" };
            t.Controls.Add(l, 0, t.RowCount - 1);
            t.SetColumnSpan(l, 2);
            return l;
        }

        static Label Heading(TableLayoutPanel t, string text)
        {
            t.RowCount++;
            t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            var l = new Label { Text = text, AutoSize = true, Font = new Font("Segoe UI Semibold", 10F), Margin = new Padding(3, 12, 3, 4) };
            t.Controls.Add(l, 0, t.RowCount - 1);
            t.SetColumnSpan(l, 2);
            return l;
        }

        static TextBox Text_(string value, int width) { return new TextBox { Text = value, Width = width }; }
        static NumericUpDown Num(int min, int max, int value) { return new NumericUpDown { Minimum = min, Maximum = max, Value = Math.Max(min, Math.Min(max, value)), Width = 80 }; }

        Control WithBrowse(TextBox box, bool folder)
        {
            var p = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0) };
            var b = new Button { Text = "Browse...", AutoSize = true };
            b.Click += (s, e) =>
            {
                using (var d = new FolderBrowserDialog { SelectedPath = box.Text })
                    if (d.ShowDialog(this) == DialogResult.OK) box.Text = d.SelectedPath;
            };
            p.Controls.Add(box); p.Controls.Add(b);
            return p;
        }

        static FlowLayoutPanel Flow(params Control[] cs)
        {
            var p = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0) };
            foreach (var c in cs) p.Controls.Add(c);
            return p;
        }

        bool Fail(string message, Control focus)
        {
            MessageBox.Show(this, message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            if (focus != null) focus.Focus();
            return false;
        }

        // =====================================================================================
        // Pages
        // =====================================================================================

        void BuildPages()
        {
            pages.Add(PageWelcome());
            pages.Add(PageInstall());
            pages.Add(PageDomain());
            pages.Add(PageNetwork());
            pages.Add(PageDomainControllers());
            pages.Add(PageMemberServers());
            pages.Add(PageAccounts());
            pages.Add(PageSql());
            pages.Add(PageWorkstations());
            pages.Add(PageIso());
            pages.Add(PageSummary());
            pages.Add(PageBuild());
        }

        Page PageWelcome()
        {
            var t = Grid();
            Note(t, "This wizard installs LabBuilder on this Hyper-V host and builds an isolated test lab: an Active Directory forest " +
                    "with domain controllers, a certificate authority, member servers with the roles you choose, and domain-joined " +
                    "workstations, optionally SQL Server 2025 Express. You choose the operating system of every server (Windows Server " +
                    "2025, 2022 or 2019) and of the workstations (Windows 11 Enterprise LTSC, or Windows 10 Enterprise from your own ISO). " +
                    "Evaluation ISOs (and the SQL Server Express media) are downloaded from Microsoft, verified and kept in an image " +
                    "library that every later lab reuses.");
            Heading(t, "Prerequisite check");
            lvPrereq = new ListView { View = View.Details, FullRowSelect = true, HeaderStyle = ColumnHeaderStyle.Nonclickable, Width = 720, Height = 260, Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top };
            // Detail column takes the remaining width so the list fits the page at any scaling.
            lvPrereq.Resize += (s, e) => { if (lvPrereq.Columns.Count == 3) lvPrereq.Columns[2].Width = Math.Max(Px(120), lvPrereq.ClientSize.Width - lvPrereq.Columns[0].Width - lvPrereq.Columns[1].Width - 4); };
            lvPrereq.Columns.Add("Check", Px(330)); lvPrereq.Columns.Add("Result", Px(70)); lvPrereq.Columns.Add("Detail", Px(290));
            t.RowCount++; t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            t.Controls.Add(lvPrereq, 0, t.RowCount - 1); t.SetColumnSpan(lvPrereq, 2);
            Note(t, "Use 'Load configuration...' to repeat a lab you saved before.");
            return new Page
            {
                Step = "Welcome", Title = "Welcome", Subtitle = "Hyper-V TEST environment builder - prerequisites", Content = t,
                Enter = RunPrereqs,
                Leave = () =>
                {
                    bool fatal = lvPrereq.Items.Cast<ListViewItem>().Any(i => i.SubItems[1].Text == "FAIL");
                    return !fatal || Fail("Fix the failed prerequisites first (see the list).", null);
                }
            };
        }

        void RunPrereqs()
        {
            lvPrereq.Items.Clear();
            Action<string, bool, bool, string> add = (check, ok, fatal, detail) =>
            {
                var it = new ListViewItem(new[] { check, ok ? "OK" : (fatal ? "FAIL" : "WARN"), detail });
                it.ForeColor = ok ? Color.DarkGreen : (fatal ? Color.Firebrick : Color.DarkOrange);
                lvPrereq.Items.Add(it);
            };
            bool admin = new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator);
            add("Running as administrator", admin, true, WindowsIdentity.GetCurrent().Name);

            int build = 0; string caption = "";
            using (var k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
            {
                if (k != null) { int.TryParse(Convert.ToString(k.GetValue("CurrentBuildNumber")), out build); caption = Convert.ToString(k.GetValue("ProductName")); }
            }
            add("Windows build >= 17763 (Server 2019 / Windows 10 1809)", build >= 17763, true, caption + " build " + build);

            string vmms = "not installed"; bool vmmsOk = false;
            try { using (var sc = new ServiceController("vmms")) { vmms = sc.Status.ToString(); vmmsOk = sc.Status == ServiceControllerStatus.Running; } } catch { }
            add("Hyper-V Virtual Machine Management service", vmmsOk, true, vmms);

            bool hvModule = Directory.Exists(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\Modules\Hyper-V"));
            add("Hyper-V PowerShell module", hvModule, true, hvModule ? "installed" : "install 'Hyper-V Module for Windows PowerShell'");
            add("Windows PowerShell 5.1", File.Exists(PsRunner.PowerShellExe), true, PsRunner.PowerShellExe);

            bool payload = File.Exists(Path.Combine(toolsDir, @"scripts\Invoke-LabBuild.ps1"));
            add("Application files", payload, true, payload ? Payload.Version : "payload missing");

            var ci = new Microsoft.VisualBasic.Devices.ComputerInfo();
            double freeGb = ci.AvailablePhysicalMemory / 1073741824.0;
            add("Free memory (default lab needs ~12 GB)", freeGb >= 12, false, freeGb.ToString("N1") + " GB free of " + (ci.TotalPhysicalMemory / 1073741824.0).ToString("N0") + " GB");
            bool curl = File.Exists(Path.Combine(Environment.SystemDirectory, "curl.exe"));
            add("curl.exe (resumable ISO download)", curl, false, curl ? "found" : "falls back to Invoke-WebRequest");
        }

        Page PageInstall()
        {
            var t = Grid();
            tInstall = Text_(S.InstallDir, 420);
            Row(t, "Install LabBuilder to", WithBrowse(tInstall, true));
            Note(t, "Scripts, configuration and the lab output (credentials, logs, reports) are kept here.");
            tLabName = Text_(S.LabName, 160);
            Row(t, "Lab name", tLabName);
            Note(t, "1-15 letters, digits or '-'. Hyper-V VM names are <LabName>-<ComputerName>.");
            tLabRoot = Text_(S.LabRoot, 420);
            Row(t, "Lab folder on this host", WithBrowse(tLabRoot, true));
            Note(t, "This lab's VM disks, logs, reports and lab.json.");
            tLibrary = Text_(S.LibraryRoot, 420);
            Row(t, "Image library folder", WithBrowse(tLibrary, true));
            Note(t, "Shared by ALL labs on this host: the ISOs and one base image per operating system are downloaded and " +
                    "built once and reused by every later lab. Media of labs built with LabBuilder 1.0/1.1 is moved here automatically.");
            lblDisk = Note(t, "");
            string lastDefaultLib = LabSettings.DefaultLibraryFor(S.LabRoot);
            tLabRoot.TextChanged += (s, e) =>
            {
                // keep the library on the lab drive while the tester has not chosen another folder
                if (tLibrary.Text == lastDefaultLib && Regex.IsMatch(tLabRoot.Text, @"^[A-Za-z]:"))
                {
                    lastDefaultLib = LabSettings.DefaultLibraryFor(tLabRoot.Text);
                    tLibrary.Text = lastDefaultLib;
                }
                UpdateDiskNote();
            };
            tLibrary.TextChanged += (s, e) => UpdateDiskNote();
            return new Page
            {
                Step = "Install & lab", Title = "Installation and lab folder", Subtitle = "Where LabBuilder and the virtual machines are stored", Content = t,
                Enter = UpdateDiskNote,
                Leave = () =>
                {
                    if (!Regex.IsMatch(tInstall.Text, @"^[A-Za-z]:\\")) return Fail("Install folder must be a local absolute path.", tInstall);
                    if (!Regex.IsMatch(tLabName.Text, @"^[A-Za-z0-9][A-Za-z0-9-]{0,14}$")) return Fail("Lab name must be 1-15 letters, digits or '-'.", tLabName);
                    if (!Regex.IsMatch(tLabRoot.Text, @"^[A-Za-z]:\\")) return Fail("Lab folder must be an absolute path on a local drive, e.g. D:\\HyperVLab.", tLabRoot);
                    if (!Directory.Exists(Path.GetPathRoot(tLabRoot.Text))) return Fail("Drive " + Path.GetPathRoot(tLabRoot.Text) + " does not exist.", tLabRoot);
                    if (!Regex.IsMatch(tLibrary.Text, @"^[A-Za-z]:\\")) return Fail("Image library folder must be an absolute path on a local drive, e.g. D:\\LabBuilder-Library.", tLibrary);
                    if (!Directory.Exists(Path.GetPathRoot(tLibrary.Text))) return Fail("Drive " + Path.GetPathRoot(tLibrary.Text) + " does not exist.", tLibrary);
                    var lab = tLabRoot.Text.TrimEnd('\\') + "\\"; var lib = tLibrary.Text.TrimEnd('\\') + "\\";
                    if (lib.StartsWith(lab, StringComparison.OrdinalIgnoreCase)) return Fail("The image library is shared by all labs - choose a folder outside the lab folder.", tLibrary);
                    S.InstallDir = tInstall.Text.TrimEnd('\\'); S.LabName = tLabName.Text; S.LabRoot = tLabRoot.Text.TrimEnd('\\');
                    S.LibraryRoot = tLibrary.Text.TrimEnd('\\');
                    return true;
                }
            };
        }

        void UpdateDiskNote()
        {
            try
            {
                var d = new DriveInfo(Path.GetPathRoot(tLabRoot.Text));
                var l = new DriveInfo(Path.GetPathRoot(tLibrary.Text));
                string libPart = d.Name.Equals(l.Name, StringComparison.OrdinalIgnoreCase) ? "" :
                    string.Format(" Free space on {0} (image library): {1:N0} GB.", l.Name, l.AvailableFreeSpace / 1073741824.0);
                lblDisk.Text = string.Format("Free space on {0}: {1:N0} GB.{2} Needed: ~20 GB in the library per operating system not yet there " +
                    "(ISO + base image), plus the VM disks (dynamic - they start at ~15 GB each and grow up to the size you choose).",
                    d.Name, d.AvailableFreeSpace / 1073741824.0, libPart);
            }
            catch { lblDisk.Text = "Enter a path on a local drive."; }
        }

        Page PageDomain()
        {
            var t = Grid();
            tFqdn = Text_(S.Fqdn, 260);
            Row(t, "Forest root domain (FQDN)", tFqdn);
            Note(t, "A new forest, e.g. lab.test. Use a name that is not used on your network; .local is not allowed.");
            tNetBios = Text_(S.NetBios, 160);
            Row(t, "NetBIOS domain name", tNetBios);
            tFqdn.Leave += (s, e) =>
            {
                if (tNetBios.Text.Length == 0 && tFqdn.Text.Contains("."))
                {
                    var first = tFqdn.Text.Split('.')[0].ToUpperInvariant();
                    tNetBios.Text = first.Length > 15 ? first.Substring(0, 15) : first;
                }
            };
            Heading(t, "Lab administrator password");
            Note(t, "Used for the built-in Administrator of every VM, the domain Administrator and DSRM.");
            rGen = new RadioButton { Text = "Generate a strong random password (saved encrypted for you on this host)", AutoSize = true, Checked = S.GeneratePassword };
            rEnter = new RadioButton { Text = "Enter a password", AutoSize = true, Checked = !S.GeneratePassword };
            Full(t, rGen); Full(t, rEnter);
            tPw1 = new TextBox { Width = 260, UseSystemPasswordChar = true };
            tPw2 = new TextBox { Width = 260, UseSystemPasswordChar = true };
            Row(t, "Password", tPw1); Row(t, "Confirm password", tPw2);
            EventHandler sync = (s, e) => { tPw1.Enabled = tPw2.Enabled = rEnter.Checked; };
            rGen.CheckedChanged += sync; rEnter.CheckedChanged += sync; sync(null, null);
            return new Page
            {
                Step = "Domain", Title = "Active Directory domain", Subtitle = "New forest and lab administrator", Content = t,
                Leave = () =>
                {
                    string fqdn = tFqdn.Text.Trim().TrimEnd('.');
                    if (!FqdnRx.IsMatch(fqdn)) return Fail("Enter a valid FQDN with at least two labels, e.g. lab.test.", tFqdn);
                    if (fqdn.EndsWith(".local", StringComparison.OrdinalIgnoreCase)) return Fail(".local domains are not allowed; use e.g. lab.test.", tFqdn);
                    if (!NameRx.IsMatch(tNetBios.Text.Trim())) return Fail("NetBIOS name: 1-15 letters, digits or '-', not all digits.", tNetBios);
                    if (rEnter.Checked)
                    {
                        if (tPw1.Text != tPw2.Text) return Fail("The passwords do not match.", tPw2);
                        if (!PasswordOk(tPw1.Text)) return Fail("Password needs at least 8 characters and 3 of: upper case, lower case, digit, symbol.", tPw1);
                    }
                    S.Fqdn = fqdn.ToLowerInvariant(); S.NetBios = tNetBios.Text.Trim().ToUpperInvariant();
                    S.GeneratePassword = rGen.Checked; S.AdminPassword = rEnter.Checked ? tPw1.Text : "";
                    return true;
                }
            };
        }

        static bool PasswordOk(string p)
        {
            if (p == null || p.Length < 8) return false;
            int c = 0;
            if (p.Any(char.IsUpper)) c++;
            if (p.Any(char.IsLower)) c++;
            if (p.Any(char.IsDigit)) c++;
            if (p.Any(ch => !char.IsLetterOrDigit(ch))) c++;
            return c >= 3;
        }

        Page PageNetwork()
        {
            var t = Grid();
            rPrivate = new RadioButton { Text = "Isolated (Private switch) - VMs reach only each other; no host, LAN or internet access (recommended)", AutoSize = true, Checked = S.SwitchType == "Private" };
            rInternal = new RadioButton { Text = "Host-reachable (Internal switch) - this host gets an adapter on the lab network; still no LAN/internet", AutoSize = true, Checked = S.SwitchType == "Internal" };
            Heading(t, "Network isolation");
            Full(t, rPrivate); Full(t, rInternal);
            Note(t, "With Internal, give the host's 'vEthernet (<switch>)' adapter an address in the lab subnet to reach the VMs. The build itself always uses PowerShell Direct and works with both.");
            tSwitch = Text_(S.SwitchName, 200);
            Row(t, "Virtual switch name", tSwitch);
            tPrefix = Text_(S.Prefix, 120);
            Row(t, "Lab subnet (/24, first three octets)", tPrefix);
            Note(t, "Servers and workstations get static addresses <subnet>.<host octet>; DNS points to the domain controllers.");
            return new Page
            {
                Step = "Network", Title = "Network", Subtitle = "Isolation and addressing of the lab", Content = t,
                Leave = () =>
                {
                    if (!Regex.IsMatch(tSwitch.Text, @"^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$")) return Fail("Switch name: letters, digits, space, _ or -.", tSwitch);
                    if (!Regex.IsMatch(tPrefix.Text, @"^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){2}$")) return Fail("Subnet must be three octets, e.g. 10.10.10.", tPrefix);
                    S.SwitchType = rPrivate.Checked ? "Private" : "Internal"; S.SwitchName = tSwitch.Text; S.Prefix = tPrefix.Text;
                    return true;
                }
            };
        }

        // Role columns of a grid (the DC grid has no SQL column), in grid order.
        static IEnumerable<string> GridRoles(DataGridView g)
        {
            return g.Columns.Cast<DataGridViewColumn>().Where(c => c is DataGridViewCheckBoxColumn).Select(c => c.Name).ToList();
        }

        DataGridView ServerGrid(string[] roles)
        {
            var g = new DataGridView
            {
                Width = 750, Height = 220, AllowUserToAddRows = false, AllowUserToDeleteRows = false, RowHeadersVisible = false,
                AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.None, SelectionMode = DataGridViewSelectionMode.CellSelect,
                BackgroundColor = SystemColors.Window, EditMode = DataGridViewEditMode.EditOnEnter, Font = new Font("Segoe UI", 9F),
                // Widths follow the header/cell text, so they are right at any Windows display scaling (fixed pixel
                // widths are not scaled by WinForms and cut the headers at 125-200 %). The grid stretches with the page.
                Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top,
                ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.AutoSize,
                ScrollBars = ScrollBars.Both
            };
            g.ColumnHeadersDefaultCellStyle.WrapMode = DataGridViewTriState.False;
            int pad = TextRenderer.MeasureText("MM", g.Font).Width;   // DPI-aware spacing
            Action<DataGridViewColumn> fit = c => { c.AutoSizeMode = DataGridViewAutoSizeColumnMode.AllCells; c.MinimumWidth = pad; };
            var cols = new List<DataGridViewColumn>
            {
                new DataGridViewTextBoxColumn { Name = "Name", HeaderText = "Computer name" },
                OsColumn(),
                new DataGridViewTextBoxColumn { Name = "Octet", HeaderText = "IP .x" },
                new DataGridViewTextBoxColumn { Name = "Cpu", HeaderText = "vCPU" },
                new DataGridViewTextBoxColumn { Name = "Mem", HeaderText = "RAM GB" },
                new DataGridViewTextBoxColumn { Name = "Disk", HeaderText = "Disk GB" }
            };
            foreach (var r in roles) cols.Add(new DataGridViewCheckBoxColumn { Name = r, HeaderText = RoleCatalog.Header(r) });
            foreach (var c in cols)
            {
                fit(c); c.SortMode = DataGridViewColumnSortMode.NotSortable;
                c.MinimumWidth = Math.Max(c.MinimumWidth, TextRenderer.MeasureText(c.HeaderText, g.Font).Width + pad / 2);   // header never cut
                g.Columns.Add(c);
            }
            g.Columns["Name"].MinimumWidth = Math.Max(g.Columns["Name"].MinimumWidth, TextRenderer.MeasureText("WWWWWWWWWWW", g.Font).Width);   // room to type a 15-char name
            g.Columns["OS"].MinimumWidth = TextRenderer.MeasureText(OsCatalog.Display("Server2025"), g.Font).Width + pad * 2;   // text + drop-down arrow
            g.DataError += (s, e) => { e.ThrowException = false; };   // a value not in the list (old config) must not crash the grid
            g.Columns.Add(new DataGridViewTextBoxColumn
            {
                Name = "Features", HeaderText = "Extra Windows features (comma separated)", SortMode = DataGridViewColumnSortMode.NotSortable,
                MinimumWidth = TextRenderer.MeasureText("Extra features", g.Font).Width + pad,
                AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill
            });
            g.CurrentCellDirtyStateChanged += (s, e) => { if (g.IsCurrentCellDirty && g.CurrentCell is DataGridViewCheckBoxCell) g.CommitEdit(DataGridViewDataErrorContexts.Commit); };
            return g;
        }

        // Operating system per server (ADR 0013): Windows Server 2025 / 2022 / 2019 evaluation.
        static DataGridViewComboBoxColumn OsColumn()
        {
            var c = new DataGridViewComboBoxColumn { Name = "OS", HeaderText = "Operating system", FlatStyle = FlatStyle.Flat, DisplayStyle = DataGridViewComboBoxDisplayStyle.ComboBox };
            foreach (var k in OsCatalog.ServerKeys) c.Items.Add(OsCatalog.Display(k));
            return c;
        }

        static void FillGrid(DataGridView g, List<ServerSpec> list)
        {
            g.Rows.Clear();
            foreach (var s in list) AddGridRow(g, s);
        }

        static void AddGridRow(DataGridView g, ServerSpec s)
        {
            var os = OsCatalog.ServerKeys.Contains(s.Image) ? s.Image : OsCatalog.DefaultServer;
            var values = new List<object> { s.Name, OsCatalog.Display(os), s.HostOctet, s.Cpu, s.MemoryGB, s.DiskGB };
            foreach (var r in GridRoles(g)) values.Add(s.Roles.Contains(r));
            values.Add(string.Join(", ", s.Features));
            g.Rows.Add(values.ToArray());
        }

        static void SyncRows(DataGridView g, int count, string namePrefix, int firstOctet, string defaultRole)
        {
            while (g.Rows.Count > count) g.Rows.RemoveAt(g.Rows.Count - 1);
            while (g.Rows.Count < count)
            {
                int n = g.Rows.Count + 1;
                var s = new ServerSpec(namePrefix + n.ToString("D2"), firstOctet + n - 1, 2, 4, 80);
                if (n == 1 && defaultRole != null) s.Roles.Add(defaultRole);
                AddGridRow(g, s);
            }
        }

        bool ReadGrid(DataGridView g, string what, out List<ServerSpec> list)
        {
            g.EndEdit();
            list = new List<ServerSpec>();
            foreach (DataGridViewRow row in g.Rows)
            {
                string name = Convert.ToString(row.Cells["Name"].Value).Trim();
                int octet, cpu, mem, disk;
                if (!NameRx.IsMatch(name)) return Fail(what + ": computer name '" + name + "' must be 1-15 letters, digits or '-'.", g);
                if (!int.TryParse(Convert.ToString(row.Cells["Octet"].Value), out octet) || octet < 1 || octet > 254) return Fail(what + " " + name + ": IP host octet must be 1-254.", g);
                if (!int.TryParse(Convert.ToString(row.Cells["Cpu"].Value), out cpu) || cpu < 1 || cpu > 64) return Fail(what + " " + name + ": vCPU must be 1-64.", g);
                if (!int.TryParse(Convert.ToString(row.Cells["Mem"].Value), out mem) || mem < 2 || mem > 512) return Fail(what + " " + name + ": RAM must be 2-512 GB.", g);
                if (!int.TryParse(Convert.ToString(row.Cells["Disk"].Value), out disk) || disk < 40 || disk > 2048) return Fail(what + " " + name + ": disk must be 40-2048 GB (dynamic).", g);
                var s = new ServerSpec(name.ToUpperInvariant(), octet, cpu, mem, disk);
                s.Image = OsCatalog.KeyOf(Convert.ToString(row.Cells["OS"].Value));
                if (!OsCatalog.ServerKeys.Contains(s.Image)) return Fail(what + " " + name + ": choose the operating system.", g);
                foreach (var r in GridRoles(g)) if (Convert.ToBoolean(row.Cells[r].Value ?? false)) s.Roles.Add(r);
                foreach (var f in Convert.ToString(row.Cells["Features"].Value).Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    if (!Regex.IsMatch(f, "^[A-Za-z0-9-]+$")) return Fail(what + " " + name + ": '" + f + "' is not a Windows feature name.", g);
                    s.Features.Add(f);
                }
                list.Add(s);
            }
            return true;
        }

        Page PageDomainControllers()
        {
            var t = Grid();
            nDcCount = Num(1, 5, S.DomainControllers.Count);
            Row(t, "Number of domain controllers", nDcCount);
            Note(t, "DC 1 creates the forest (AD DS + DNS); the others join it as additional DCs with DNS and Global Catalog. " +
                    "Each DC can run Windows Server 2025, 2022 or 2019 (functional level 2016 works with all of them). " +
                    "Tick the extra roles each DC should get. ADCS = Enterprise Root CA (one per lab). Disks are always dynamic.");
            gDc = ServerGrid(RoleCatalog.DomainController);
            t.RowCount++; t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            t.Controls.Add(gDc, 0, t.RowCount - 1); t.SetColumnSpan(gDc, 2);
            nDcCount.ValueChanged += (s, e) => SyncRows(gDc, (int)nDcCount.Value, "DC", 10, null);
            return new Page
            {
                Step = "Domain controllers", Title = "Domain controllers", Subtitle = "How many, their operating system, size and roles", Content = t,
                Enter = () => { if (gDc.Rows.Count == 0) FillGrid(gDc, S.DomainControllers); },
                Leave = () =>
                {
                    List<ServerSpec> list;
                    if (!ReadGrid(gDc, "Domain controller", out list)) return false;
                    S.DomainControllers = list;
                    return true;
                }
            };
        }

        Page PageMemberServers()
        {
            var t = Grid();
            nMsCount = Num(0, 10, S.MemberServers.Count);
            Row(t, "Number of member servers", nMsCount);
            Note(t, "Domain-joined servers in OU=Servers; choose each server's operating system. Tick the roles for each server; add any other Windows " +
                    "feature names (e.g. RSAT-AD-Tools, Telnet-Client) in the last column. SQL = SQL Server 2025 Express, " +
                    "installed unattended with the options on the 'SQL Server' page.");
            gMs = ServerGrid(RoleCatalog.All);
            t.RowCount++; t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            t.Controls.Add(gMs, 0, t.RowCount - 1); t.SetColumnSpan(gMs, 2);
            nMsCount.ValueChanged += (s, e) => SyncRows(gMs, (int)nMsCount.Value, "SRV", 20, null);
            Heading(t, "Role settings");
            cHttps = new CheckBox { Text = "IIS: HTTPS with a certificate from the lab CA (needs an ADCS server)", AutoSize = true, Checked = S.IisHttps };
            Row(t, "IIS", cHttps);
            nDhcpStart = Num(1, 254, S.DhcpStart); nDhcpEnd = Num(1, 254, S.DhcpEnd);
            Row(t, "DHCP scope (host octets)", Flow(nDhcpStart, new Label { Text = " to ", AutoSize = true, Margin = new Padding(3, 7, 3, 3) }, nDhcpEnd));
            tShare = Text_(S.ShareName, 160);
            Row(t, "File Server share name", tShare);
            return new Page
            {
                Step = "Member servers", Title = "Member servers and roles", Subtitle = "Which servers, their operating system and the roles on each", Content = t,
                Enter = () => { if (gMs.Rows.Count == 0 && S.MemberServers.Count > 0) FillGrid(gMs, S.MemberServers); },
                Leave = () =>
                {
                    List<ServerSpec> list;
                    if (!ReadGrid(gMs, "Member server", out list)) return false;
                    var all = S.DomainControllers.Concat(list).ToList();
                    var dupName = all.GroupBy(x => x.Name).FirstOrDefault(x => x.Count() > 1);
                    if (dupName != null) return Fail("Computer name " + dupName.Key + " is used twice.", gMs);
                    var dupIp = all.GroupBy(x => x.HostOctet).FirstOrDefault(x => x.Count() > 1);
                    if (dupIp != null) return Fail("IP " + S.Prefix + "." + dupIp.Key + " is used twice.", gMs);
                    if (all.Count(x => x.Roles.Contains("ADCS")) > 1) return Fail("ADCS (Enterprise Root CA) can be on one server only.", gMs);
                    if (all.Count(x => x.Roles.Contains("DHCP")) > 1) return Fail("DHCP can be on one server only.", gMs);
                    if (cHttps.Checked && all.Any(x => x.Roles.Contains("IIS")) && !all.Any(x => x.Roles.Contains("ADCS")))
                        return Fail("IIS HTTPS needs a certificate authority: tick ADCS on one server, or untick HTTPS.", cHttps);
                    if (nDhcpStart.Value > nDhcpEnd.Value) return Fail("DHCP scope start must be <= end.", nDhcpStart);
                    if (!Regex.IsMatch(tShare.Text, "^[A-Za-z0-9_-]{1,80}$")) return Fail("Share name: letters, digits, _ or -.", tShare);
                    S.MemberServers = list; S.IisHttps = cHttps.Checked;
                    S.DhcpStart = (int)nDhcpStart.Value; S.DhcpEnd = (int)nDhcpEnd.Value; S.ShareName = tShare.Text;
                    return true;
                }
            };
        }

        Page PageAccounts()
        {
            var t = Grid();
            nAdmins = Num(0, 10, S.DomainAdminCount);
            Row(t, "Dedicated domain admin accounts", nAdmins);
            Note(t, "Random names adm.<first>.<last> in OU=Admins, members of Domain Admins.");
            nUsers = Num(0, 100, S.TestUserCount);
            Row(t, "Domain test users", nUsers);
            Note(t, "Random names <first>.<last> in OU=Users; every test user is in the first group below, others at random.");
            nPwLen = Num(12, 64, S.PasswordLength);
            Row(t, "Generated password length", nPwLen);
            Heading(t, "Test users on the workstations");
            rLocalAdminNo = new RadioButton { Text = "Standard users (recommended)", AutoSize = true, Checked = !S.TestUsersLocalAdmin };
            rLocalAdminYes = new RadioButton { Text = "Local administrators (the first group is added to Administrators on every workstation)", AutoSize = true, Checked = S.TestUsersLocalAdmin };
            Full(t, rLocalAdminNo); Full(t, rLocalAdminYes);
            Heading(t, "Security groups (one per line: Name;Description)");
            tGroups = new TextBox { Multiline = true, Width = 520, Height = 120, ScrollBars = ScrollBars.Vertical };
            t.RowCount++; t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            t.Controls.Add(tGroups, 0, t.RowCount - 1); t.SetColumnSpan(tGroups, 2);
            Note(t, "Accounts and passwords are saved to output\\<LabName>\\lab-accounts.csv in the install folder (readable only by you).");
            return new Page
            {
                Step = "Accounts", Title = "Accounts and groups", Subtitle = "Domain admins, test users and security groups", Content = t,
                Enter = () => { tGroups.Text = string.Join(Environment.NewLine, S.Groups.Select(g => g.Name + ";" + g.Description)); },
                Leave = () =>
                {
                    var groups = new List<GroupSpec>();
                    foreach (var line in tGroups.Lines.Select(l => l.Trim()).Where(l => l.Length > 0))
                    {
                        var parts = line.Split(new[] { ';' }, 2);
                        string name = parts[0].Trim();
                        if (!Regex.IsMatch(name, @"^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$")) return Fail("Group name '" + name + "' is not valid.", tGroups);
                        if (groups.Any(g => g.Name.Equals(name, StringComparison.OrdinalIgnoreCase))) return Fail("Group '" + name + "' is listed twice.", tGroups);
                        groups.Add(new GroupSpec(name, parts.Length > 1 ? parts[1].Trim().Replace("'", "") : ""));
                    }
                    if (groups.Count == 0) return Fail("Add at least one security group (test users join the first one).", tGroups);
                    S.Groups = groups; S.DomainAdminCount = (int)nAdmins.Value; S.TestUserCount = (int)nUsers.Value;
                    S.PasswordLength = (int)nPwLen.Value; S.TestUsersLocalAdmin = rLocalAdminYes.Checked;
                    return true;
                }
            };
        }

        static void FillChecks(CheckedListBox box, IEnumerable<GroupSpec> groups, List<string> selected)
        {
            box.Items.Clear();
            foreach (var g in groups) box.Items.Add(g.Name, selected.Any(x => x.Equals(g.Name, StringComparison.OrdinalIgnoreCase)));
        }

        // Role SQL options (FR-20, ADR 0012). Placed after Accounts so the lab groups are known.
        Page PageSql()
        {
            var t = Grid();
            lblSqlState = new Label { Tag = "wrap", AutoSize = true, MaximumSize = new Size(Px(720), 0), Margin = new Padding(3, 3, 3, 6), UseMnemonic = false, Font = new Font("Segoe UI Semibold", 9F) };
            Full(t, lblSqlState);
            Heading(t, "Product");
            Row(t, "Edition", new Label { Text = "SQL Server 2025 Express (database engine) - downloaded from Microsoft, signature checked", AutoSize = true, Margin = new Padding(3, 7, 3, 3) });
            Heading(t, "Instance and network");
            tSqlInstance = Text_(S.SqlInstance, 180);
            Row(t, "Instance name", tSqlInstance);
            Note(t, "SQLEXPRESS (default) = named instance <server>\\SQLEXPRESS with SQL Browser; MSSQLSERVER = default instance <server>.");
            nSqlPort = Num(1024, 65535, S.SqlPort);
            Row(t, "Static TCP port", nSqlPort);
            Note(t, "TCP/IP is enabled on this fixed port and the Windows firewall is opened for it (and UDP 1434 for a named instance).");
            Heading(t, "Authentication");
            rSqlWin = new RadioButton { Text = "Windows authentication only (recommended)", AutoSize = true, Checked = !S.SqlMixed };
            rSqlMixed = new RadioButton { Text = "Mixed mode - Windows and SQL logins; sa gets a generated password (output\\<LabName>\\lab-sql.csv)", AutoSize = true, Checked = S.SqlMixed };
            Full(t, rSqlWin); Full(t, rSqlMixed);
            Heading(t, "Permissions and test database");
            clSqlSys = new CheckedListBox { CheckOnClick = true, Width = 360, Height = 96, IntegralHeight = false };
            Row(t, "sysadmin groups (Domain Admins always)", clSqlSys);
            tSqlDb = Text_(S.SqlDatabase, 220);
            Row(t, "Test database (empty = none)", tSqlDb);
            clSqlOwners = new CheckedListBox { CheckOnClick = true, Width = 360, Height = 96, IntegralHeight = false };
            Row(t, "db_owner groups of the test database", clSqlOwners);
            tSqlCollation = Text_(S.SqlCollation, 260);
            Row(t, "Server collation (empty = default)", tSqlCollation);
            Note(t, "The test database gets a table dbo.LabCheck with one row, used by the validation. Changing the instance, authentication " +
                    "or collation after SQL Server is installed needs the server to be rebuilt.");
            return new Page
            {
                Step = "SQL Server", Title = "SQL Server Express", Subtitle = "Options for the member servers with the SQL Express role", Content = t,
                // Only shown when a member server has the SQL role ticked; otherwise the saved/default options are kept unused.
                Hidden = () => !S.MemberServers.Any(x => x.Roles.Contains("SQL")),
                Enter = () =>
                {
                    var names = S.MemberServers.Where(x => x.Roles.Contains("SQL")).Select(x => x.Name).ToList();
                    lblSqlState.Text = names.Count == 0
                        ? "No member server has the SQL Express role - these settings are kept but not used. Tick 'SQL' on the Member servers page to deploy SQL Server."
                        : "SQL Server 2025 Express will be installed unattended on: " + string.Join(", ", names);
                    lblSqlState.ForeColor = names.Count == 0 ? Color.DimGray : Color.DarkGreen;
                    FillChecks(clSqlSys, S.Groups, S.SqlSysadminGroups);
                    FillChecks(clSqlOwners, S.Groups, S.SqlDbOwnerGroups);
                },
                Leave = () =>
                {
                    string inst = tSqlInstance.Text.Trim(), db = tSqlDb.Text.Trim(), col = tSqlCollation.Text.Trim();
                    if (!Regex.IsMatch(inst, @"^[A-Za-z_][A-Za-z0-9_$]{0,15}$") || inst.Equals("DEFAULT", StringComparison.OrdinalIgnoreCase))
                        return Fail("Instance name: 1-16 letters, digits or _, starting with a letter (MSSQLSERVER = default instance).", tSqlInstance);
                    if (db.Length > 0 && (!Regex.IsMatch(db, "^[A-Za-z][A-Za-z0-9_]{0,63}$") || new[] { "master", "model", "msdb", "tempdb" }.Contains(db.ToLowerInvariant())))
                        return Fail("Test database: 1-64 letters, digits or _, starting with a letter, not a system database.", tSqlDb);
                    if (col.Length > 0 && !Regex.IsMatch(col, "^[A-Za-z0-9_]{3,128}$"))
                        return Fail("Collation: a collation name such as Latin1_General_CI_AS, or empty.", tSqlCollation);
                    S.SqlInstance = inst; S.SqlPort = (int)nSqlPort.Value; S.SqlMixed = rSqlMixed.Checked;
                    S.SqlSysadminGroups = clSqlSys.CheckedItems.Cast<object>().Select(x => x.ToString()).ToList();
                    S.SqlDbOwnerGroups = clSqlOwners.CheckedItems.Cast<object>().Select(x => x.ToString()).ToList();
                    S.SqlDatabase = db; S.SqlCollation = col;
                    return true;
                }
            };
        }

        Page PageWorkstations()
        {
            var t = Grid();
            nWsCount = Num(0, 20, S.WsCount);
            Row(t, "Number of test workstations", nWsCount);
            cbWsOs = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = Px(300) };
            foreach (var k in OsCatalog.ClientKeys) cbWsOs.Items.Add(OsCatalog.Display(k));
            cbWsOs.SelectedItem = OsCatalog.Display(OsCatalog.ClientKeys.Contains(S.WsImage) ? S.WsImage : OsCatalog.DefaultClient);
            Row(t, "Operating system", cbWsOs);
            tWin10Iso = Text_(S.Win10IsoPath, 420);
            var bIso = new Button { Text = "Browse...", AutoSize = true };
            bIso.Click += (s, e) =>
            {
                using (var d = new OpenFileDialog { Filter = "ISO image (*.iso)|*.iso", Title = "Windows 10 Enterprise ISO" })
                    if (d.ShowDialog(this) == DialogResult.OK) tWin10Iso.Text = d.FileName;
            };
            var isoRow = Flow(tWin10Iso, bIso);
            Row(t, "Windows 10 ISO file", isoRow);
            var wsOsNote = Note(t, "");
            Action syncOs = () =>
            {
                bool w10 = OsCatalog.KeyOf(Convert.ToString(cbWsOs.SelectedItem)) == OsCatalog.Supplied;
                tWin10Iso.Enabled = bIso.Enabled = w10;
                wsOsNote.Text = w10
                    ? "Microsoft no longer offers a Windows 10 evaluation download (end of support October 2025), so choose your own Windows 10 " +
                      "Enterprise ISO (e.g. Enterprise LTSC 2021) on this host. It is copied into the image library once; you are responsible for its licence."
                    : "Windows 11 Enterprise LTSC evaluation, downloaded from Microsoft.";
                wsOsNote.Text += " All workstations are domain-joined into OU=Workstations, with vTPM and Secure Boot.";
            };
            cbWsOs.SelectedIndexChanged += (s, e) => syncOs();
            syncOs();
            tWsPrefix = Text_(S.WsPrefix, 120);
            Row(t, "Computer name prefix", tWsPrefix);
            nWsOctet = Num(1, 254, S.WsFirstOctet);
            Row(t, "First IP host octet", nWsOctet);
            Heading(t, "Size of every workstation");
            nWsCpu = Num(2, 64, S.WsCpu); nWsMem = Num(4, 512, S.WsMemoryGB); nWsDisk = Num(64, 2048, S.WsDiskGB);
            Row(t, "vCPU", nWsCpu); Row(t, "RAM (GB)", nWsMem); Row(t, "Disk (GB, dynamic)", nWsDisk);
            var preview = Note(t, "");
            Action upd = () =>
            {
                int n = (int)nWsCount.Value;
                preview.Text = n == 0 ? "No workstations." : string.Format("Names {0}01..{0}{1:D2}, addresses {2}.{3}..{2}.{4}", tWsPrefix.Text, n, S.Prefix, nWsOctet.Value, nWsOctet.Value + n - 1);
            };
            nWsCount.ValueChanged += (s, e) => upd(); tWsPrefix.TextChanged += (s, e) => upd(); nWsOctet.ValueChanged += (s, e) => upd();
            return new Page
            {
                Step = "Workstations", Title = "Test workstations", Subtitle = "How many, which operating system and their generic size", Content = t,
                Enter = upd,
                Leave = () =>
                {
                    if (!Regex.IsMatch(tWsPrefix.Text, @"^[A-Za-z][A-Za-z0-9-]{0,12}$")) return Fail("Prefix: 1-13 letters, digits or '-', starting with a letter.", tWsPrefix);
                    int n = (int)nWsCount.Value, first = (int)nWsOctet.Value;
                    if (first + n - 1 > 254) return Fail("Not enough addresses: first octet + count - 1 must be <= 254.", nWsOctet);
                    var used = S.AllServers.Where(x => x.HostOctet >= first && x.HostOctet <= first + n - 1).Select(x => x.Name).ToList();
                    if (used.Count > 0) return Fail("Workstation addresses overlap server " + string.Join(", ", used) + ".", nWsOctet);
                    var wsImage = OsCatalog.KeyOf(Convert.ToString(cbWsOs.SelectedItem));
                    if (n > 0 && wsImage == OsCatalog.Supplied)
                    {
                        if (!Regex.IsMatch(tWin10Iso.Text, @"^[A-Za-z]:\\.+\.iso$", RegexOptions.IgnoreCase)) return Fail("Choose your Windows 10 Enterprise ISO file (a local .iso path).", tWin10Iso);
                        if (!File.Exists(tWin10Iso.Text)) return Fail("The Windows 10 ISO file was not found: " + tWin10Iso.Text, tWin10Iso);
                    }
                    S.WsImage = wsImage; S.Win10IsoPath = wsImage == OsCatalog.Supplied ? tWin10Iso.Text : "";
                    S.WsCount = n; S.WsPrefix = tWsPrefix.Text.ToUpperInvariant(); S.WsFirstOctet = first;
                    S.WsCpu = (int)nWsCpu.Value; S.WsMemoryGB = (int)nWsMem.Value; S.WsDiskGB = (int)nWsDisk.Value;
                    return true;
                }
            };
        }

        Page PageIso()
        {
            var t = Grid();
            rDownload = new RadioButton { Text = "Download from the Microsoft Evaluation Center", AutoSize = true, Checked = string.IsNullOrEmpty(S.IsoSource) };
            rIsoFolder = new RadioButton { Text = "Use ISOs pre-downloaded with scripts\\Get-LabIso.ps1 (folder with iso-manifest.json)", AutoSize = true, Checked = !string.IsNullOrEmpty(S.IsoSource) };
            Full(t, rDownload); Full(t, rIsoFolder);
            tIsoFolder = Text_(S.IsoSource, 420);
            Row(t, "Pre-downloaded ISO folder", WithBrowse(tIsoFolder, true));
            var needed = Note(t, "");
            Note(t, "ISOs are stored in the image library (<library>\\ISO) on this host, verified (HTTPS from Microsoft hosts only, size, " +
                    "SHA-256) and reused by every later build and lab; ISOs already in the library are not downloaded again. Downloads " +
                    "resume after an interruption. With the SQL Express role, the SQL Server media is fetched in the same step (Microsoft " +
                    "web installer, signature checked) into <library>\\ISO\\SQL; a pre-downloaded folder can hold it in a SQL subfolder " +
                    "(Get-LabIso.ps1 -IncludeSql).");
            EventHandler sync = (s, e) => { tIsoFolder.Enabled = rIsoFolder.Checked; };
            rDownload.CheckedChanged += sync; rIsoFolder.CheckedChanged += sync; sync(null, null);
            var approxGb = new Dictionary<string, string> { { "Server2025", "~8.2 GB" }, { "Server2022", "~5.0 GB" }, { "Server2019", "~5.7 GB" }, { "Win11LTSC", "~5.1 GB" } };
            return new Page
            {
                Step = "ISOs", Title = "Installation media", Subtitle = "Evaluation ISOs of the operating systems this lab uses", Content = t,
                Enter = () =>
                {
                    var lines = S.ImagesInUse.Select(k => "  - " + OsCatalog.Display(k) + (k == OsCatalog.Supplied
                        ? ": " + S.Win10IsoPath + " (copied into the library)"
                        : (approxGb.ContainsKey(k) ? " (" + approxGb[k] + ")" : "")));
                    needed.Text = "This lab needs:\n" + string.Join("\n", lines.ToArray());
                },
                Leave = () =>
                {
                    if (rIsoFolder.Checked)
                    {
                        if (!Directory.Exists(tIsoFolder.Text)) return Fail("ISO folder not found.", tIsoFolder);
                        if (!File.Exists(Path.Combine(tIsoFolder.Text, "iso-manifest.json"))) return Fail("The folder has no iso-manifest.json - download it with scripts\\Get-LabIso.ps1.", tIsoFolder);
                        S.IsoSource = tIsoFolder.Text;
                    }
                    else S.IsoSource = "";
                    return true;
                }
            };
        }

        Page PageSummary()
        {
            var panel = new Panel();
            lblValidation = new Label { Dock = DockStyle.Top, AutoSize = false, Height = 44, Padding = new Padding(4), ForeColor = Color.DimGray, UseMnemonic = false };
            cConfigOnly = new CheckBox { Dock = DockStyle.Bottom, Height = 28, Text = "Only install LabBuilder and save the configuration - do not build the lab now" };
            cConfigOnly.CheckedChanged += (s, e) => { btnNext.Text = cConfigOnly.Checked ? "Install" : "Install && build"; };
            tSummary = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Font = new Font("Consolas", 9F), BackColor = Color.White };
            panel.Controls.Add(tSummary); panel.Controls.Add(cConfigOnly); panel.Controls.Add(lblValidation);
            return new Page
            {
                Step = "Summary", Title = "Summary", Subtitle = "Check the lab before it is built", Content = panel,
                Enter = () => { tSummary.Text = SummaryText(); ValidateWithScripts(); },
                Leave = () => lastValidationOk || Fail("The configuration has errors (see the top of the page).", null)
            };
        }

        string SummaryText()
        {
            var sb = new StringBuilder();
            Func<ServerSpec, string> fmt = s => string.Format("  {0,-15} {6,-20} {1,-15} {2,2} vCPU {3,4} GB RAM {4,5} GB disk  {5}",
                s.Name, S.Prefix + "." + s.HostOctet, s.Cpu, s.MemoryGB, s.DiskGB, string.Join(", ", s.Roles.Concat(s.Features)), OsCatalog.Display(s.Image));
            sb.AppendLine("Install folder      : " + S.InstallDir);
            sb.AppendLine("Lab name / folder   : " + S.LabName + "  /  " + S.LabRoot);
            sb.AppendLine("Image library       : " + S.LibraryRoot + "  (shared by all labs)");
            sb.AppendLine("Domain              : " + S.Fqdn + "  (NetBIOS " + S.NetBios + ")");
            sb.AppendLine("Admin password      : " + (S.GeneratePassword ? "generated" : "entered by you"));
            sb.AppendLine("Network             : " + (S.SwitchType == "Private" ? "isolated (Private switch '" : "host-reachable (Internal switch '") + S.SwitchName + "'), " + S.Prefix + ".0/24");
            sb.AppendLine();
            sb.AppendLine("Domain controllers (" + S.DomainControllers.Count + "), AD DS + DNS on each:");
            foreach (var s in S.DomainControllers) sb.AppendLine(fmt(s));
            sb.AppendLine("Member servers (" + S.MemberServers.Count + "):");
            foreach (var s in S.MemberServers) sb.AppendLine(fmt(s));
            sb.AppendLine("Workstations (" + S.WsCount + "): " + (S.WsCount == 0 ? "none" :
                string.Format("{7}, {0}01..{0}{1:D2}, {2}.{3}.., {4} vCPU, {5} GB RAM, {6} GB disk each", S.WsPrefix, S.WsCount, S.Prefix, S.WsFirstOctet, S.WsCpu, S.WsMemoryGB, S.WsDiskGB, OsCatalog.Display(S.WsImage))));
            sb.AppendLine();
            sb.AppendLine("Accounts            : " + S.DomainAdminCount + " domain admin(s), " + S.TestUserCount + " test user(s); test users " +
                (S.TestUsersLocalAdmin ? "ARE" : "are not") + " local admins on workstations");
            sb.AppendLine("Groups              : " + string.Join(", ", S.Groups.Select(g => g.Name)));
            if (S.HasRole("IIS")) sb.AppendLine("IIS                 : " + (S.IisHttps ? "HTTP + HTTPS (lab CA certificate)" : "HTTP only"));
            if (S.HasRole("DHCP")) sb.AppendLine("DHCP scope          : " + S.Prefix + "." + S.DhcpStart + " - " + S.Prefix + "." + S.DhcpEnd);
            if (S.HasRole("FileServer")) sb.AppendLine("File share          : \\\\<server>\\" + S.ShareName);
            if (S.HasRole("SQL"))
            {
                sb.AppendLine("SQL Server          : 2025 Express on " + string.Join(", ", S.MemberServers.Where(x => x.Roles.Contains("SQL")).Select(x => x.Name)) +
                    ", instance " + S.SqlInstance + ", TCP " + S.SqlPort + ", " + (S.SqlMixed ? "Mixed (sa password generated)" : "Windows authentication"));
                sb.AppendLine("                      sysadmin: Domain Admins" + (S.SqlSysadminGroups.Count > 0 ? ", " + string.Join(", ", S.SqlSysadminGroups) : "") +
                    (string.IsNullOrEmpty(S.SqlDatabase) ? "; no test database" : "; database " + S.SqlDatabase + " (db_owner: " + (S.SqlDbOwnerGroups.Count > 0 ? string.Join(", ", S.SqlDbOwnerGroups) : "none") + ")") +
                    (string.IsNullOrEmpty(S.SqlCollation) ? "" : "; collation " + S.SqlCollation));
            }
            sb.AppendLine("ISOs                : " + string.Join(", ", S.ImagesInUse.Select(k => OsCatalog.Display(k)).ToArray()) + " - " +
                (string.IsNullOrEmpty(S.IsoSource) ? "from the library, else downloaded from Microsoft" : "from the library, else imported from " + S.IsoSource) +
                (S.ImagesInUse.Contains(OsCatalog.Supplied) ? "; Windows 10 from " + S.Win10IsoPath : ""));
            sb.AppendLine();
            var ci = new Microsoft.VisualBasic.Devices.ComputerInfo();
            double freeRam = ci.AvailablePhysicalMemory / 1073741824.0;
            double freeDisk = 0;
            try { freeDisk = new DriveInfo(Path.GetPathRoot(S.LabRoot)).AvailableFreeSpace / 1073741824.0; } catch { }
            sb.AppendLine(string.Format("Resources           : {0} VMs, {1} vCPU, {2} GB RAM (host free {3:N0} GB){4}", S.VmCount, S.TotalCpu, S.TotalMemoryGB, freeRam, S.TotalMemoryGB > freeRam ? "  <-- WARNING: not enough free RAM" : ""));
            double startDisk = 45 + S.VmCount * 15;
            sb.AppendLine(string.Format("Disk                : ~{0:N0} GB at start, up to {1:N0} GB if every dynamic disk fills (free {2:N0} GB){3}",
                startDisk, 45 + S.TotalDiskGB, freeDisk, startDisk > freeDisk ? "  <-- WARNING: not enough free disk" : ""));
            return sb.ToString();
        }

        string TempConfigPath { get { return Path.Combine(toolsDir, @"config\lab.config.psd1"); } }

        void ValidateWithScripts()
        {
            lastValidationOk = false;
            lblValidation.ForeColor = Color.DimGray;
            lblValidation.Text = "Checking the configuration with the LabBuilder rules ...";
            btnNext.Enabled = false;
            Refresh();
            try
            {
                File.WriteAllText(TempConfigPath, S.ToPsd1(), Encoding.ASCII);
                // -OutputRoot: also check this host for another lab with the same name, lab folder or switch (Test-LabHostConflict)
                var r = PsRunner.Run(PsRunner.FileArgs(Path.Combine(toolsDir, @"scripts\Test-LabConfigFile.ps1"), "-ConfigPath", TempConfigPath,
                    "-OutputRoot", Path.Combine(S.InstallDir, "output")), toolsDir, 120000);
                var errors = r.Lines.Where(l => l.StartsWith("ERROR:")).Select(l => l.Substring(6).Trim()).ToList();
                var locale = r.Lines.Where(l => l.StartsWith("LOCALE:")).Select(l => l.Substring(7).Trim()).ToList();
                lastValidationOutput = string.Join(Environment.NewLine, r.Lines);
                if (locale.Count > 0)
                    tSummary.AppendText(Environment.NewLine + "VM regional settings (from this host; UI language = ISO language):" + Environment.NewLine + "  " + string.Join(Environment.NewLine + "  ", locale) + Environment.NewLine);
                lastValidationOk = r.ExitCode == 0 && errors.Count == 0;
                if (lastValidationOk)
                {
                    lblValidation.ForeColor = Color.DarkGreen;
                    lblValidation.Text = "\u2713 Configuration is valid. Click '" + btnNext.Text.Replace("&&", "&") + "' to continue.";
                }
                else
                {
                    lblValidation.ForeColor = Color.Firebrick;
                    lblValidation.Text = "Fix these before continuing (use < Back):" + Environment.NewLine + "  - " +
                        string.Join(Environment.NewLine + "  - ", errors.Count > 0 ? errors : new List<string> { "validation failed: " + lastValidationOutput });
                    // height from the wrapped text at the current width and display scaling (long host-conflict messages)
                    int w = Math.Max(Px(300), lblValidation.ClientSize.Width - lblValidation.Padding.Horizontal);
                    lblValidation.Height = Math.Min(Px(320), TextRenderer.MeasureText(lblValidation.Text, lblValidation.Font, new Size(w, 0), TextFormatFlags.WordBreak).Height + Px(12));
                }
            }
            catch (Exception ex)
            {
                lblValidation.ForeColor = Color.Firebrick;
                lblValidation.Text = "Could not run the validation: " + ex.Message;
            }
            btnNext.Enabled = lastValidationOk;
        }

        Page PageBuild()
        {
            var panel = new Panel();
            lvPhases = new ListView { Dock = DockStyle.Left, Width = 300, View = View.Details, HeaderStyle = ColumnHeaderStyle.Nonclickable, FullRowSelect = true };
            lvPhases.Columns.Add("Phase", Px(140)); lvPhases.Columns.Add("Status", Px(150));
            foreach (var ph in Phases) lvPhases.Items.Add(new ListViewItem(new[] { ph, "pending" }));
            tLog = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Font = new Font("Consolas", 8.5F), BackColor = Color.FromArgb(20, 24, 30), ForeColor = Color.Gainsboro, MaxLength = 0 };
            var top = new Panel { Dock = DockStyle.Top, Height = 40 };
            lblBuildStatus = new Label { Dock = DockStyle.Fill, Font = new Font("Segoe UI Semibold", 10F), TextAlign = ContentAlignment.MiddleLeft };
            var buttons = new FlowLayoutPanel { Dock = DockStyle.Right, Width = 420, FlowDirection = FlowDirection.RightToLeft };
            bOpenReport = new Button { Text = "Validation report", AutoSize = true, Enabled = false };
            bOpenSummary = new Button { Text = "Lab summary", AutoSize = true, Enabled = false };
            bOpenOut = new Button { Text = "Open output folder", AutoSize = true, Enabled = false };
            buttons.Controls.Add(bOpenReport); buttons.Controls.Add(bOpenSummary); buttons.Controls.Add(bOpenOut);
            top.Controls.Add(lblBuildStatus); top.Controls.Add(buttons);
            var spacer = new Panel { Dock = DockStyle.Left, Width = 8 };
            panel.Controls.Add(tLog); panel.Controls.Add(spacer); panel.Controls.Add(lvPhases); panel.Controls.Add(top);
            bOpenOut.Click += (s, e) => OpenPath(OutputDir);
            bOpenSummary.Click += (s, e) => OpenPath(Path.Combine(OutputDir, "lab-summary.md"));
            bOpenReport.Click += (s, e) =>
            {
                var f = Directory.Exists(OutputDir) ? Directory.GetFiles(OutputDir, "validation-*.md").OrderByDescending(x => x).FirstOrDefault() : null;
                if (f != null) OpenPath(f);
            };
            return new Page { Step = "Build", Title = "Building the lab", Subtitle = "Live progress - the build can take one to two hours", Content = panel };
        }

        string OutputDir { get { return Path.Combine(S.InstallDir, "output", S.LabName); } }

        void OpenPath(string path)
        {
            try
            {
                if (path.EndsWith(".md")) Process.Start("notepad.exe", "\"" + path + "\"");
                else Process.Start("explorer.exe", "\"" + path + "\"");
            }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, Text); }
        }

        // =====================================================================================
        // Install & build
        // =====================================================================================

        void InstallAndBuild()
        {
            string cfgPath = Path.Combine(S.InstallDir, @"config\lab.config.psd1");
            try
            {
                Cursor = Cursors.WaitCursor;
                Payload.ExtractTo(S.InstallDir);
                if (File.Exists(cfgPath))
                {
                    string backup = cfgPath + ".bak-" + DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
                    File.Copy(cfgPath, backup, true);
                }
                File.WriteAllText(cfgPath, S.ToPsd1(), Encoding.ASCII);
            }
            catch (Exception ex)
            {
                Cursor = Cursors.Default;
                MessageBox.Show(this, "Installation failed: " + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            finally { Cursor = Cursors.Default; }

            string script = Path.Combine(S.InstallDir, @"scripts\Invoke-LabBuild.ps1");
            var args = new List<string> { "-ConfigPath", cfgPath };
            if (!string.IsNullOrEmpty(S.IsoSource)) { args.Add("-IsoSource"); args.Add(S.IsoSource); }
            if (!S.GeneratePassword) args.Add("-AdminPasswordFromStdin");
            string commandLine = PsRunner.FileArgs(script, args.ToArray());

            if (cConfigOnly.Checked)
            {
                buildFinished = true;
                MessageBox.Show(this, "LabBuilder is installed in " + S.InstallDir + " and the configuration is saved to\n" + cfgPath +
                    "\n\nBuild the lab later from an elevated PowerShell console:\n\n  cd \"" + S.InstallDir + "\"\n  .\\scripts\\Invoke-LabBuild.ps1 -ConfigPath .\\config\\lab.config.psd1" +
                    (S.GeneratePassword ? "" : " -LabAdminCredential (Get-Credential)") + "\n\nor run this wizard again and load the configuration.", Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
                Close();
                return;
            }

            ShowPage(pages.Count - 1);
            lblBuildStatus.Text = "Build running ...";
            lblBuildStatus.ForeColor = Color.SteelBlue;
            Log("LabBuilder " + Payload.Version + " installed to " + S.InstallDir);
            Log("Configuration: " + cfgPath);
            Log("Starting: powershell.exe " + commandLine);
            Log("");
            try
            {
                build = PsRunner.Start(commandLine, S.InstallDir, S.GeneratePassword ? null : S.AdminPassword, OnBuildLine, OnBuildExit);
                S.AdminPassword = "";
                tPw1.Text = tPw2.Text = "";
            }
            catch (Exception ex)
            {
                lblBuildStatus.Text = "Could not start the build: " + ex.Message;
                lblBuildStatus.ForeColor = Color.Firebrick;
                buildFinished = true; btnNext.Enabled = true;
            }
        }

        static readonly Regex PhaseStart = new Regex(@"=== Phase (\w+) on ");
        static readonly Regex PhaseDone = new Regex(@"=== Phase (\w+) completed in ([\d.,]+) min");
        static readonly Regex PhaseFail = new Regex(@"Phase (\w+) failed: ");

        void OnBuildLine(string line)
        {
            if (IsDisposed) return;
            BeginInvoke((Action)(() =>
            {
                Log(line);
                Match m;
                if ((m = PhaseStart.Match(line)).Success) SetPhase(m.Groups[1].Value, "running", Color.SteelBlue);
                else if ((m = PhaseDone.Match(line)).Success) SetPhase(m.Groups[1].Value, "done (" + m.Groups[2].Value + " min)", Color.DarkGreen);
                else if ((m = PhaseFail.Match(line)).Success) SetPhase(m.Groups[1].Value, "FAILED", Color.Firebrick);
            }));
        }

        void SetPhase(string name, string status, Color color)
        {
            foreach (ListViewItem it in lvPhases.Items)
                if (it.Text == name) { it.SubItems[1].Text = status; it.ForeColor = color; it.EnsureVisible(); }
        }

        void OnBuildExit(int code)
        {
            if (IsDisposed) return;
            BeginInvoke((Action)(() =>
            {
                buildFinished = true;
                btnNext.Enabled = true;
                bOpenOut.Enabled = bOpenSummary.Enabled = bOpenReport.Enabled = Directory.Exists(OutputDir);
                if (code == 0) { lblBuildStatus.Text = "\u2713 Lab built and validated."; lblBuildStatus.ForeColor = Color.DarkGreen; }
                else if (code == 2) { lblBuildStatus.Text = "Lab built - some validation checks failed (see the report)."; lblBuildStatus.ForeColor = Color.DarkOrange; }
                else
                {
                    lblBuildStatus.Text = "Build stopped (exit code " + code + "). Fix the cause and run the wizard again with the same settings - finished work is detected and skipped.";
                    lblBuildStatus.ForeColor = Color.Firebrick;
                }
                Log("");
                Log("Build process exited with code " + code + ".");
            }));
        }

        void Log(string line)
        {
            tLog.AppendText(line + Environment.NewLine);
        }

        // =====================================================================================
        // Load / save configuration
        // =====================================================================================

        void StoreCurrentPage()
        {
            // Pages store their values on Next; store the visible page too (ignore validation failures here).
            if (current >= 0 && pages[current].Leave != null && pages[current].Step != "Summary" && pages[current].Step != "Build") pages[current].Leave();
        }

        void SaveConfigAs()
        {
            StoreCurrentPage();
            using (var d = new SaveFileDialog { Filter = "Lab configuration (*.psd1)|*.psd1", FileName = S.LabName + ".lab.config.psd1" })
            {
                if (d.ShowDialog(this) != DialogResult.OK) return;
                // A saved file must stand alone: point BaseConfig at the installed example if present, else keep relative.
                File.WriteAllText(d.FileName, S.ToPsd1(), Encoding.ASCII);
                string dir = Path.GetDirectoryName(d.FileName);
                string example = Path.Combine(dir, "lab.config.example.psd1");
                if (!File.Exists(example)) File.Copy(Path.Combine(toolsDir, @"config\lab.config.example.psd1"), example, false);
                MessageBox.Show(this, "Saved " + d.FileName + "\n(with lab.config.example.psd1 next to it). The admin password is never saved.", Text);
            }
        }

        void LoadConfig(string path)
        {
            try
            {
                string script = "$ErrorActionPreference='Stop'; Import-Module '" + Path.Combine(toolsDir, @"src\LabBuilder\LabBuilder.psd1").Replace("'", "''") +
                                "'; Import-LabConfig -Path '" + path.Replace("'", "''") + "' | ConvertTo-Json -Depth 20 -Compress";
                var r = PsRunner.Run("-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"" + script.Replace("\"", "\\\"") + "\"", toolsDir, 60000);
                // -Compress gives one JSON line; ignore WARNING:/other lines PowerShell may print.
                string json = r.Lines.FirstOrDefault(l => l.TrimStart().StartsWith("{"));
                if (r.ExitCode != 0 || string.IsNullOrEmpty(json)) throw new InvalidOperationException(string.Join(Environment.NewLine, r.Lines));
                var data = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(json) as IDictionary<string, object>;
                if (data == null) throw new InvalidOperationException("Not a lab configuration.");
                S = LabSettings.FromConfig(data, S);
                RebindAll();
                MessageBox.Show(this, "Loaded " + path + ".\nThe admin password is not stored in configurations; choose it on the Domain page.", Text);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Could not load the configuration:\n" + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        void RebindAll()
        {
            tInstall.Text = S.InstallDir; tLabName.Text = S.LabName; tLabRoot.Text = S.LabRoot; tLibrary.Text = S.LibraryRoot;
            cbWsOs.SelectedItem = OsCatalog.Display(OsCatalog.ClientKeys.Contains(S.WsImage) ? S.WsImage : OsCatalog.DefaultClient);
            tWin10Iso.Text = S.Win10IsoPath;
            tFqdn.Text = S.Fqdn; tNetBios.Text = S.NetBios; rGen.Checked = true;
            rPrivate.Checked = S.SwitchType == "Private"; rInternal.Checked = S.SwitchType == "Internal";
            tSwitch.Text = S.SwitchName; tPrefix.Text = S.Prefix;
            nDcCount.Value = Math.Max(1, Math.Min(5, S.DomainControllers.Count)); FillGrid(gDc, S.DomainControllers);
            nMsCount.Value = Math.Min(10, S.MemberServers.Count); FillGrid(gMs, S.MemberServers);
            cHttps.Checked = S.IisHttps; nDhcpStart.Value = S.DhcpStart; nDhcpEnd.Value = S.DhcpEnd; tShare.Text = S.ShareName;
            nAdmins.Value = S.DomainAdminCount; nUsers.Value = S.TestUserCount; nPwLen.Value = Math.Max(12, Math.Min(64, S.PasswordLength));
            rLocalAdminYes.Checked = S.TestUsersLocalAdmin; rLocalAdminNo.Checked = !S.TestUsersLocalAdmin;
            tGroups.Text = string.Join(Environment.NewLine, S.Groups.Select(g => g.Name + ";" + g.Description));
            tSqlInstance.Text = S.SqlInstance; nSqlPort.Value = Math.Max(1024, Math.Min(65535, S.SqlPort));
            rSqlMixed.Checked = S.SqlMixed; rSqlWin.Checked = !S.SqlMixed; tSqlDb.Text = S.SqlDatabase; tSqlCollation.Text = S.SqlCollation;
            nWsCount.Value = Math.Min(20, S.WsCount); tWsPrefix.Text = S.WsPrefix; nWsOctet.Value = Math.Max(1, Math.Min(254, S.WsFirstOctet));
            nWsCpu.Value = Math.Max(2, Math.Min(64, S.WsCpu)); nWsMem.Value = Math.Max(4, Math.Min(512, S.WsMemoryGB)); nWsDisk.Value = Math.Max(64, Math.Min(2048, S.WsDiskGB));
            if (current >= 0) ShowPage(current);
        }
    }
}
