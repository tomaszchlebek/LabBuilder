// LabBuilderSetup - tester inputs and .psd1 writer/reader (ADR 0011). C# 5 (inbox csc.exe).
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace LabBuilderSetup
{
    public static class RoleCatalog
    {
        public static readonly string[] All = new[] { "ADCS", "IIS", "DHCP", "FileServer", "SQL" };
        /// <summary>Roles allowed on domain controllers (SQL Server is not supported on a DC).</summary>
        public static readonly string[] DomainController = new[] { "ADCS", "IIS", "DHCP", "FileServer" };
        public static string Header(string role) { return role == "FileServer" ? "File Server" : role; }
    }

    public class ServerSpec
    {
        public string Name;
        public int HostOctet;
        public int Cpu;
        public int MemoryGB;
        public int DiskGB;
        public List<string> Roles;
        public List<string> Features;

        public ServerSpec(string name, int octet, int cpu, int memoryGB, int diskGB, params string[] roles)
        {
            Name = name; HostOctet = octet; Cpu = cpu; MemoryGB = memoryGB; DiskGB = diskGB;
            Roles = new List<string>(roles ?? new string[0]);
            Features = new List<string>();
        }
    }

    public class GroupSpec
    {
        public string Name;
        public string Description;
        public GroupSpec(string name, string description) { Name = name; Description = description; }
    }

    /// <summary>Everything the tester decides in the wizard. Password and install folder are never written to the config.</summary>
    public class LabSettings
    {
        public string InstallDir;
        public string LabName;
        public string LabRoot;
        public string Fqdn;
        public string NetBios;
        public bool GeneratePassword;
        public string AdminPassword;
        public string SwitchType;
        public string SwitchName;
        public string Prefix;
        public List<ServerSpec> DomainControllers;
        public List<ServerSpec> MemberServers;
        public int WsCount;
        public string WsPrefix;
        public int WsFirstOctet;
        public int WsCpu;
        public int WsMemoryGB;
        public int WsDiskGB;
        public int DomainAdminCount;
        public int TestUserCount;
        public int PasswordLength;
        public bool TestUsersLocalAdmin;
        public List<GroupSpec> Groups;
        public bool IisHttps;
        public int DhcpStart;
        public int DhcpEnd;
        public string ShareName;
        // Role SQL (FR-20, ADR 0012)
        public string SqlInstance;
        public int SqlPort;
        public bool SqlMixed;
        public List<string> SqlSysadminGroups;
        public string SqlDatabase;
        public List<string> SqlDbOwnerGroups;
        public string SqlCollation;
        public string IsoSource;
        public bool ConfigOnly;

        public LabSettings()
        {
            InstallDir = @"C:\LabBuilder";
            LabName = "TESTLAB";
            LabRoot = Directory.Exists(@"D:\") ? @"D:\HyperVLab" : @"C:\HyperVLab";
            Fqdn = ""; NetBios = "";
            GeneratePassword = true; AdminPassword = "";
            SwitchType = "Private"; SwitchName = "LAB-Isolated"; Prefix = "10.10.10";
            DomainControllers = new List<ServerSpec> { new ServerSpec("DC01", 10, 2, 4, 80, "ADCS") };
            MemberServers = new List<ServerSpec> { new ServerSpec("IIS01", 20, 2, 4, 80, "IIS") };
            WsCount = 3; WsPrefix = "WS"; WsFirstOctet = 101; WsCpu = 2; WsMemoryGB = 4; WsDiskGB = 80;
            DomainAdminCount = 1; TestUserCount = 3; PasswordLength = 16; TestUsersLocalAdmin = false;
            Groups = new List<GroupSpec> {
                new GroupSpec("SG-Lab-Testers", "All lab test users"),
                new GroupSpec("SG-Lab-WebAdmins", "IIS content administrators"),
                new GroupSpec("SG-Lab-Finance", "Sample department group"),
                new GroupSpec("SG-Lab-HR", "Sample department group")
            };
            IisHttps = true; DhcpStart = 200; DhcpEnd = 250; ShareName = "LabShare";
            SqlInstance = "SQLEXPRESS"; SqlPort = 1433; SqlMixed = false; SqlSysadminGroups = new List<string>();
            SqlDatabase = "LabDB"; SqlDbOwnerGroups = new List<string> { "SG-Lab-Testers" }; SqlCollation = "";
            IsoSource = ""; ConfigOnly = false;
        }

        public IEnumerable<ServerSpec> AllServers { get { return DomainControllers.Concat(MemberServers); } }
        public bool HasRole(string role) { return AllServers.Any(s => s.Roles.Contains(role)); }

        public int TotalCpu { get { return AllServers.Sum(s => s.Cpu) + WsCount * WsCpu; } }
        public int TotalMemoryGB { get { return AllServers.Sum(s => s.MemoryGB) + WsCount * WsMemoryGB; } }
        public int TotalDiskGB { get { return AllServers.Sum(s => s.DiskGB) + WsCount * WsDiskGB; } }
        public int VmCount { get { return DomainControllers.Count + MemberServers.Count + WsCount; } }

        // ---------------- .psd1 writer ----------------

        static string Q(string s) { return "'" + (s ?? "").Replace("'", "''") + "'"; }
        static string Arr(IEnumerable<string> items)
        {
            var list = items.Where(i => !string.IsNullOrWhiteSpace(i)).Select(i => Q(i.Trim())).ToList();
            return list.Count == 0 ? "@()" : "@(" + string.Join(", ", list) + ")";
        }
        static string B(bool b) { return b ? "$true" : "$false"; }

        static string Server(ServerSpec s)
        {
            return string.Format(CultureInfo.InvariantCulture,
                "        @{{ Name = {0}; HostOctet = {1}; ProcessorCount = {2}; MemoryBytes = {3}GB; DiskSizeBytes = {4}GB; Roles = {5}; AdditionalFeatures = {6} }}",
                Q(s.Name), s.HostOctet, s.Cpu, s.MemoryGB, s.DiskGB, Arr(s.Roles), Arr(s.Features));
        }

        /// <summary>Config v2 holding only the tester's choices; everything else comes from BaseConfig (ADR 0011).</summary>
        public string ToPsd1()
        {
            var sb = new StringBuilder();
            sb.AppendLine("# Written by LabBuilderSetup.exe on " + DateTime.Now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture) + ".");
            sb.AppendLine("# Only the tester's choices are here; all other settings come from BaseConfig. ASCII only.");
            sb.AppendLine("@{");
            sb.AppendLine("    BaseConfig    = 'lab.config.example.psd1'");
            sb.AppendLine("    SchemaVersion = 2");
            sb.AppendLine("    LabName       = " + Q(LabName));
            sb.AppendLine("    Paths   = @{ LabRoot = " + Q(LabRoot) + " }");
            sb.AppendLine("    Domain  = @{ Fqdn = " + Q(Fqdn.ToLowerInvariant()) + "; NetBiosName = " + Q(NetBios.ToUpperInvariant()) + " }");
            sb.AppendLine("    Network = @{ SwitchName = " + Q(SwitchName) + "; SwitchType = " + Q(SwitchType) + "; Prefix = " + Q(Prefix) + " }");
            sb.AppendLine("    DomainControllers = @(");
            foreach (var s in DomainControllers) sb.AppendLine(Server(s));
            sb.AppendLine("    )");
            if (MemberServers.Count == 0) sb.AppendLine("    MemberServers = @()");
            else
            {
                sb.AppendLine("    MemberServers = @(");
                foreach (var s in MemberServers) sb.AppendLine(Server(s));
                sb.AppendLine("    )");
            }
            sb.AppendLine(string.Format(CultureInfo.InvariantCulture,
                "    Workstations = @{{ Count = {0}; NamePrefix = {1}; FirstHostOctet = {2}; ProcessorCount = {3}; MemoryBytes = {4}GB; DiskSizeBytes = {5}GB }}",
                WsCount, Q(WsPrefix), WsFirstOctet, WsCpu, WsMemoryGB, WsDiskGB));
            sb.AppendLine(string.Format(CultureInfo.InvariantCulture,
                "    Accounts = @{{ DomainAdminCount = {0}; TestUserCount = {1}; PasswordLength = {2}; TestUsersAreLocalAdmins = {3} }}",
                DomainAdminCount, TestUserCount, PasswordLength, B(TestUsersLocalAdmin)));
            sb.AppendLine("    Groups = @(");
            foreach (var g in Groups) sb.AppendLine("        @{ Name = " + Q(g.Name) + "; Description = " + Q(g.Description) + " }");
            sb.AppendLine("    )");
            sb.AppendLine("    Roles = @{");
            sb.AppendLine("        IIS        = @{ EnableHttps = " + B(IisHttps) + " }");
            sb.AppendLine(string.Format(CultureInfo.InvariantCulture, "        DHCP       = @{{ RangeStartOctet = {0}; RangeEndOctet = {1} }}", DhcpStart, DhcpEnd));
            sb.AppendLine("        FileServer = @{ ShareName = " + Q(ShareName) + " }");
            sb.AppendLine(string.Format(CultureInfo.InvariantCulture,
                "        SQL        = @{{ InstanceName = {0}; TcpPort = {1}; AuthenticationMode = {2}; SysadminGroups = {3}; DatabaseName = {4}; DbOwnerGroups = {5}; Collation = {6} }}",
                Q(SqlInstance), SqlPort, Q(SqlMixed ? "Mixed" : "Windows"), Arr(SqlSysadminGroups), Q(SqlDatabase), Arr(SqlDbOwnerGroups), Q(SqlCollation)));
            sb.AppendLine("    }");
            sb.AppendLine("}");
            return sb.ToString();
        }

        // ---------------- reader (from Import-LabConfig | ConvertTo-Json) ----------------

        static object Get(IDictionary<string, object> d, string path)
        {
            object cur = d;
            foreach (var part in path.Split('.'))
            {
                var dict = cur as IDictionary<string, object>;
                if (dict == null || !dict.ContainsKey(part)) return null;
                cur = dict[part];
            }
            return cur;
        }
        static string S(IDictionary<string, object> d, string path, string def)
        {
            var v = Get(d, path); return v == null ? def : Convert.ToString(v, CultureInfo.InvariantCulture);
        }
        static long L(IDictionary<string, object> d, string path, long def)
        {
            var v = Get(d, path); return v == null ? def : Convert.ToInt64(v, CultureInfo.InvariantCulture);
        }
        static bool Bo(IDictionary<string, object> d, string path, bool def)
        {
            var v = Get(d, path); return v == null ? def : Convert.ToBoolean(v, CultureInfo.InvariantCulture);
        }
        static IEnumerable<object> List(object v)
        {
            if (v == null) return new object[0];
            var arr = v as IEnumerable;
            if (arr != null && !(v is string) && !(v is IDictionary<string, object>)) return arr.Cast<object>();
            return new[] { v };
        }
        static int Gb(long bytes) { return (int)(bytes / (1024L * 1024L * 1024L)); }

        static List<ServerSpec> Servers(object v)
        {
            var result = new List<ServerSpec>();
            foreach (var o in List(v))
            {
                var d = o as IDictionary<string, object>;
                if (d == null) continue;
                var s = new ServerSpec(S(d, "Name", ""), (int)L(d, "HostOctet", 0), (int)L(d, "ProcessorCount", 2),
                    Gb(L(d, "MemoryBytes", 4L << 30)), Gb(L(d, "DiskSizeBytes", 80L << 30)));
                s.Roles = List(Get(d, "Roles")).Select(x => Convert.ToString(x)).Where(x => !string.IsNullOrEmpty(x)).ToList();
                s.Features = List(Get(d, "AdditionalFeatures")).Select(x => Convert.ToString(x)).Where(x => !string.IsNullOrEmpty(x)).ToList();
                result.Add(s);
            }
            return result;
        }

        public static LabSettings FromConfig(IDictionary<string, object> d, LabSettings keep)
        {
            var s = new LabSettings();
            s.InstallDir = keep.InstallDir; s.IsoSource = keep.IsoSource;
            s.LabName = S(d, "LabName", s.LabName);
            s.LabRoot = S(d, "Paths.LabRoot", s.LabRoot);
            s.Fqdn = S(d, "Domain.Fqdn", "");
            s.NetBios = S(d, "Domain.NetBiosName", "");
            s.SwitchType = S(d, "Network.SwitchType", s.SwitchType);
            s.SwitchName = S(d, "Network.SwitchName", s.SwitchName);
            s.Prefix = S(d, "Network.Prefix", s.Prefix);
            s.DomainControllers = Servers(Get(d, "DomainControllers"));
            s.MemberServers = Servers(Get(d, "MemberServers"));
            s.WsCount = (int)L(d, "Workstations.Count", s.WsCount);
            s.WsPrefix = S(d, "Workstations.NamePrefix", s.WsPrefix);
            s.WsFirstOctet = (int)L(d, "Workstations.FirstHostOctet", s.WsFirstOctet);
            s.WsCpu = (int)L(d, "Workstations.ProcessorCount", s.WsCpu);
            s.WsMemoryGB = Gb(L(d, "Workstations.MemoryBytes", 4L << 30));
            s.WsDiskGB = Gb(L(d, "Workstations.DiskSizeBytes", 80L << 30));
            s.DomainAdminCount = (int)L(d, "Accounts.DomainAdminCount", s.DomainAdminCount);
            s.TestUserCount = (int)L(d, "Accounts.TestUserCount", s.TestUserCount);
            s.PasswordLength = (int)L(d, "Accounts.PasswordLength", s.PasswordLength);
            s.TestUsersLocalAdmin = Bo(d, "Accounts.TestUsersAreLocalAdmins", false);
            var groups = new List<GroupSpec>();
            foreach (var o in List(Get(d, "Groups")))
            {
                var g = o as IDictionary<string, object>;
                if (g != null) groups.Add(new GroupSpec(S(g, "Name", ""), S(g, "Description", "")));
            }
            if (groups.Count > 0) s.Groups = groups;
            s.IisHttps = Bo(d, "Roles.IIS.EnableHttps", true);
            s.DhcpStart = (int)L(d, "Roles.DHCP.RangeStartOctet", 200);
            s.DhcpEnd = (int)L(d, "Roles.DHCP.RangeEndOctet", 250);
            s.ShareName = S(d, "Roles.FileServer.ShareName", "LabShare");
            s.SqlInstance = S(d, "Roles.SQL.InstanceName", s.SqlInstance);
            s.SqlPort = (int)L(d, "Roles.SQL.TcpPort", s.SqlPort);
            s.SqlMixed = S(d, "Roles.SQL.AuthenticationMode", "Windows") == "Mixed";
            if (Get(d, "Roles.SQL") != null)
            {
                s.SqlSysadminGroups = List(Get(d, "Roles.SQL.SysadminGroups")).Select(x => Convert.ToString(x)).Where(x => !string.IsNullOrEmpty(x)).ToList();
                s.SqlDbOwnerGroups = List(Get(d, "Roles.SQL.DbOwnerGroups")).Select(x => Convert.ToString(x)).Where(x => !string.IsNullOrEmpty(x)).ToList();
            }
            s.SqlDatabase = S(d, "Roles.SQL.DatabaseName", s.SqlDatabase);
            s.SqlCollation = S(d, "Roles.SQL.Collation", s.SqlCollation);
            if (s.DomainControllers.Count == 0) s.DomainControllers.Add(new ServerSpec("DC01", 10, 2, 4, 80, "ADCS"));
            return s;
        }
    }
}
