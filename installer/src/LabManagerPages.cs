// LabBuilderSetup - lab manager pages (release 1.4.0, ADR 0015): first-run folders, start page (new / edit / delete / image
// library), delete flow, library view. C# 5, WinForms, no designer. The data comes from scripts\Get-LabInventory.ps1 (JSON).
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace LabBuilderSetup
{
    public partial class WizardForm
    {
        // ---- host settings (%ProgramData%\LabBuilder\settings.json) ----
        bool settingsExist, showFolders;
        string appFolder = @"C:\LabBuilder", labsFolder, libraryFolder;
        string managerMode = "New";                    // New | Edit | Delete | Library
        IDictionary<string, object> inventory;         // last Get-LabInventory.ps1 result
        IDictionary<string, object> selectedLab;       // lab chosen for Edit / Delete
        bool deleteDone, deleteRunning;

        TextBox tAppFolder, tLabsFolder, tLibFolder, tDeleteConfirm, tDeleteLog;
        Label lblFolderSpace, lblStartFolders, lblStartLibrary, lblDeleteWhat, lblLibraryInfo;
        RadioButton rModeNew, rModeEdit, rModeDelete, rModeLibrary;
        ListView lvLabs, lvLibrary;

        static string SettingsFile { get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), @"LabBuilder\settings.json"); } }

        static string DataDrive { get { return Directory.Exists(@"D:\") ? "D" : "C"; } }

        void InitLabManager()
        {
            labsFolder = DataDrive + @":\LabBuilder-Labs";
            libraryFolder = DataDrive + @":\LabBuilder-Library";
            try
            {
                if (File.Exists(SettingsFile))
                {
                    var d = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(SettingsFile)) as IDictionary<string, object>;
                    if (d != null)
                    {
                        appFolder = Str(d, "AppFolder", appFolder);
                        labsFolder = Str(d, "LabsFolder", labsFolder);
                        libraryFolder = Str(d, "LibraryFolder", libraryFolder);
                        settingsExist = true;
                    }
                }
            }
            catch { settingsExist = false; }
            ApplyFoldersToSettings();
            // New lab: the lab folder follows the lab name inside the Labs folder (ADR 0015).
            tLabName.TextChanged += (s, e) => { if (managerMode == "New") tLabRoot.Text = Path.Combine(labsFolder, tLabName.Text.Trim()); };
            // Mode-dependent pages: the lab pages are not used for Delete / Image library.
            foreach (var p in pages)
            {
                if (p.Step == "Welcome" || p.Step == "Folders" || p.Step == "Start" || p.Step == "Delete lab" || p.Step == "Image library") continue;
                var old = p.Hidden;
                p.Hidden = () => managerMode == "Delete" || managerMode == "Library" || (old != null && old());
            }
            ApplyModeLocks();
        }

        void ApplyFoldersToSettings()
        {
            S.InstallDir = appFolder;
            S.LibraryRoot = libraryFolder;
            if (managerMode == "New")
            {
                S.LabRoot = Path.Combine(labsFolder, S.LabName);
                S.OutputPath = Path.Combine(S.LabRoot, "output");
            }
            if (tInstall != null) { tInstall.Text = S.InstallDir; tLibrary.Text = S.LibraryRoot; tLabRoot.Text = S.LabRoot; }
        }

        // Install/lab paths come from the host settings; name, domain and network of an existing lab cannot change.
        void ApplyModeLocks()
        {
            bool edit = managerMode == "Edit";
            tInstall.Parent.Enabled = false; tLabRoot.Parent.Enabled = false; tLibrary.Parent.Enabled = false;
            tLabName.ReadOnly = edit;
            tFqdn.ReadOnly = edit;
            tNetBios.ReadOnly = edit && !S.Reconstructed;
            tSwitch.ReadOnly = edit; tPrefix.ReadOnly = edit;
            rPrivate.Enabled = rInternal.Enabled = !edit;
            rDiskDynamic.Enabled = rDiskDiff.Enabled = !edit;
        }

        // ---------------- helpers ----------------

        static string Str(IDictionary<string, object> d, string key, string def)
        {
            object v; if (d == null || !d.TryGetValue(key, out v) || v == null) return def;
            return Convert.ToString(v, CultureInfo.InvariantCulture);
        }
        static IEnumerable<IDictionary<string, object>> Items(IDictionary<string, object> d, string key)
        {
            object v; if (d == null || !d.TryGetValue(key, out v) || v == null) return new IDictionary<string, object>[0];
            var arr = v as IEnumerable;
            if (arr == null || v is string) return new IDictionary<string, object>[0];
            return arr.Cast<object>().OfType<IDictionary<string, object>>().ToList();
        }
        static IDictionary<string, object> Obj(IDictionary<string, object> d, string key)
        {
            object v; if (d == null || !d.TryGetValue(key, out v)) return null;
            return v as IDictionary<string, object>;
        }
        static bool Flag(IDictionary<string, object> d, string key)
        {
            object v; return d != null && d.TryGetValue(key, out v) && v is bool && (bool)v;
        }
        static string Gb(object bytes)
        {
            double b = 0; try { b = Convert.ToDouble(bytes, CultureInfo.InvariantCulture); } catch { }
            return (b / 1073741824.0).ToString("N1", CultureInfo.CurrentCulture) + " GB";
        }

        /// <summary>Runs scripts\Get-LabInventory.ps1 (from the unpacked payload) and returns its JSON result.</summary>
        IDictionary<string, object> RunInventory(params string[] args)
        {
            Cursor = Cursors.WaitCursor;
            try
            {
                var r = PsRunner.Run(PsRunner.FileArgs(Path.Combine(toolsDir, @"scripts\Get-LabInventory.ps1"), args), toolsDir, 300000);
                string line = r.Lines.FirstOrDefault(l => l.StartsWith("JSON: "));
                if (line == null) throw new InvalidOperationException(string.Join(Environment.NewLine, r.Lines.Take(20)));
                var d = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(line.Substring(6)) as IDictionary<string, object>;
                if (d == null) throw new InvalidOperationException("Inventory returned no data.");
                if (!Flag(d, "Ok")) throw new InvalidOperationException(Str(d, "Error", "unknown error"));
                return d;
            }
            finally { Cursor = Cursors.Default; }
        }

        int PageIndex(string step) { for (int i = 0; i < pages.Count; i++) if (pages[i].Step == step) return i; return -1; }

        // =====================================================================================
        // Folders (first run, or "Change folders...")
        // =====================================================================================

        Page PageFolders()
        {
            var t = Grid();
            Note(t, "LabBuilder keeps everything in three folders on this host. They are saved in " + SettingsFile +
                    " and used for every lab from now on.");
            tAppFolder = Text_(appFolder, 420);
            Row(t, "App folder", WithBrowse(tAppFolder, true));
            Note(t, "LabBuilder itself: scripts, module, example configuration.");
            tLabsFolder = Text_(labsFolder, 420);
            Row(t, "Labs folder", WithBrowse(tLabsFolder, true));
            Note(t, "Every lab gets its own subfolder here: <Labs folder>\\<LabName> with its configuration, VM disks, logs, reports and credentials.");
            tLibFolder = Text_(libraryFolder, 420);
            Row(t, "Library folder", WithBrowse(tLibFolder, true));
            Note(t, "Image library shared by all labs: ISOs and one base image per operating system, downloaded and built once. An existing library is reused as it is.");
            lblFolderSpace = Note(t, "");
            EventHandler upd = (s, e) =>
            {
                var parts = new List<string>();
                foreach (var tb in new[] { tLabsFolder, tLibFolder })
                {
                    try { var d = new DriveInfo(Path.GetPathRoot(tb.Text)); parts.Add(string.Format("{0} {1:N0} GB free", d.Name, d.AvailableFreeSpace / 1073741824.0)); }
                    catch { }
                }
                lblFolderSpace.Text = parts.Count == 0 ? "" : "Free space: " + string.Join(", ", parts.Distinct().ToArray()) +
                    ". Plan ~20 GB in the library per operating system and ~15 GB per VM (a few hundred MB with differencing disks).";
            };
            tLabsFolder.TextChanged += upd; tLibFolder.TextChanged += upd;
            return new Page
            {
                Step = "Folders", Title = "LabBuilder folders", Subtitle = "Where the app, the labs and the image library live on this host", Content = t,
                Hidden = () => settingsExist && !showFolders,
                Enter = () => { tAppFolder.Text = appFolder; tLabsFolder.Text = labsFolder; tLibFolder.Text = libraryFolder; upd(null, null); },
                Leave = () =>
                {
                    foreach (var tb in new[] { tAppFolder, tLabsFolder, tLibFolder })
                    {
                        if (!Regex.IsMatch(tb.Text, @"^[A-Za-z]:\\")) return Fail("Use absolute paths on local drives, e.g. D:\\LabBuilder-Labs.", tb);
                        if (!Directory.Exists(Path.GetPathRoot(tb.Text))) return Fail("Drive " + Path.GetPathRoot(tb.Text) + " does not exist.", tb);
                    }
                    string labs = tLabsFolder.Text.TrimEnd('\\') + "\\", lib = tLibFolder.Text.TrimEnd('\\') + "\\";
                    if (labs.StartsWith(lib, StringComparison.OrdinalIgnoreCase) || lib.StartsWith(labs, StringComparison.OrdinalIgnoreCase))
                        return Fail("The Labs folder and the Library folder must not be inside each other.", tLibFolder);
                    try
                    {
                        RunInventory("-SaveSettings", "-AppFolder", tAppFolder.Text.TrimEnd('\\'), "-LabsFolder", tLabsFolder.Text.TrimEnd('\\'), "-LibraryFolder", tLibFolder.Text.TrimEnd('\\'));
                    }
                    catch (Exception ex) { return Fail("Could not save the folders: " + ex.Message, null); }
                    appFolder = tAppFolder.Text.TrimEnd('\\'); labsFolder = tLabsFolder.Text.TrimEnd('\\'); libraryFolder = tLibFolder.Text.TrimEnd('\\');
                    settingsExist = true; showFolders = false;
                    ApplyFoldersToSettings();
                    return true;
                }
            };
        }

        // =====================================================================================
        // Start page: new / edit / delete / image library
        // =====================================================================================

        Page PageStart()
        {
            var t = Grid();
            lblStartFolders = new Label { AutoSize = true, ForeColor = Color.DimGray, UseMnemonic = false, Margin = new Padding(3, 7, 12, 3) };
            var bChange = new Button { Text = "Change folders...", AutoSize = true };
            bChange.Click += (s, e) => { showFolders = true; ShowPage(PageIndex("Folders")); };
            Full(t, Flow(lblStartFolders, bChange));
            Heading(t, "What do you want to do?");
            rModeNew = new RadioButton { Text = "Create a new lab", AutoSize = true, Checked = true };
            rModeEdit = new RadioButton { Text = "Edit an existing lab (add servers, workstations or roles, then build again)", AutoSize = true };
            rModeDelete = new RadioButton { Text = "Delete a lab (VMs, disks, its folder and credentials - never the image library)", AutoSize = true };
            rModeLibrary = new RadioButton { Text = "Show the image library (ISOs and base images)", AutoSize = true };
            var modes = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Margin = new Padding(0) };
            modes.Controls.AddRange(new Control[] { rModeNew, rModeEdit, rModeDelete, rModeLibrary });
            Full(t, modes);
            Heading(t, "Labs on this host");
            lvLabs = new ListView { View = View.Details, FullRowSelect = true, HideSelection = false, MultiSelect = false, HeaderStyle = ColumnHeaderStyle.Nonclickable,
                Width = 720, Height = Px(190), Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top };
            foreach (var c in new[] { "Lab", "Domain", "VMs", "Disks", "Last phase", "Size", "Folder" }) lvLabs.Columns.Add(c, -2);
            t.RowCount++; t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            t.Controls.Add(lvLabs, 0, t.RowCount - 1); t.SetColumnSpan(lvLabs, 2);
            lblStartLibrary = Note(t, "");
            EventHandler sync = (s, e) => { lvLabs.Enabled = rModeEdit.Checked || rModeDelete.Checked || rModeNew.Checked || rModeLibrary.Checked; };
            rModeEdit.CheckedChanged += sync;
            lvLabs.DoubleClick += (s, e) => { if (!rModeDelete.Checked) rModeEdit.Checked = true; Next(); };
            return new Page
            {
                Step = "Start", Title = "Lab manager", Subtitle = "Create a new lab, or edit or delete one that exists", Content = t,
                Enter = () =>
                {
                    lblStartFolders.Text = "App " + appFolder + "  |  Labs " + labsFolder + "  |  Library " + libraryFolder;
                    try { inventory = RunInventory("-RegisterDiscovered"); FillStart(); }
                    catch (Exception ex) { lblStartLibrary.Text = "Could not read the labs and the library: " + ex.Message; lblStartLibrary.ForeColor = Color.Firebrick; }
                },
                Leave = LeaveStart
            };
        }

        void FillStart()
        {
            lvLabs.Items.Clear();
            foreach (var lab in Items(inventory, "Labs"))
            {
                var vms = Items(lab, "VMs").ToList();
                int running = vms.Count(v => Str(v, "State", "") == "Running");
                string folder = Str(lab, "LabRoot", "");
                if (Str(lab, "Source", "") != "Labs") folder += "  (registered)";
                var it = new ListViewItem(new[] {
                    Str(lab, "Name", ""), Str(lab, "Domain", ""), string.Format("{0} ({1} running)", vms.Count, running),
                    Str(lab, "DiskType", "Dynamic"), Str(lab, "LastPhase", ""), Gb(lab.ContainsKey("SizeBytes") ? lab["SizeBytes"] : 0), folder });
                if (!Flag(lab, "HasConfig")) { it.ForeColor = Color.DarkOrange; it.ToolTipText = "Config not found - it will be reconstructed when you edit this lab."; }
                it.Tag = lab;
                lvLabs.Items.Add(it);
            }
            if (lvLabs.Items.Count == 0) lvLabs.Items.Add(new ListViewItem(new[] { "(no labs yet)", "", "", "", "", "", "" }) { ForeColor = Color.DimGray });
            foreach (ColumnHeader c in lvLabs.Columns) c.Width = -2;
            var lib = Obj(inventory, "Library");
            var imgs = Items(lib, "Images").ToList();
            int isos = imgs.Count(i => Flag(i, "IsoPresent")), bases = imgs.Count(i => Flag(i, "BasePresent"));
            lblStartLibrary.ForeColor = Color.DimGray;
            lblStartLibrary.Text = string.Format("Image library {0}: {1} of {2} ISOs and {3} base images ready{4}. Choose 'Show the image library' for details.",
                Str(lib, "LibraryRoot", libraryFolder), isos, imgs.Count, bases,
                imgs.Count(i => Flag(i, "BasePresent")) > 0 ? " (" + string.Join(", ", imgs.Where(i => Flag(i, "BasePresent")).Select(i => OsCatalog.Display(Str(i, "Key", ""))).ToArray()) + ")" : "");
        }

        bool LeaveStart()
        {
            string prev = managerMode;
            IDictionary<string, object> lab = lvLabs.SelectedItems.Count > 0 ? lvLabs.SelectedItems[0].Tag as IDictionary<string, object> : null;
            if (rModeNew.Checked)
            {
                if (prev != "New") { S = new LabSettings(); RebindAll(); }
                managerMode = "New";
                S.Mode = "New"; S.ConfigPath = ""; S.Reconstructed = false;
                ApplyFoldersToSettings();
                ApplyModeLocks();
                return true;
            }
            if ((rModeEdit.Checked || rModeDelete.Checked) && lab == null) return Fail("Select a lab in the list first.", lvLabs);
            if (rModeEdit.Checked)
            {
                string name = Str(lab, "Name", "");
                bool hadConfig = Flag(lab, "HasConfig");
                if (!hadConfig)
                {
                    if (MessageBox.Show(this, "The configuration of lab " + name + " was not found (labs before 1.4.0 shared one config file).\n\n" +
                        "LabBuilder can rebuild it from the lab's lab.json and Hyper-V: VM names, operating systems, IP addresses, vCPU, RAM and disks. " +
                        "The roles of each server and the NetBIOS name cannot be read back - check them on the next pages before you build again.\n\nRebuild the configuration now?",
                        Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return false;
                    try { inventory = RunInventory("-ReconstructConfig", "-LabName", name); }
                    catch (Exception ex) { return Fail("Could not rebuild the configuration: " + ex.Message, null); }
                    lab = Items(inventory, "Labs").FirstOrDefault(l => string.Equals(Str(l, "Name", ""), name, StringComparison.OrdinalIgnoreCase)) ?? lab;
                }
                string cfg = Str(lab, "ConfigPath", "");
                if (!LoadConfig(cfg, true)) return false;
                managerMode = "Edit";
                selectedLab = lab;
                S.Mode = "Edit"; S.ConfigPath = cfg; S.Reconstructed = !hadConfig; S.InstallDir = appFolder;
                if (string.IsNullOrEmpty(S.LibraryRoot)) S.LibraryRoot = libraryFolder;
                RebindAll();
                ApplyModeLocks();
                return true;
            }
            if (rModeDelete.Checked)
            {
                managerMode = "Delete"; selectedLab = lab; deleteDone = false;
                return true;
            }
            managerMode = "Library";
            return true;
        }

        // =====================================================================================
        // Delete a lab
        // =====================================================================================

        Page PageDeleteLab()
        {
            var t = Grid();
            lblDeleteWhat = new Label { AutoSize = true, MaximumSize = new Size(Px(900), 0), UseMnemonic = false, Margin = new Padding(3, 3, 3, 8), Tag = "wrap" };
            Full(t, lblDeleteWhat);
            tDeleteConfirm = Text_("", 220);
            Row(t, "Type the lab name to confirm", tDeleteConfirm);
            tDeleteLog = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Font = new Font("Consolas", 8.5F),
                BackColor = Color.FromArgb(20, 24, 30), ForeColor = Color.Gainsboro, Width = 720, Height = Px(220), Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top };
            Full(t, tDeleteLog);
            tDeleteConfirm.TextChanged += (s, e) => { if (!deleteDone && !deleteRunning) btnNext.Enabled = tDeleteConfirm.Text == Str(selectedLab, "Name", "\0"); };
            return new Page
            {
                Step = "Delete lab", Title = "Delete a lab", Subtitle = "Everything of this lab is removed - the shared image library stays", Content = t,
                Hidden = () => managerMode != "Delete",
                Enter = () =>
                {
                    var lab = selectedLab;
                    var vms = Items(lab, "VMs").ToList();
                    lblDeleteWhat.Text =
                        "Lab " + Str(lab, "Name", "") + "  (domain " + Str(lab, "Domain", "?") + ", " + Str(lab, "DiskType", "Dynamic") + " disks)\n\n" +
                        "Will be deleted:\n" +
                        "  - VMs, their checkpoints and disks: " + (vms.Count == 0 ? "(none recorded - VMs tagged LabBuilder:" + Str(lab, "Name", "") + " are found on the host)" :
                            string.Join(", ", vms.Select(v => Str(v, "VMName", "") + " [" + Str(v, "State", "") + "]").ToArray())) + "\n" +
                        "  - switch " + Str(lab, "Switch", "(unknown)") + " (only if no other VM uses it)\n" +
                        "  - lab files in " + Str(lab, "LabRoot", "") + " (VMs, Logs, Reports, lab.json, configuration) and the folder if it is then empty\n" +
                        "  - credentials and reports in " + Str(lab, "OutputPath", "") + "\n\n" +
                        "Kept: the image library " + libraryFolder + " (ISOs and base images) and every other lab.";
                    tDeleteConfirm.Text = ""; tDeleteConfirm.Enabled = !deleteDone;
                    if (!deleteDone) tDeleteLog.Text = "";
                    btnNext.Text = deleteDone ? "Back to start" : "Delete lab";
                    btnNext.Enabled = deleteDone;
                }
            };
        }

        void RunDelete()
        {
            string name = Str(selectedLab, "Name", "");
            deleteRunning = true;
            btnNext.Enabled = btnBack.Enabled = tDeleteConfirm.Enabled = false;
            tDeleteLog.AppendText("Deleting lab " + name + " ..." + Environment.NewLine);
            try
            {
                PsRunner.Start(PsRunner.FileArgs(Path.Combine(toolsDir, @"scripts\Remove-Lab.ps1"), "-LabName", name, "-Force"), toolsDir, null,
                    line => { if (!IsDisposed) BeginInvoke((Action)(() => { if (!line.StartsWith("##LBP ")) tDeleteLog.AppendText(line + Environment.NewLine); })); },
                    code => { if (!IsDisposed) BeginInvoke((Action)(() =>
                    {
                        deleteRunning = false; deleteDone = code == 0;
                        tDeleteLog.AppendText(Environment.NewLine + (code == 0 ? "Lab " + name + " deleted." : "Delete stopped (exit code " + code + ") - see the messages above; run it again after fixing the cause.") + Environment.NewLine);
                        btnBack.Enabled = true; btnNext.Enabled = true;
                        btnNext.Text = deleteDone ? "Back to start" : "Delete lab";
                        tDeleteConfirm.Enabled = !deleteDone;
                    })); });
            }
            catch (Exception ex)
            {
                deleteRunning = false; btnBack.Enabled = btnNext.Enabled = true;
                tDeleteLog.AppendText("Could not start: " + ex.Message + Environment.NewLine);
            }
        }

        // =====================================================================================
        // Image library
        // =====================================================================================

        Page PageLibrary()
        {
            var t = Grid();
            lblLibraryInfo = Note(t, "");
            lvLibrary = new ListView { View = View.Details, FullRowSelect = true, HeaderStyle = ColumnHeaderStyle.Nonclickable, Width = 720, Height = Px(260),
                Anchor = AnchorStyles.Left | AnchorStyles.Right | AnchorStyles.Top };
            foreach (var c in new[] { "Operating system", "ISO", "Base image", "Windows build", "Used by (differencing disks)" }) lvLibrary.Columns.Add(c, -2);
            t.RowCount++; t.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            t.Controls.Add(lvLibrary, 0, t.RowCount - 1); t.SetColumnSpan(lvLibrary, 2);
            Note(t, "Missing ISOs are downloaded (or imported) and missing base images built the first time a lab needs them; after that every lab reuses them. " +
                    "Windows 10 needs your own ISO (chosen on the Workstations page).");
            return new Page
            {
                Step = "Image library", Title = "Image library", Subtitle = "ISOs and base images shared by all labs on this host", Content = t,
                Hidden = () => managerMode != "Library",
                Enter = () =>
                {
                    btnNext.Text = "Back to start";
                    var lib = Obj(inventory, "Library");
                    lblLibraryInfo.Text = "Library folder: " + Str(lib, "LibraryRoot", libraryFolder);
                    lvLibrary.Items.Clear();
                    foreach (var i in Items(lib, "Images"))
                    {
                        bool roleImage = Str(i, "Key", "").EndsWith("-Roles");
                        string iso = roleImage ? "(made from the plain base image)"
                                   : Flag(i, "IsoPresent") ? Gb(i.ContainsKey("IsoBytes") ? i["IsoBytes"] : 0) + ", " + Str(i, "IsoRecorded", "").Split('T')[0]
                                   : (Flag(i, "Supplied") ? "your ISO (not imported yet)" : "not downloaded yet");
                        string bas = Flag(i, "BasePresent") ? ("built " + Str(i, "BaseCreated", "").Split('T')[0] +
                                     (Flag(i, "BaseCurrent") ? "" : (roleImage ? " - older base" : " - older ISO"))) : "not built yet";
                        object u; string usedBy = "";
                        if (i.TryGetValue("UsedBy", out u) && u is IEnumerable && !(u is string)) usedBy = string.Join(", ", ((IEnumerable)u).Cast<object>().Select(x => Convert.ToString(x)).ToArray());
                        var it = new ListViewItem(new[] { OsCatalog.Display(Str(i, "Key", "")), iso, bas, Str(i, "BaseVersion", ""), usedBy });
                        it.ForeColor = Flag(i, "BasePresent") ? Color.DarkGreen : (Flag(i, "IsoPresent") ? Color.SteelBlue : Color.DimGray);
                        lvLibrary.Items.Add(it);
                    }
                    foreach (var u in Items(lib, "UnknownIsos"))
                        lvLibrary.Items.Add(new ListViewItem(new[] { "Unknown ISO: " + Str(u, "FileName", ""), Gb(u.ContainsKey("Bytes") ? u["Bytes"] : 0) + ", " + Str(u, "Modified", ""), "", "", "" }) { ForeColor = Color.DarkOrange });
                    foreach (ColumnHeader c in lvLibrary.Columns) c.Width = -2;
                }
            };
        }

        /// <summary>Next on the lab-manager pages. Returns true when handled here.</summary>
        bool HandleManagerNext(Page p)
        {
            if (p.Step == "Image library") { managerMode = "New"; rModeNew.Checked = true; ShowPage(PageIndex("Start")); return true; }
            if (p.Step == "Delete lab")
            {
                if (deleteRunning) return true;
                if (deleteDone) { managerMode = "New"; rModeNew.Checked = true; deleteDone = false; ShowPage(PageIndex("Start")); return true; }
                if (tDeleteConfirm.Text != Str(selectedLab, "Name", "\0")) { Fail("Type the lab name exactly to confirm.", tDeleteConfirm); return true; }
                RunDelete();
                return true;
            }
            return false;
        }

        /// <summary>New lab: the name must not be in use on this host and its folder must be new or empty.</summary>
        bool CheckNewLabName()
        {
            if (managerMode != "New") return true;
            string name = tLabName.Text.Trim();
            if (inventory != null && Items(inventory, "Labs").Any(l => string.Equals(Str(l, "Name", ""), name, StringComparison.OrdinalIgnoreCase)))
                return Fail("A lab named " + name + " already exists on this host - choose another name, or go back and choose 'Edit an existing lab'.", tLabName);
            string folder = Path.Combine(labsFolder, name);
            if (Directory.Exists(folder) && Directory.EnumerateFileSystemEntries(folder).Any())
                return Fail("The folder " + folder + " already exists and is not empty - choose another lab name.", tLabName);
            S.LabRoot = folder; S.OutputPath = Path.Combine(folder, "output"); S.InstallDir = appFolder; S.LibraryRoot = libraryFolder;
            return true;
        }
    }
}
