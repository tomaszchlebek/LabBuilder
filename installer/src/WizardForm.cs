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
        TextBox tInstall, tLabName, tLabRoot, tFqdn, tNetBios, tPw1, tPw2, tSwitch, tPrefix, tWsPrefix, tGroups, tIsoFolder, tShare, tSummary, tLog;
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
            var left = new Panel { Dock = DockStyle.Left, Width = 190, BackColor = Color.FromArgb(32, 54, 84), Padding = new Padding(12, 16, 8, 8) };
            var brand = new Label { Text = "LabBuilder", ForeColor = Color.White, Font = new Font("Segoe UI Semibold", 14F), Dock = DockStyle.Top, Height = 34 };
            var brand2 = new Label { Text = "Hyper-V TEST environment", ForeColor = Color.FromArgb(180, 200, 225), Dock = DockStyle.Top, Height = 28 };
            steps = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, Padding = new Padding(0, 12, 0, 0) };
            left.Controls.Add(steps); left.Controls.Add(brand2); left.Controls.Add(brand);

            var header = new Panel { Dock = DockStyle.Top, Height = 66, BackColor = Color.White, Padding = new Padding(16, 10, 16, 6) };
            lblSubtitle = new Label { Dock = DockStyle.Top, Height = 22, ForeColor = Color.DimGray };
            lblTitle = new Label { Dock = DockStyle.Top, Height = 28, Font = new Font("Segoe UI Semibold", 13F) };
            header.Controls.Add(lblSubtitle); header.Controls.Add(lblTitle);
            var sep = new Label { Dock = DockStyle.Top, Height = 1, BackColor = Color.Gainsboro };

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

            btnBack.Click += (s, e) => { if (current > 0) ShowPage(current - 1); };
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
                steps.Controls.Add(new Label
                {
                    Text = (i < index ? "\u2713 " : (i == index ? "\u25B6 " : "   ")) + pages[i].Step,
                    ForeColor = i == index ? Color.White : Color.FromArgb(170, 190, 215),
                    Font = i == index ? new Font("Segoe UI Semibold", 9.5F) : new Font("Segoe UI", 9.5F),
                    AutoSize = false, Width = 170, Height = 26, UseMnemonic = false
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
            ShowPage(current + 1);
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
            return t;
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
            var l = new Label { Text = text, AutoSize = true, MaximumSize = new Size(720, 0), ForeColor = Color.DimGray, Margin = new Padding(3, 4, 3, 10) };
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
                    "Windows 11 Enterprise LTSC workstations. Windows Server 2025 and Windows 11 evaluation ISOs are downloaded from " +
                    "the Microsoft Evaluation Center and verified.");
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
            add("Free memory (default lab needs ~20 GB)", freeGb >= 20, false, freeGb.ToString("N1") + " GB free of " + (ci.TotalPhysicalMemory / 1073741824.0).ToString("N0") + " GB");
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
            lblDisk = Note(t, "");
            tLabRoot.TextChanged += (s, e) => UpdateDiskNote();
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
                    S.InstallDir = tInstall.Text.TrimEnd('\\'); S.LabName = tLabName.Text; S.LabRoot = tLabRoot.Text.TrimEnd('\\');
                    return true;
                }
            };
        }

        void UpdateDiskNote()
        {
            try
            {
                var d = new DriveInfo(Path.GetPathRoot(tLabRoot.Text));
                lblDisk.Text = string.Format("Free space on {0}: {1:N0} GB. Needed: ~45 GB for ISOs and base images plus the VM disks " +
                    "(dynamic - they start at ~15 GB each and grow up to the size you choose).", d.Name, d.AvailableFreeSpace / 1073741824.0);
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

        DataGridView ServerGrid()
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
                new DataGridViewTextBoxColumn { Name = "Octet", HeaderText = "IP .x" },
                new DataGridViewTextBoxColumn { Name = "Cpu", HeaderText = "vCPU" },
                new DataGridViewTextBoxColumn { Name = "Mem", HeaderText = "RAM GB" },
                new DataGridViewTextBoxColumn { Name = "Disk", HeaderText = "Disk GB" }
            };
            foreach (var r in RoleCatalog.All) cols.Add(new DataGridViewCheckBoxColumn { Name = r, HeaderText = r == "FileServer" ? "File Server" : r });
            foreach (var c in cols)
            {
                fit(c); c.SortMode = DataGridViewColumnSortMode.NotSortable;
                c.MinimumWidth = Math.Max(c.MinimumWidth, TextRenderer.MeasureText(c.HeaderText, g.Font).Width + pad / 2);   // header never cut
                g.Columns.Add(c);
            }
            g.Columns["Name"].MinimumWidth = Math.Max(g.Columns["Name"].MinimumWidth, TextRenderer.MeasureText("WWWWWWWWWWW", g.Font).Width);   // room to type a 15-char name
            g.Columns.Add(new DataGridViewTextBoxColumn
            {
                Name = "Features", HeaderText = "Extra Windows features (comma separated)", SortMode = DataGridViewColumnSortMode.NotSortable,
                MinimumWidth = TextRenderer.MeasureText("Extra Windows features", g.Font).Width + pad,
                AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill
            });
            g.CurrentCellDirtyStateChanged += (s, e) => { if (g.IsCurrentCellDirty && g.CurrentCell is DataGridViewCheckBoxCell) g.CommitEdit(DataGridViewDataErrorContexts.Commit); };
            return g;
        }

        static void FillGrid(DataGridView g, List<ServerSpec> list)
        {
            g.Rows.Clear();
            foreach (var s in list) AddGridRow(g, s);
        }

        static void AddGridRow(DataGridView g, ServerSpec s)
        {
            var values = new List<object> { s.Name, s.HostOctet, s.Cpu, s.MemoryGB, s.DiskGB };
            foreach (var r in RoleCatalog.All) values.Add(s.Roles.Contains(r));
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
                foreach (var r in RoleCatalog.All) if (Convert.ToBoolean(row.Cells[r].Value ?? false)) s.Roles.Add(r);
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
                    "Tick the extra roles each DC should get. ADCS = Enterprise Root CA (one per lab). Disks are always dynamic.");
            gDc = ServerGrid();
            t.RowCount++; t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            t.Controls.Add(gDc, 0, t.RowCount - 1); t.SetColumnSpan(gDc, 2);
            nDcCount.ValueChanged += (s, e) => SyncRows(gDc, (int)nDcCount.Value, "DC", 10, null);
            return new Page
            {
                Step = "Domain controllers", Title = "Domain controllers", Subtitle = "How many, their size and roles", Content = t,
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
            Note(t, "Domain-joined Windows Server 2025 servers in OU=Servers. Tick the roles for each server; add any other Windows " +
                    "feature names (e.g. RSAT-AD-Tools, Telnet-Client) in the last column.");
            gMs = ServerGrid();
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
                Step = "Member servers", Title = "Member servers and roles", Subtitle = "Which servers and which roles on each", Content = t,
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

        Page PageWorkstations()
        {
            var t = Grid();
            nWsCount = Num(0, 20, S.WsCount);
            Row(t, "Number of test workstations", nWsCount);
            Note(t, "Windows 11 Enterprise LTSC, domain-joined into OU=Workstations, vTPM and Secure Boot.");
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
                Step = "Workstations", Title = "Test workstations", Subtitle = "How many and their generic size", Content = t,
                Enter = upd,
                Leave = () =>
                {
                    if (!Regex.IsMatch(tWsPrefix.Text, @"^[A-Za-z][A-Za-z0-9-]{0,12}$")) return Fail("Prefix: 1-13 letters, digits or '-', starting with a letter.", tWsPrefix);
                    int n = (int)nWsCount.Value, first = (int)nWsOctet.Value;
                    if (first + n - 1 > 254) return Fail("Not enough addresses: first octet + count - 1 must be <= 254.", nWsOctet);
                    var used = S.AllServers.Where(x => x.HostOctet >= first && x.HostOctet <= first + n - 1).Select(x => x.Name).ToList();
                    if (used.Count > 0) return Fail("Workstation addresses overlap server " + string.Join(", ", used) + ".", nWsOctet);
                    S.WsCount = n; S.WsPrefix = tWsPrefix.Text.ToUpperInvariant(); S.WsFirstOctet = first;
                    S.WsCpu = (int)nWsCpu.Value; S.WsMemoryGB = (int)nWsMem.Value; S.WsDiskGB = (int)nWsDisk.Value;
                    return true;
                }
            };
        }

        Page PageIso()
        {
            var t = Grid();
            rDownload = new RadioButton { Text = "Download from the Microsoft Evaluation Center (Windows Server 2025 ~8.2 GB, Windows 11 Enterprise LTSC ~5.1 GB)", AutoSize = true, Checked = string.IsNullOrEmpty(S.IsoSource) };
            rIsoFolder = new RadioButton { Text = "Use ISOs pre-downloaded with scripts\\Get-LabIso.ps1 (folder with iso-manifest.json)", AutoSize = true, Checked = !string.IsNullOrEmpty(S.IsoSource) };
            Full(t, rDownload); Full(t, rIsoFolder);
            tIsoFolder = Text_(S.IsoSource, 420);
            Row(t, "Pre-downloaded ISO folder", WithBrowse(tIsoFolder, true));
            Note(t, "ISOs are stored in <lab folder>\\ISO on this host, verified (HTTPS from Microsoft hosts only, size, SHA-256) " +
                    "and reused by later builds. Downloads resume after an interruption.");
            EventHandler sync = (s, e) => { tIsoFolder.Enabled = rIsoFolder.Checked; };
            rDownload.CheckedChanged += sync; rIsoFolder.CheckedChanged += sync; sync(null, null);
            return new Page
            {
                Step = "ISOs", Title = "Installation media", Subtitle = "Windows Server 2025 and Windows 11 Enterprise LTSC evaluation ISOs", Content = t,
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
            Func<ServerSpec, string> fmt = s => string.Format("  {0,-15} {1,-15} {2,2} vCPU {3,4} GB RAM {4,5} GB disk  {5}",
                s.Name, S.Prefix + "." + s.HostOctet, s.Cpu, s.MemoryGB, s.DiskGB, string.Join(", ", s.Roles.Concat(s.Features)));
            sb.AppendLine("Install folder      : " + S.InstallDir);
            sb.AppendLine("Lab name / folder   : " + S.LabName + "  /  " + S.LabRoot);
            sb.AppendLine("Domain              : " + S.Fqdn + "  (NetBIOS " + S.NetBios + ")");
            sb.AppendLine("Admin password      : " + (S.GeneratePassword ? "generated" : "entered by you"));
            sb.AppendLine("Network             : " + (S.SwitchType == "Private" ? "isolated (Private switch '" : "host-reachable (Internal switch '") + S.SwitchName + "'), " + S.Prefix + ".0/24");
            sb.AppendLine();
            sb.AppendLine("Domain controllers (" + S.DomainControllers.Count + "), AD DS + DNS on each:");
            foreach (var s in S.DomainControllers) sb.AppendLine(fmt(s));
            sb.AppendLine("Member servers (" + S.MemberServers.Count + "):");
            foreach (var s in S.MemberServers) sb.AppendLine(fmt(s));
            sb.AppendLine("Workstations (" + S.WsCount + "): " + (S.WsCount == 0 ? "none" :
                string.Format("{0}01..{0}{1:D2}, {2}.{3}.., {4} vCPU, {5} GB RAM, {6} GB disk each", S.WsPrefix, S.WsCount, S.Prefix, S.WsFirstOctet, S.WsCpu, S.WsMemoryGB, S.WsDiskGB)));
            sb.AppendLine();
            sb.AppendLine("Accounts            : " + S.DomainAdminCount + " domain admin(s), " + S.TestUserCount + " test user(s); test users " +
                (S.TestUsersLocalAdmin ? "ARE" : "are not") + " local admins on workstations");
            sb.AppendLine("Groups              : " + string.Join(", ", S.Groups.Select(g => g.Name)));
            if (S.HasRole("IIS")) sb.AppendLine("IIS                 : " + (S.IisHttps ? "HTTP + HTTPS (lab CA certificate)" : "HTTP only"));
            if (S.HasRole("DHCP")) sb.AppendLine("DHCP scope          : " + S.Prefix + "." + S.DhcpStart + " - " + S.Prefix + "." + S.DhcpEnd);
            if (S.HasRole("FileServer")) sb.AppendLine("File share          : \\\\<server>\\" + S.ShareName);
            sb.AppendLine("ISOs                : " + (string.IsNullOrEmpty(S.IsoSource) ? "download from Microsoft" : "import from " + S.IsoSource));
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
                var r = PsRunner.Run(PsRunner.FileArgs(Path.Combine(toolsDir, @"scripts\Test-LabConfigFile.ps1"), "-ConfigPath", TempConfigPath), toolsDir, 120000);
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
                    lblValidation.Height = 24 + 16 * Math.Min(6, Math.Max(1, errors.Count));
                    lblValidation.Text = "Fix these before continuing (use < Back):" + Environment.NewLine + "  - " +
                        string.Join(Environment.NewLine + "  - ", errors.Count > 0 ? errors : new List<string> { "validation failed: " + lastValidationOutput });
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
            tInstall.Text = S.InstallDir; tLabName.Text = S.LabName; tLabRoot.Text = S.LabRoot;
            tFqdn.Text = S.Fqdn; tNetBios.Text = S.NetBios; rGen.Checked = true;
            rPrivate.Checked = S.SwitchType == "Private"; rInternal.Checked = S.SwitchType == "Internal";
            tSwitch.Text = S.SwitchName; tPrefix.Text = S.Prefix;
            nDcCount.Value = Math.Max(1, Math.Min(5, S.DomainControllers.Count)); FillGrid(gDc, S.DomainControllers);
            nMsCount.Value = Math.Min(10, S.MemberServers.Count); FillGrid(gMs, S.MemberServers);
            cHttps.Checked = S.IisHttps; nDhcpStart.Value = S.DhcpStart; nDhcpEnd.Value = S.DhcpEnd; tShare.Text = S.ShareName;
            nAdmins.Value = S.DomainAdminCount; nUsers.Value = S.TestUserCount; nPwLen.Value = Math.Max(12, Math.Min(64, S.PasswordLength));
            rLocalAdminYes.Checked = S.TestUsersLocalAdmin; rLocalAdminNo.Checked = !S.TestUsersLocalAdmin;
            tGroups.Text = string.Join(Environment.NewLine, S.Groups.Select(g => g.Name + ";" + g.Description));
            nWsCount.Value = Math.Min(20, S.WsCount); tWsPrefix.Text = S.WsPrefix; nWsOctet.Value = Math.Max(1, Math.Min(254, S.WsFirstOctet));
            nWsCpu.Value = Math.Max(2, Math.Min(64, S.WsCpu)); nWsMem.Value = Math.Max(4, Math.Min(512, S.WsMemoryGB)); nWsDisk.Value = Math.Max(64, Math.Min(2048, S.WsDiskGB));
            if (current >= 0) ShowPage(current);
        }
    }
}
