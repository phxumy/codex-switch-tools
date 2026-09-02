using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Web.Script.Serialization;

[assembly: AssemblyTitle("Codex 配置切换工具")]
[assembly: AssemblyDescription("中文 Codex Provider、模型、上下文、密钥与备份管理工具")]
[assembly: AssemblyProduct("Codex Switch Tools")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.0.0")]

namespace CodexSwitchToolsGui
{
    internal sealed class CommandResult
    {
        internal int ExitCode;
        internal string StandardOutput = string.Empty;
        internal string StandardError = string.Empty;

        internal bool Success { get { return ExitCode == 0; } }

        internal string CombinedOutput
        {
            get
            {
                string value = (StandardOutput + Environment.NewLine + StandardError).Trim();
                return value.Length > 6000 ? value.Substring(value.Length - 6000) : value;
            }
        }
    }

    internal static class NativeEnvironmentMethods
    {
        internal const int HwndBroadcast = 0xffff;
        internal const int WmSettingChange = 0x001a;
        internal const int SmtoAbortIfHung = 0x0002;

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr SendMessageTimeout(
            IntPtr window,
            int message,
            IntPtr wParam,
            string lParam,
            int flags,
            int timeout,
            out IntPtr result);
    }

    internal static class ApplicationResources
    {
        private const string IconResourceName = "CodexSwitchTools.AppIcon.ico";

        internal static Icon LoadApplicationIcon()
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(IconResourceName))
            {
                if (stream == null) throw new InvalidOperationException("应用图标资源缺失，请重新构建 CodexSwitchTools.exe。");
                using (var source = new Icon(stream)) return (Icon)source.Clone();
            }
        }
    }

    internal sealed class PowerShellBridge : IDisposable
    {
        private const string CoreResourceName = "CodexSwitchTools.Core.ps1";
        private const string FingerprintResourceName = "CodexSwitchTools.BuildFingerprint.txt";
        private readonly string enginePath;
        private readonly string corePath;
        private readonly string coreDirectory;
        private readonly string coreHash;
        private readonly string configOverride;

        internal PowerShellBridge(string configPath)
        {
            configOverride = string.IsNullOrWhiteSpace(configPath) ? null : Path.GetFullPath(configPath);
            enginePath = FindPowerShell();
            corePath = ExtractCore(out coreDirectory, out coreHash);
        }

        internal CommandResult Run(IEnumerable<string> actionArguments, string standardInput)
        {
            VerifyExtractedCore();
            var args = new List<string>
            {
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                corePath
            };
            args.AddRange(actionArguments);
            if (!string.IsNullOrWhiteSpace(configOverride))
            {
                args.Add("-ConfigPath");
                args.Add(configOverride);
            }
            args.Add("-NoPause");

            var startInfo = new ProcessStartInfo
            {
                FileName = enginePath,
                Arguments = string.Join(" ", args.Select(QuoteArgument).ToArray()),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = standardInput != null,
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false),
                WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory
            };

            var stdout = new StringBuilder();
            var stderr = new StringBuilder();
            using (var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true })
            {
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null) stdout.AppendLine(e.Data);
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null) stderr.AppendLine(e.Data);
                };

                if (!process.Start())
                    throw new InvalidOperationException("无法启动 PowerShell 配置核心。");
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();

                if (standardInput != null)
                {
                    process.StandardInput.Write(standardInput);
                    process.StandardInput.Close();
                }

                if (!process.WaitForExit(120000))
                {
                    bool terminated = TerminateProcessTree(process);
                    throw new TimeoutException(terminated
                        ? "配置操作超过 120 秒，相关进程树已终止。请检查 Codex 或网络状态。"
                        : "配置操作超过 120 秒，已请求终止但无法确认所有子进程退出。请在任务管理器检查 PowerShell/Codex 进程。");
                }
                process.WaitForExit();
                return new CommandResult
                {
                    ExitCode = process.ExitCode,
                    StandardOutput = stdout.ToString().Trim(),
                    StandardError = stderr.ToString().Trim()
                };
            }
        }

        internal string CoreDirectoryForTest { get { return coreDirectory; } }

        internal bool CoreDirectoryAclIsPrivateForTest()
        {
            DirectorySecurity security = Directory.GetAccessControl(coreDirectory);
            if (!security.AreAccessRulesProtected) return false;
            SecurityIdentifier currentUser = WindowsIdentity.GetCurrent().User;
            SecurityIdentifier system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            AuthorizationRuleCollection rules = security.GetAccessRules(true, true, typeof(SecurityIdentifier));
            foreach (FileSystemAccessRule rule in rules)
            {
                if (rule.AccessControlType != AccessControlType.Allow) continue;
                SecurityIdentifier sid = rule.IdentityReference as SecurityIdentifier;
                if (sid == null || (!sid.Equals(currentUser) && !sid.Equals(system))) return false;
            }
            return true;
        }

        internal static string GetBuildFingerprint()
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(FingerprintResourceName))
            {
                if (stream == null) return string.Empty;
                using (var reader = new StreamReader(stream, Encoding.UTF8, true)) return reader.ReadToEnd().Trim();
            }
        }

        private static string FindPowerShell()
        {
            bool forceWindowsPowerShell = string.Equals(
                Environment.GetEnvironmentVariable("CST_GUI_FORCE_WINDOWS_POWERSHELL"),
                "1",
                StringComparison.Ordinal);
            var roots = new List<string>();
            string programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string programW6432 = Environment.GetEnvironmentVariable("ProgramW6432", EnvironmentVariableTarget.Machine);
            if (!string.IsNullOrWhiteSpace(programFiles)) roots.Add(programFiles);
            if (!string.IsNullOrWhiteSpace(programW6432) && !roots.Contains(programW6432, StringComparer.OrdinalIgnoreCase)) roots.Add(programW6432);
            if (!forceWindowsPowerShell)
            {
                foreach (string root in roots)
                {
                    string version7 = Path.Combine(root, "PowerShell", "7", "pwsh.exe");
                    if (IsTrustedMicrosoftPowerShell(version7)) return version7;
                    string powerShellRoot = Path.Combine(root, "PowerShell");
                    if (Directory.Exists(powerShellRoot))
                    {
                        foreach (string directory in Directory.GetDirectories(powerShellRoot).OrderByDescending(p => p, StringComparer.OrdinalIgnoreCase))
                        {
                            string candidate = Path.Combine(directory, "pwsh.exe");
                            if (IsTrustedMicrosoftPowerShell(candidate)) return candidate;
                        }
                    }
                }
            }

            string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string windowsPowerShell = Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe");
            if (File.Exists(windowsPowerShell) && IsTrustedMicrosoftPowerShell(windowsPowerShell)) return windowsPowerShell;
            throw new FileNotFoundException("未找到 PowerShell 7 或 Windows PowerShell 5.1。");
        }

        private static bool IsTrustedMicrosoftPowerShell(string path)
        {
            if (!File.Exists(path)) return false;
            try
            {
                FileVersionInfo version = FileVersionInfo.GetVersionInfo(path);
                string company = version.CompanyName ?? string.Empty;
                string product = version.ProductName ?? string.Empty;
                string description = version.FileDescription ?? string.Empty;
                string original = version.OriginalFilename ?? string.Empty;
                return company.IndexOf("Microsoft", StringComparison.OrdinalIgnoreCase) >= 0 &&
                       (product.IndexOf("PowerShell", StringComparison.OrdinalIgnoreCase) >= 0 ||
                        description.IndexOf("PowerShell", StringComparison.OrdinalIgnoreCase) >= 0 ||
                        string.Equals(original, "powershell.exe", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(original, "pwsh.exe", StringComparison.OrdinalIgnoreCase));
            }
            catch { return false; }
        }

        private static string ExtractCore(out string directory, out string hash)
        {
            byte[] data;
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream stream = assembly.GetManifestResourceStream(CoreResourceName))
            {
                if (stream == null) throw new InvalidOperationException("EXE 中缺少内嵌配置核心。");
                using (var memory = new MemoryStream())
                {
                    stream.CopyTo(memory);
                    data = memory.ToArray();
                }
            }

            using (SHA256 sha = SHA256.Create())
                hash = BitConverter.ToString(sha.ComputeHash(data)).Replace("-", string.Empty);

            directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "CodexSwitchTools",
                "Runtime",
                Process.GetCurrentProcess().Id + "-" + Guid.NewGuid().ToString("N"));
            WindowsIdentity identity = WindowsIdentity.GetCurrent();
            SecurityIdentifier currentUser = identity.User;
            if (currentUser == null) throw new InvalidOperationException("无法确定当前 Windows 用户 SID。");
            var security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            security.SetOwner(currentUser);
            var inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            security.AddAccessRule(new FileSystemAccessRule(currentUser, FileSystemRights.FullControl, inheritance, PropagationFlags.None, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl, inheritance, PropagationFlags.None, AccessControlType.Allow));
            Directory.CreateDirectory(directory, security);
            string path = Path.Combine(directory, "Codex-Switch-Tools.ps1");
            File.WriteAllBytes(path, data);
            return path;
        }

        private void VerifyExtractedCore()
        {
            if (!File.Exists(corePath)) throw new FileNotFoundException("临时配置核心已丢失。", corePath);
            string current;
            using (SHA256 sha = SHA256.Create())
                current = BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(corePath))).Replace("-", string.Empty);
            if (!string.Equals(current, coreHash, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("临时配置核心完整性校验失败，已拒绝执行。");
        }

        private static bool TerminateProcessTree(Process process)
        {
            try
            {
                string taskKill = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "taskkill.exe");
                using (var killer = Process.Start(new ProcessStartInfo
                {
                    FileName = taskKill,
                    Arguments = "/PID " + process.Id + " /T /F",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                }))
                {
                    if (killer != null) killer.WaitForExit(5000);
                }
                return process.WaitForExit(5000);
            }
            catch
            {
                try { process.Kill(); process.WaitForExit(3000); } catch { }
                return process.HasExited;
            }
        }

        public void Dispose()
        {
            try
            {
                if (!string.IsNullOrWhiteSpace(coreDirectory) && Directory.Exists(coreDirectory))
                    Directory.Delete(coreDirectory, true);
            }
            catch { }
        }

        private static string QuoteArgument(string value)
        {
            if (value == null) return "\"\"";
            if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return value;

            var result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char c in value)
            {
                if (c == '\\')
                {
                    slashes++;
                    continue;
                }
                if (c == '"')
                {
                    result.Append('\\', slashes * 2 + 1);
                    result.Append('"');
                    slashes = 0;
                    continue;
                }
                result.Append('\\', slashes);
                slashes = 0;
                result.Append(c);
            }
            result.Append('\\', slashes * 2);
            result.Append('"');
            return result.ToString();
        }
    }

    internal sealed class ProviderView
    {
        internal string Id = string.Empty;
        internal string Name = string.Empty;
        internal string BaseUrl = string.Empty;
        internal string EnvKey = string.Empty;
        internal bool KeyPresent;
        internal bool ProcessKeyPresent;
        internal bool UserKeyPresent;
        internal bool MachineKeyPresent;
        internal bool ProcessUserKeyConflict;
        internal bool OpenAiAuth;
        internal bool InlineSecret;
        internal bool CommandAuth;
        internal bool AdvancedConfig;

        public override string ToString()
        {
            string title = string.IsNullOrWhiteSpace(Name) ? Id : Name;
            return Id == "openai" ? "内置 OpenAI Provider" : Id + " — " + title;
        }
    }

    internal sealed class BackupView
    {
        internal string Name = string.Empty;
        internal string Operation = string.Empty;
        internal bool ContainsSecret;

        public override string ToString()
        {
            return Name + " — " + Operation + (ContainsSecret ? "  [含旧内联密钥]" : string.Empty);
        }
    }

    internal sealed class ModelView
    {
        internal string Id = string.Empty;
        internal string DisplayName = string.Empty;
        internal bool Verified;
        internal bool SupportsImages;
        internal string ContextWindow = string.Empty;
        internal string Source = string.Empty;
        internal readonly List<string> ReasoningLevels = new List<string>();

        public override string ToString()
        {
            string name = string.IsNullOrWhiteSpace(DisplayName) || DisplayName == Id ? Id : DisplayName + " — " + Id;
            return name + (!Verified ? "  [元数据未验证]" : SupportsImages ? "  [图片 + 文本]" : "  [文本]");
        }
    }

    internal sealed class ModelListSnapshot
    {
        internal string ProviderId = string.Empty;
        internal string LastModel = string.Empty;
        internal string RefreshedAt = string.Empty;
        internal readonly List<ModelView> Models = new List<ModelView>();
        internal readonly List<string> Warnings = new List<string>();

        internal static ModelListSnapshot Parse(string json)
        {
            var root = new JavaScriptSerializer().DeserializeObject(json) as Dictionary<string, object>;
            if (root == null) throw new InvalidDataException("模型列表 JSON 无法解析。");
            var result = new ModelListSnapshot
            {
                ProviderId = StatusSnapshot.GetString(root, "ProviderId"),
                LastModel = StatusSnapshot.GetString(root, "LastModel"),
                RefreshedAt = StatusSnapshot.GetString(root, "RefreshedAt")
            };
            if (string.IsNullOrWhiteSpace(result.ProviderId)) throw new InvalidDataException("模型列表缺少 Provider ID。");
            foreach (object item in StatusSnapshot.AsItems(StatusSnapshot.GetValue(root, "Models")))
            {
                var record = item as Dictionary<string, object>;
                if (record == null) continue;
                var model = new ModelView
                {
                    Id = StatusSnapshot.GetString(record, "Id"),
                    DisplayName = StatusSnapshot.GetString(record, "DisplayName"),
                    Verified = StatusSnapshot.GetBool(record, "Verified"),
                    SupportsImages = StatusSnapshot.GetBool(record, "SupportsImages"),
                    ContextWindow = StatusSnapshot.GetString(record, "ContextWindow"),
                    Source = StatusSnapshot.GetString(record, "Source")
                };
                if (string.IsNullOrWhiteSpace(model.Id) || result.Models.Any(m => m.Id == model.Id)) continue;
                foreach (object level in StatusSnapshot.AsItems(StatusSnapshot.GetValue(record, "ReasoningLevels")))
                {
                    string value = Convert.ToString(level);
                    if (!string.IsNullOrWhiteSpace(value) && !model.ReasoningLevels.Contains(value)) model.ReasoningLevels.Add(value);
                }
                result.Models.Add(model);
            }
            foreach (object item in StatusSnapshot.AsItems(StatusSnapshot.GetValue(root, "Warnings")))
                if (item != null) result.Warnings.Add(Convert.ToString(item));
            return result;
        }
    }

    internal sealed class StatusSnapshot
    {
        internal string ToolVersion = string.Empty;
        internal string ConfigPath = string.Empty;
        internal bool ConfigExists;
        internal string CodexCommand = string.Empty;
        internal string CodexVersion = string.Empty;
        internal string Provider = "openai";
        internal string Model = string.Empty;
        internal string Effort = string.Empty;
        internal string ContextWindow = string.Empty;
        internal string CompactLimit = string.Empty;
        internal bool ContextManaged;
        internal string CatalogPath = string.Empty;
        internal bool CatalogManaged;
        internal string ForcedLogin = string.Empty;
        internal string PreferredAuth = string.Empty;
        internal readonly List<ProviderView> Providers = new List<ProviderView>();
        internal readonly List<string> Warnings = new List<string>();

        internal static StatusSnapshot Parse(string json)
        {
            var serializer = new JavaScriptSerializer();
            var root = serializer.DeserializeObject(json) as Dictionary<string, object>;
            if (root == null) throw new InvalidDataException("状态 JSON 无法解析。");

            var status = new StatusSnapshot
            {
                ToolVersion = GetString(root, "ToolVersion"),
                ConfigPath = GetString(root, "ConfigPath"),
                ConfigExists = GetBool(root, "ConfigExists"),
                CodexCommand = GetString(root, "CodexCommand"),
                CodexVersion = GetString(root, "CodexVersion"),
                Provider = ValueOr(GetString(root, "ExpectedProvider"), "openai"),
                Model = GetString(root, "RequestedModel"),
                Effort = GetString(root, "ReasoningEffort"),
                ContextWindow = GetString(root, "ContextWindow"),
                CompactLimit = GetString(root, "AutoCompactLimit"),
                ContextManaged = GetBool(root, "ContextManagedByTool"),
                CatalogPath = GetString(root, "CatalogPath"),
                CatalogManaged = GetBool(root, "CatalogManagedByTool"),
                ForcedLogin = GetString(root, "ForcedLoginMethod"),
                PreferredAuth = GetString(root, "PreferredAuthMethod")
            };

            foreach (object item in AsItems(GetValue(root, "Providers")))
            {
                var provider = item as Dictionary<string, object>;
                if (provider == null) continue;
                status.Providers.Add(new ProviderView
                {
                    Id = GetString(provider, "Id"),
                    Name = GetString(provider, "Name"),
                    BaseUrl = GetString(provider, "BaseUrl"),
                    EnvKey = GetString(provider, "EnvKey"),
                    KeyPresent = GetBool(provider, "EnvKeyPresent"),
                    ProcessKeyPresent = GetBool(provider, "EnvKeyProcessPresent"),
                    UserKeyPresent = GetBool(provider, "EnvKeyUserPresent"),
                    MachineKeyPresent = GetBool(provider, "EnvKeyMachinePresent"),
                    ProcessUserKeyConflict = GetBool(provider, "EnvKeyProcessUserConflict"),
                    OpenAiAuth = string.Equals(GetString(provider, "RequiresOpenAIAuth"), "true", StringComparison.OrdinalIgnoreCase),
                    InlineSecret = GetBool(provider, "HasInlineSecret"),
                    CommandAuth = GetBool(provider, "HasCommandAuth"),
                    AdvancedConfig = GetBool(provider, "HasAdvancedRequestConfig")
                });
            }
            foreach (object item in AsItems(GetValue(root, "Warnings")))
                if (item != null) status.Warnings.Add(Convert.ToString(item));
            return status;
        }

        internal static List<BackupView> ParseBackups(string json)
        {
            var serializer = new JavaScriptSerializer();
            object parsed = serializer.DeserializeObject(json);
            var backups = new List<BackupView>();
            foreach (object item in AsItems(parsed))
            {
                var record = item as Dictionary<string, object>;
                if (record == null) continue;
                backups.Add(new BackupView
                {
                    Name = GetString(record, "Name"),
                    Operation = GetString(record, "Operation"),
                    ContainsSecret = GetBool(record, "ContainsLegacyInlineSecret")
                });
            }
            return backups;
        }

        internal static object GetValue(Dictionary<string, object> source, string key)
        {
            object value;
            return source.TryGetValue(key, out value) ? value : null;
        }

        internal static string GetString(Dictionary<string, object> source, string key)
        {
            object value = GetValue(source, key);
            return value == null ? string.Empty : Convert.ToString(value);
        }

        internal static bool GetBool(Dictionary<string, object> source, string key)
        {
            object value = GetValue(source, key);
            if (value is bool) return (bool)value;
            bool parsed;
            return value != null && bool.TryParse(Convert.ToString(value), out parsed) && parsed;
        }

        internal static IEnumerable<object> AsItems(object value)
        {
            if (value == null) yield break;
            object[] array = value as object[];
            if (array != null)
            {
                foreach (object item in array) yield return item;
                yield break;
            }
            ArrayList list = value as ArrayList;
            if (list != null)
            {
                foreach (object item in list) yield return item;
                yield break;
            }
            yield return value;
        }

        private static string ValueOr(string value, string fallback)
        {
            return string.IsNullOrWhiteSpace(value) ? fallback : value;
        }
    }

    internal sealed class PromptDialog : Form
    {
        private readonly TextBox input;

        private PromptDialog(string title, string message, bool password)
        {
            Text = title;
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ClientSize = new Size(500, 166);
            Font = new Font("Microsoft YaHei UI", 9F);

            var label = new Label { Left = 18, Top = 16, Width = 462, Height = 50, Text = message };
            input = new TextBox { Left = 18, Top = 72, Width = 462, UseSystemPasswordChar = password };
            var ok = new Button { Left = 304, Top = 116, Width = 84, Height = 32, Text = "确定", DialogResult = DialogResult.OK };
            var cancel = new Button { Left = 396, Top = 116, Width = 84, Height = 32, Text = "取消", DialogResult = DialogResult.Cancel };
            Controls.Add(label);
            Controls.Add(input);
            Controls.Add(ok);
            Controls.Add(cancel);
            AcceptButton = ok;
            CancelButton = cancel;
        }

        internal static bool Ask(IWin32Window owner, string title, string message, bool password, out string value)
        {
            using (var dialog = new PromptDialog(title, message, password))
            {
                bool accepted = dialog.ShowDialog(owner) == DialogResult.OK;
                value = accepted ? dialog.input.Text : string.Empty;
                dialog.input.Text = string.Empty;
                return accepted;
            }
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly PowerShellBridge bridge;
        private readonly string configOverride;
        private readonly bool testMode;
        private readonly List<Control> actionControls = new List<Control>();
        private bool busy;
        private bool operationValidationSkipped;
        private bool bindingModels;
        private string displayedModelProvider = string.Empty;
        private string nextRefreshProvider = string.Empty;
        private readonly Dictionary<string, ModelListSnapshot> modelLists = new Dictionary<string, ModelListSnapshot>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, string> selectedModels = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private StatusSnapshot status;

        private readonly TabControl tabs;
        private readonly Label bottomStatus;
        private readonly Button closeButton;

        private readonly Label overviewSummary;
        private readonly TextBox overviewText;

        private readonly ComboBox switchProvider;
        private readonly ComboBox switchModel;
        private readonly ComboBox switchEffort;
        private readonly CheckBox manualModelEnabled;
        private readonly TextBox manualModel;
        private readonly TextBox manualModelContext;
        private readonly Button refreshModels;
        private readonly TextBox modelInfo;
        private readonly TextBox providerId;
        private readonly TextBox providerName;
        private readonly TextBox providerUrl;
        private readonly TextBox providerEnv;
        private readonly CheckBox providerNoAuth;

        private readonly Label contextCurrent;
        private readonly Button smartContextButton;
        private readonly TextBox contextWindow;
        private readonly TextBox contextCompact;

        private readonly ComboBox keyProvider;
        private readonly TextBox keyEnv;
        private readonly TextBox keyValue;
        private readonly CheckBox overwriteKey;
        private readonly ComboBox backups;

        internal int TabCountForTest { get { return tabs.TabPages.Count; } }
        internal string[] TabTitlesForTest { get { return tabs.TabPages.Cast<TabPage>().Select(p => p.Text).ToArray(); } }

        internal static bool RunEnvironmentSynchronizationSelfTest()
        {
            string name = "CST_GUI_PROCESS_SYNC_" + Guid.NewGuid().ToString("N").ToUpperInvariant();
            string previous = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Process);
            try
            {
                Environment.SetEnvironmentVariable(name, "old", EnvironmentVariableTarget.Process);
                if (!ApplyEffectiveEnvironment(name, "new", null, false)) return false;
                if (Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Process) != "new") return false;
                if (!ApplyEffectiveEnvironment(name, null, null, false)) return false;
                return Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Process) == null;
            }
            finally
            {
                Environment.SetEnvironmentVariable(name, previous, EnvironmentVariableTarget.Process);
            }
        }

        internal bool RunModelSelectionSelfTest()
        {
            var sample = ModelListSnapshot.Parse("{\"ProviderId\":\"example\",\"LastModel\":\"example-vision\",\"Models\":[{\"Id\":\"example-text\",\"Verified\":true,\"SupportsImages\":false,\"ContextWindow\":32768,\"ReasoningLevels\":[\"low\",\"high\"]},{\"Id\":\"example-vision\",\"Verified\":true,\"SupportsImages\":true,\"ContextWindow\":65536,\"ReasoningLevels\":[\"high\",\"max\"]}],\"Warnings\":[]}");
            status = new StatusSnapshot { Provider = "example", Model = "example-text", Effort = "high" };
            bindingModels = true;
            try
            {
                FillProviderCombo(switchProvider, new[]
                {
                    new ProviderView { Id = "openai" },
                    new ProviderView { Id = "example" },
                    new ProviderView { Id = "other" }
                }, "example");
            }
            finally { bindingModels = false; }
            ApplyModelSnapshot(sample);
            if (SelectedModelId() != "example-text" || Convert.ToString(switchEffort.SelectedItem) != "high") return false;
            switchModel.SelectedItem = sample.Models[1];
            if (!SelectedModel().SupportsImages || !switchEffort.Items.Contains("max") || switchEffort.Items.Contains("low") || switchEffort.SelectedIndex != 0) return false;
            RememberSelectedModel();
            switchProvider.SelectedIndex = 2;
            ApplyModelSnapshot(ModelListSnapshot.Parse("{\"ProviderId\":\"other\",\"LastModel\":\"other-text\",\"Models\":[{\"Id\":\"other-text\",\"Verified\":true,\"ReasoningLevels\":[]}]}"));
            if (SelectedModelId() != "other-text" || switchEffort.Items.Count != 1) return false;
            RememberSelectedModel();
            switchProvider.SelectedIndex = 1;
            ApplyModelSnapshot(sample);
            if (SelectedModelId() != "example-vision") return false;
            manualModelEnabled.Checked = true;
            manualModel.Text = "unverified-new-vision";
            if (SelectedModel() != null || switchEffort.Items.Count != 1 || switchEffort.Enabled || !manualModelContext.Enabled || switchModel.Enabled) return false;
            if (modelInfo.Text.IndexOf("仅文本", StringComparison.Ordinal) < 0) return false;
            manualModelEnabled.Checked = false;
            if (SelectedModelId() != "example-vision" || !switchModel.Enabled || manualModel.Enabled) return false;
            switchProvider.SelectedIndex = 0;
            ApplyModelSnapshot(new ModelListSnapshot { ProviderId = "openai" });
            if (switchModel.Enabled || refreshModels.Enabled || manualModelEnabled.Enabled) return false;
            StatusSnapshot catalog = StatusSnapshot.Parse("{\"CatalogPath\":\"C:/catalog.json\",\"CatalogManagedByTool\":true}");
            return catalog.CatalogManaged && catalog.CatalogPath == "C:/catalog.json";
        }

        internal void RenderPreviewForTest(string path)
        {
            if (!testMode) throw new InvalidOperationException("预览仅用于隔离自测。");
            var previewStatus = new StatusSnapshot { Provider = "deepseek", Model = "deepseek-v4-flash-vision-exp", ConfigPath = "（合成预览，无真实配置）", CodexVersion = "preview" };
            previewStatus.Providers.Add(new ProviderView { Id = "deepseek", Name = "DeepSeek（合成预览）", BaseUrl = "https://api.deepseek.com", EnvKey = "DEEPSEEK_API_KEY" });
            ApplyStatus(previewStatus, "deepseek");
            ApplyModelSnapshot(ModelListSnapshot.Parse("{\"ProviderId\":\"deepseek\",\"Models\":[{\"Id\":\"deepseek-v4-pro\",\"DisplayName\":\"DeepSeek V4 Pro\",\"Verified\":true,\"ContextWindow\":1048576,\"ReasoningLevels\":[\"low\",\"high\",\"max\"],\"Source\":\"preview-fixture\"},{\"Id\":\"deepseek-v4-flash-vision-exp\",\"DisplayName\":\"DeepSeek V4 Flash Vision Exp\",\"Verified\":true,\"SupportsImages\":true,\"ContextWindow\":1048576,\"ReasoningLevels\":[\"low\",\"high\",\"max\"],\"Source\":\"preview-fixture\"}]}"));
            foreach (ModelView model in modelLists["deepseek"].Models) model.Source = "DeepSeek official Codex metadata (2026-09-02); not a live access check";
            modelLists["deepseek"].Warnings.Add("Offline presets only. Refresh /models to discover models exposed to your key; discovery does not prove Responses/tool compatibility.");
            modelLists["deepseek"].Warnings.Add("New model IDs do not reveal context, reasoning or image capabilities; unverified models require confirmation.");
            UpdateSelectedModel();
            tabs.SelectedIndex = 1;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-32000, -32000);
            Opacity = 0;
            // Off-screen, transparent creation gives all nested WinForms controls handles.
            // A hidden Form.DrawToBitmap alone otherwise produces an empty frame.
            Show();
            try
            {
                PerformLayout();
                Update();
                using (var bitmap = new Bitmap(Width, Height))
                {
                    DrawToBitmap(bitmap, new Rectangle(0, 0, Width, Height));
                    bitmap.Save(Path.GetFullPath(path), System.Drawing.Imaging.ImageFormat.Png);
                }
            }
            finally { Hide(); }
        }

        internal MainForm(PowerShellBridge powerShellBridge, string overridePath, bool isTestMode)
        {
            bridge = powerShellBridge;
            configOverride = overridePath;
            testMode = isTestMode;

            Text = "Codex 配置切换工具 v" + Assembly.GetExecutingAssembly().GetName().Version.ToString(3);
            Icon = ApplicationResources.LoadApplicationIcon();
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(900, 650);
            ClientSize = new Size(940, 680);
            Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            AutoScaleMode = AutoScaleMode.Dpi;

            var header = new Panel { Dock = DockStyle.Top, Height = 88, BackColor = Color.White };
            var title = new Label
            {
                AutoSize = true,
                Font = new Font(Font.FontFamily, 18F, FontStyle.Bold),
                Location = new Point(22, 14),
                Text = "Codex 配置切换工具"
            };
            var subtitle = new Label
            {
                AutoSize = false,
                Location = new Point(25, 52),
                Size = new Size(875, 26),
                Text = "管理 Provider、请求模型、上下文和 API 密钥。这里显示的是持久配置预计在下次启动时生效的值。"
            };
            header.Controls.Add(title);
            header.Controls.Add(subtitle);

            var footer = new Panel { Dock = DockStyle.Bottom, Height = 48, BackColor = SystemColors.ControlLight };
            bottomStatus = new Label { AutoEllipsis = true, Left = 18, Top = 15, Width = 760, Text = "准备就绪" };
            closeButton = new Button { Anchor = AnchorStyles.Top | AnchorStyles.Right, Left = 830, Top = 8, Width = 90, Height = 32, Text = "关闭" };
            closeButton.Click += delegate { Close(); };
            footer.Controls.Add(bottomStatus);
            footer.Controls.Add(closeButton);

            tabs = new TabControl { Dock = DockStyle.Fill, Padding = new Point(18, 7) };
            TabPage overviewPage = new TabPage("状态总览");
            TabPage providerPage = new TabPage("Provider 与模型");
            providerPage.AutoScroll = true;
            providerPage.AutoScrollMinSize = new Size(850, 595);
            TabPage contextPage = new TabPage("上下文窗口");
            TabPage maintenancePage = new TabPage("密钥、备份与诊断");
            tabs.TabPages.AddRange(new[] { overviewPage, providerPage, contextPage, maintenancePage });

            overviewSummary = new Label
            {
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                Left = 20,
                Top = 18,
                Width = 850,
                Height = 34,
                Font = new Font(Font.FontFamily, 12F, FontStyle.Bold),
                Text = "正在读取状态……"
            };
            overviewText = new TextBox
            {
                Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
                Left = 20,
                Top = 58,
                Width = 850,
                Height = 410,
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Vertical,
                BackColor = Color.White,
                Font = new Font("Consolas", 9F)
            };
            Button refresh = MakeButton("刷新状态", 20, 484, 130, delegate { RefreshAll(); });
            Button validate = MakeButton("校验配置", 160, 484, 130, delegate { ValidateConfig(); });
            Button openConfig = MakeButton("打开配置目录", 300, 484, 145, delegate { OpenConfigDirectory(); });
            overviewPage.Controls.AddRange(new Control[] { overviewSummary, overviewText, refresh, validate, openConfig });

            var switchGroup = new GroupBox
            {
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                Left = 18,
                Top = 14,
                Width = 855,
                Height = 246,
                Text = "切换持久 Provider 与请求模型"
            };
            switchProvider = new ComboBox { Left = 130, Top = 28, Width = 330, DropDownStyle = ComboBoxStyle.DropDownList };
            switchModel = new ComboBox { Left = 130, Top = 65, Width = 330, DropDownWidth = 690, DropDownStyle = ComboBoxStyle.DropDownList };
            switchEffort = new ComboBox { Left = 130, Top = 102, Width = 180, DropDownStyle = ComboBoxStyle.DropDownList };
            switchEffort.Items.Add("（模型默认）");
            switchEffort.SelectedIndex = 0;
            manualModelEnabled = new CheckBox { Left = 500, Top = 69, Width = 320, Text = "高级：手动输入模型 ID（通常不需要）" };
            manualModel = new TextBox { Left = 130, Top = 139, Width = 330, Enabled = false };
            manualModelContext = new TextBox { Left = 650, Top = 139, Width = 175, Enabled = false };
            modelInfo = new TextBox { Left = 24, Top = 181, Width = 801, Height = 60, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, BackColor = SystemColors.Control, TabStop = false, Text = "选择 Provider 后读取本地模型列表；联网更新请点“刷新模型列表”。" };
            switchGroup.Controls.Add(MakeLabel("Provider", 24, 32, 96));
            switchGroup.Controls.Add(MakeLabel("模型", 24, 69, 96));
            switchGroup.Controls.Add(MakeLabel("推理强度", 24, 106, 96));
            switchGroup.Controls.Add(MakeLabel("手动模型 ID", 24, 143, 104));
            switchGroup.Controls.Add(MakeLabel("未验证模型上下文", 500, 143, 148));
            switchGroup.Controls.Add(switchProvider);
            switchGroup.Controls.Add(switchModel);
            switchGroup.Controls.Add(switchEffort);
            switchGroup.Controls.AddRange(new Control[] { manualModelEnabled, manualModel, manualModelContext, modelInfo });
            refreshModels = MakeButton("刷新模型列表", 500, 23, 145, delegate { LoadProviderModels(true); });
            Button applySwitch = MakeButton("应用选择", 660, 95, 165, delegate { ApplyProviderSwitch(); });
            Button useOpenAi = MakeButton("恢复内置 OpenAI", 660, 23, 165, delegate { UseOpenAi(); });
            switchGroup.Controls.Add(refreshModels);
            switchGroup.Controls.Add(applySwitch);
            switchGroup.Controls.Add(useOpenAi);
            actionControls.AddRange(new Control[] { switchProvider, switchModel, switchEffort, manualModelEnabled, manualModel, manualModelContext });

            var defineGroup = new GroupBox
            {
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                Left = 18,
                Top = 270,
                Width = 855,
                Height = 325,
                Text = "新增或更新通用 Responses API Provider"
            };
            providerId = new TextBox { Left = 140, Top = 35, Width = 260 };
            providerName = new TextBox { Left = 560, Top = 35, Width = 260 };
            providerUrl = new TextBox { Left = 140, Top = 78, Width = 680 };
            providerEnv = new TextBox { Left = 140, Top = 121, Width = 400 };
            providerNoAuth = new CheckBox { Left = 565, Top = 123, Width = 255, Text = "此 Provider 不需要 Bearer Key" };
            var providerNote = new Label
            {
                Left = 24,
                Top = 168,
                Width = 795,
                Height = 60,
                Text = "Base URL 请照服务商文档填写，工具不会擅自增删 /v1。Provider 定义与“设为当前”分开保存；高级 headers、command auth 等配置不会被此页面覆盖。"
            };
            defineGroup.Controls.Add(MakeLabel("Provider ID", 24, 39, 105));
            defineGroup.Controls.Add(MakeLabel("显示名称", 444, 39, 105));
            defineGroup.Controls.Add(MakeLabel("Base URL", 24, 82, 105));
            defineGroup.Controls.Add(MakeLabel("密钥环境变量", 24, 125, 105));
            defineGroup.Controls.AddRange(new Control[] { providerId, providerName, providerUrl, providerEnv, providerNoAuth, providerNote });
            Button fillProvider = MakeButton("从选中项填入", 140, 245, 150, delegate { FillProviderForm(); });
            Button saveProvider = MakeButton("保存 Provider 定义", 305, 245, 180, delegate { SaveProviderDefinition(); });
            defineGroup.Controls.Add(fillProvider);
            defineGroup.Controls.Add(saveProvider);
            providerPage.Controls.Add(switchGroup);
            providerPage.Controls.Add(defineGroup);

            contextCurrent = new Label
            {
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                Left = 24,
                Top = 22,
                Width = 835,
                Height = 72,
                Font = new Font(Font.FontFamily, 11F, FontStyle.Bold),
                Text = "当前上下文：正在读取……"
            };
            var contextInfo = new Label
            {
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                Left = 24,
                Top = 102,
                Width = 835,
                Height = 70,
                Text = "自动模式仅对内置 OpenAI 模型读取本机 catalog 最大值；第三方 Provider 不会自动套用。\r\n872K/800K 是 GPT-5.6 旧预设；自动压缩阈值是工具启发式，不是官方推荐值。"
            };
            smartContextButton = MakeButton("按目录开启长上下文", 24, 190, 220, delegate { ToggleSmartContext(); });
            Button legacyContext = MakeButton("使用 872K / 800K 预设", 258, 190, 205, delegate { ApplyLegacyContext(); });
            Button resetContext = MakeButton("恢复之前 / 模型默认", 477, 190, 205, delegate { RestoreContext(); });
            var customGroup = new GroupBox { Left = 24, Top = 260, Width = 650, Height = 150, Text = "自定义上下文" };
            contextWindow = new TextBox { Left = 145, Top = 34, Width = 180 };
            contextCompact = new TextBox { Left = 145, Top = 76, Width = 180 };
            customGroup.Controls.Add(MakeLabel("上下文 tokens", 24, 38, 112));
            customGroup.Controls.Add(MakeLabel("自动压缩阈值", 24, 80, 112));
            customGroup.Controls.Add(contextWindow);
            customGroup.Controls.Add(contextCompact);
            Button applyCustom = MakeButton("应用自定义值", 375, 55, 160, delegate { ApplyCustomContext(); });
            customGroup.Controls.Add(applyCustom);
            contextPage.Controls.AddRange(new Control[] { contextCurrent, contextInfo, smartContextButton, legacyContext, resetContext, customGroup });

            var keyGroup = new GroupBox
            {
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                Left = 18,
                Top = 14,
                Width = 855,
                Height = 215,
                Text = "API 密钥与旧内联 token"
            };
            keyProvider = new ComboBox { Left = 140, Top = 31, Width = 330, DropDownStyle = ComboBoxStyle.DropDownList };
            keyProvider.SelectedIndexChanged += delegate { UpdateKeyProviderFields(); };
            keyEnv = new TextBox { Left = 140, Top = 70, Width = 330 };
            keyValue = new TextBox { Left = 140, Top = 109, Width = 330, UseSystemPasswordChar = true };
            overwriteKey = new CheckBox { Left = 500, Top = 73, Width = 305, Text = "迁移时允许覆盖已有 User 变量" };
            keyGroup.Controls.Add(MakeLabel("Provider", 24, 35, 105));
            keyGroup.Controls.Add(MakeLabel("环境变量", 24, 74, 105));
            keyGroup.Controls.Add(MakeLabel("新 API Key", 24, 113, 105));
            keyGroup.Controls.AddRange(new Control[] { keyProvider, keyEnv, keyValue, overwriteKey });
            Button saveKey = MakeButton("保存 / 更新 Key", 500, 109, 145, delegate { SaveApiKey(); });
            Button removeKey = MakeButton("删除 User Key", 660, 109, 145, delegate { RemoveApiKey(); });
            Button migrateKey = MakeButton("迁移旧内联 token", 500, 153, 305, delegate { MigrateLegacySecret(); });
            keyGroup.Controls.AddRange(new Control[] { saveKey, removeKey, migrateKey });

            var backupGroup = new GroupBox
            {
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                Left = 18,
                Top = 242,
                Width = 855,
                Height = 125,
                Text = "备份与恢复"
            };
            backups = new ComboBox { Left = 24, Top = 35, Width = 585, DropDownStyle = ComboBoxStyle.DropDownList };
            Button refreshBackups = MakeButton("刷新备份", 625, 31, 95, delegate { RefreshAll(); });
            Button restoreBackup = MakeButton("恢复选中备份", 730, 31, 110, delegate { RestoreSelectedBackup(); });
            var backupNote = new Label { Left = 24, Top = 76, Width = 815, Height = 34, Text = "恢复前会再次备份当前配置；标有“含旧内联密钥”的备份可能保存旧 token，请妥善保管。" };
            backupGroup.Controls.AddRange(new Control[] { backups, refreshBackups, restoreBackup, backupNote });

            var diagnosticGroup = new GroupBox
            {
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                Left = 18,
                Top = 380,
                Width = 855,
                Height = 140,
                Text = "高级诊断与快捷方式"
            };
            Button validate2 = MakeButton("离线校验配置", 24, 42, 145, delegate { ValidateConfig(); });
            Button probe = MakeButton("直接 Responses 探测", 184, 42, 175, delegate { DirectProbe(); });
            Button shortcut = MakeButton("创建中文桌面快捷方式", 374, 42, 205, delegate { CreateDesktopShortcut(); });
            Button openBackup = MakeButton("打开备份目录", 594, 42, 145, delegate { OpenBackupDirectory(); });
            var diagnosticNote = new Label { Left = 24, Top = 89, Width = 805, Height = 35, Text = "直接探测会发送一个 tools=[] 的小请求，可能计费；只支持简单 env_key / 无认证 Responses Provider。" };
            diagnosticGroup.Controls.AddRange(new Control[] { validate2, probe, shortcut, openBackup, diagnosticNote });
            maintenancePage.Controls.AddRange(new Control[] { keyGroup, backupGroup, diagnosticGroup });

            Controls.Add(tabs);
            Controls.Add(header);
            Controls.Add(footer);

            switchProvider.SelectedIndexChanged += delegate
            {
                if (bindingModels || busy) return;
                RememberSelectedModel();
                if (!testMode) LoadProviderModels(false);
            };
            switchModel.SelectedIndexChanged += delegate { if (!bindingModels) UpdateSelectedModel(); };
            manualModelEnabled.CheckedChanged += delegate
            {
                if (bindingModels) return;
                ModelView selected = switchModel.SelectedItem as ModelView;
                if (manualModelEnabled.Checked && selected != null) manualModel.Text = selected.Id;
                UpdateSelectedModel();
            };
            manualModel.TextChanged += delegate { if (!bindingModels && manualModelEnabled.Checked) UpdateSelectedModel(); };
            UpdateModelControls();

            FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                if (!busy || e.CloseReason != CloseReason.UserClosing) return;
                e.Cancel = true;
                MessageBox.Show(this, "配置操作正在进行，请等待完成后再关闭。", "请稍候", MessageBoxButtons.OK, MessageBoxIcon.Information);
            };
            if (!testMode) Shown += delegate { RefreshAll(); };
        }

        private static Label MakeLabel(string text, int left, int top, int width)
        {
            return new Label { Left = left, Top = top, Width = width, Height = 25, Text = text };
        }

        private Button MakeButton(string text, int left, int top, int width, EventHandler handler)
        {
            var button = new Button { Left = left, Top = top, Width = width, Height = 38, Text = text };
            button.Click += handler;
            actionControls.Add(button);
            return button;
        }

        private List<string> Args(string action)
        {
            return new List<string> { "-Action", action };
        }

        private void RefreshAll()
        {
            if (busy) return;
            RememberSelectedModel();
            string desiredProvider = string.IsNullOrWhiteSpace(nextRefreshProvider) ? SelectedProviderId(switchProvider) : nextRefreshProvider;
            nextRefreshProvider = string.Empty;
            SetBusy(true, "正在读取持久配置……");
            var worker = new BackgroundWorker();
            worker.DoWork += delegate(object sender, DoWorkEventArgs e)
            {
                CommandResult statusResult = bridge.Run(Args("Status").Concat(new[] { "-Json" }), null);
                if (!statusResult.Success) throw new InvalidOperationException(statusResult.CombinedOutput);
                StatusSnapshot snapshot = StatusSnapshot.Parse(statusResult.StandardOutput);

                CommandResult backupResult = bridge.Run(Args("ListBackups").Concat(new[] { "-Json" }), null);
                if (!backupResult.Success) throw new InvalidOperationException(backupResult.CombinedOutput);
                string provider = desiredProvider;
                if (string.IsNullOrWhiteSpace(provider) || (provider != "openai" && !snapshot.Providers.Any(p => string.Equals(p.Id, provider, StringComparison.OrdinalIgnoreCase)))) provider = snapshot.Provider;
                CommandResult modelsResult = bridge.Run(Args("ListModels").Concat(new[] { "-ProviderId", provider, "-Json" }), null);
                ModelListSnapshot models = null;
                string modelError = modelsResult.Success ? string.Empty : modelsResult.CombinedOutput;
                if (modelsResult.Success)
                {
                    try { models = ModelListSnapshot.Parse(modelsResult.StandardOutput); }
                    catch (Exception ex) { modelError = ex.Message; }
                }
                e.Result = new object[] { snapshot, StatusSnapshot.ParseBackups(backupResult.StandardOutput), provider, models, modelError };
            };
            worker.RunWorkerCompleted += delegate(object sender, RunWorkerCompletedEventArgs e)
            {
                if (IsDisposed) return;
                SetBusy(false, "准备就绪");
                if (e.Error != null)
                {
                    ShowError("读取状态失败", e.Error.Message);
                    return;
                }
                object[] result = (object[])e.Result;
                try
                {
                    ApplyStatus((StatusSnapshot)result[0], (string)result[2]);
                    ApplyBackups((List<BackupView>)result[1]);
                    ModelListSnapshot models = result[3] as ModelListSnapshot;
                    if (models != null) ApplyModelSnapshot(models);
                    else
                    {
                        BindCachedModels((string)result[2]);
                        modelInfo.Text = "模型列表读取失败；保留本地旧列表，可重试或使用高级手动 ID。\r\n" + Convert.ToString(result[4]);
                    }
                }
                catch (Exception bindError) { ShowError("状态显示失败", bindError.Message); }
            };
            worker.RunWorkerAsync();
        }

        private void RunAction(string label, IEnumerable<string> arguments, string standardInput, bool refreshAfter, Action<CommandResult> success)
        {
            if (busy) return;
            SetBusy(true, label);
            var worker = new BackgroundWorker();
            worker.DoWork += delegate(object sender, DoWorkEventArgs e) { e.Result = bridge.Run(arguments, standardInput); };
            worker.RunWorkerCompleted += delegate(object sender, RunWorkerCompletedEventArgs e)
            {
                if (IsDisposed) return;
                SetBusy(false, "准备就绪");
                if (e.Error != null)
                {
                    ShowError("操作失败", e.Error.Message);
                    return;
                }
                CommandResult result = (CommandResult)e.Result;
                if (!result.Success)
                {
                    ShowError("操作失败", result.CombinedOutput);
                    return;
                }
                try
                {
                    operationValidationSkipped = result.StandardOutput.IndexOf("Validation:", StringComparison.OrdinalIgnoreCase) >= 0 &&
                                                 result.StandardOutput.IndexOf("skipped", StringComparison.OrdinalIgnoreCase) >= 0;
                    if (success != null) success(result);
                }
                catch (Exception callbackError)
                {
                    MessageBox.Show(this, "核心操作已经成功，但 GUI 后处理/环境同步失败：\r\n\r\n" + callbackError.Message + "\r\n\r\n请关闭并重新打开本工具，然后刷新状态。", "操作成功但界面同步失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
                finally { operationValidationSkipped = false; }
                if (refreshAfter)
                {
                    try { RefreshAll(); }
                    catch (Exception refreshError) { ShowError("刷新失败", "核心操作已完成，但状态刷新失败：\r\n" + refreshError.Message); }
                }
            };
            worker.RunWorkerAsync();
        }

        private void ApplyStatus(StatusSnapshot snapshot, string desiredProvider)
        {
            if (status != null)
            {
                foreach (ProviderView previous in status.Providers)
                {
                    ProviderView current = snapshot.Providers.FirstOrDefault(p => string.Equals(p.Id, previous.Id, StringComparison.OrdinalIgnoreCase));
                    if (current == null || !string.Equals(current.BaseUrl, previous.BaseUrl, StringComparison.Ordinal))
                    {
                        modelLists.Remove(previous.Id);
                        selectedModels.Remove(previous.Id);
                    }
                }
            }
            status = snapshot;
            string model = string.IsNullOrWhiteSpace(status.Model) ? "UI / 模型默认" : status.Model;
            overviewSummary.Text = "预计下次启动：" + status.Provider + "  /  " + model;
            bottomStatus.Text = "配置：" + status.ConfigPath + "    Provider：" + status.Provider + "    模型：" + model;

            var sb = new StringBuilder();
            sb.AppendLine("持久配置预计下次启动生效（不是服务端最终模型证明）");
            sb.AppendLine();
            sb.AppendLine("配置文件     : " + status.ConfigPath);
            sb.AppendLine("配置存在     : " + (status.ConfigExists ? "是" : "否"));
            sb.AppendLine("Codex 版本   : " + ValueOr(status.CodexVersion, "未找到"));
            sb.AppendLine("Provider     : " + status.Provider);
            sb.AppendLine("请求模型     : " + model);
            sb.AppendLine("推理强度     : " + ValueOr(status.Effort, "模型默认"));
            sb.AppendLine("上下文       : " + ValueOr(status.ContextWindow, "模型默认"));
            sb.AppendLine("自动压缩     : " + ValueOr(status.CompactLimit, "模型默认"));
            sb.AppendLine("工具管理上下文: " + (status.ContextManaged ? "是" : "否"));
            sb.AppendLine("模型目录     : " + ValueOr(status.CatalogPath, "Codex 原生目录"));
            sb.AppendLine("工具管理目录 : " + (status.CatalogManaged ? "是" : "否"));
            sb.AppendLine("强制登录方式 : " + ValueOr(status.ForcedLogin, "未强制"));
            sb.AppendLine("偏好认证方式 : " + ValueOr(status.PreferredAuth, "Codex 默认"));
            sb.AppendLine();
            sb.AppendLine("自定义 Provider：");
            if (status.Providers.Count == 0) sb.AppendLine("  （无）");
            foreach (ProviderView provider in status.Providers)
            {
                string key;
                if (string.IsNullOrWhiteSpace(provider.EnvKey)) key = "无 env_key";
                else if (provider.UserKeyPresent) key = provider.EnvKey + " User 已保存";
                else if (provider.MachineKeyPresent) key = provider.EnvKey + " 仅 Machine 可见";
                else if (provider.ProcessKeyPresent) key = provider.EnvKey + " 仅当前进程可见";
                else key = provider.EnvKey + " 缺失";
                sb.AppendLine("  " + provider.Id + " | " + provider.BaseUrl + " | " + key);
                if (provider.ProcessUserKeyConflict) sb.AppendLine("    警告：Process 与 User Key 不一致，可能仍在使用旧值");
                if (provider.InlineSecret) sb.AppendLine("    警告：检测到旧内联 token（值已隐藏）");
                if (provider.CommandAuth || provider.AdvancedConfig) sb.AppendLine("    高级认证/请求配置：GUI 只读展示，不会覆盖");
            }
            if (status.Warnings.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine("警告：");
                foreach (string warning in status.Warnings) sb.AppendLine("  - " + warning);
            }
            overviewText.Text = sb.ToString();

            string selectedKey = SelectedProviderId(keyProvider);
            var allProviders = new List<ProviderView> { new ProviderView { Id = "openai", Name = "内置 OpenAI" } };
            allProviders.AddRange(status.Providers);
            bindingModels = true;
            try { FillProviderCombo(switchProvider, allProviders, string.IsNullOrWhiteSpace(desiredProvider) ? status.Provider : desiredProvider); }
            finally { bindingModels = false; }
            FillProviderCombo(keyProvider, status.Providers, selectedKey);
            contextCurrent.Text = string.Format(
                "当前 Provider：{0}    模型：{1}\r\n上下文：{2}    自动压缩：{3}    工具管理：{4}",
                status.Provider,
                model,
                ValueOr(status.ContextWindow, "模型默认"),
                ValueOr(status.CompactLimit, "模型默认"),
                status.ContextManaged ? "是" : "否");
            if (status.ContextManaged)
                smartContextButton.Text = "关闭并恢复启用前设置";
            else if (status.ContextWindow == "872000" && status.CompactLimit == "800000")
                smartContextButton.Text = "关闭旧 872K 覆盖";
            else
                smartContextButton.Text = "按目录开启长上下文";
            UpdateKeyProviderFields();
        }

        private void ApplyBackups(List<BackupView> records)
        {
            string selected = backups.SelectedItem is BackupView ? ((BackupView)backups.SelectedItem).Name : string.Empty;
            backups.BeginUpdate();
            backups.Items.Clear();
            foreach (BackupView record in records) backups.Items.Add(record);
            backups.EndUpdate();
            SelectBackup(selected);
            if (backups.SelectedIndex < 0 && backups.Items.Count > 0) backups.SelectedIndex = 0;
        }

        private void FillProviderCombo(ComboBox combo, IEnumerable<ProviderView> providers, string selectedId)
        {
            combo.BeginUpdate();
            combo.Items.Clear();
            foreach (ProviderView provider in providers) combo.Items.Add(provider);
            combo.EndUpdate();
            for (int i = 0; i < combo.Items.Count; i++)
            {
                ProviderView item = (ProviderView)combo.Items[i];
                if (string.Equals(item.Id, selectedId, StringComparison.OrdinalIgnoreCase))
                {
                    combo.SelectedIndex = i;
                    return;
                }
            }
            if (combo.Items.Count > 0) combo.SelectedIndex = 0;
        }

        private static string SelectedProviderId(ComboBox combo)
        {
            ProviderView selected = combo.SelectedItem as ProviderView;
            return selected == null ? string.Empty : selected.Id;
        }

        private void SelectEffort(string effort)
        {
            if (string.IsNullOrWhiteSpace(effort)) { switchEffort.SelectedIndex = 0; return; }
            for (int i = 1; i < switchEffort.Items.Count; i++)
                if (string.Equals(Convert.ToString(switchEffort.Items[i]), effort, StringComparison.OrdinalIgnoreCase)) { switchEffort.SelectedIndex = i; return; }
            switchEffort.SelectedIndex = 0;
        }

        private string SelectedModelId()
        {
            if (manualModelEnabled.Checked) return manualModel.Text.Trim();
            ModelView selected = switchModel.SelectedItem as ModelView;
            return selected == null ? string.Empty : selected.Id;
        }

        private ModelView SelectedModel()
        {
            string id = SelectedModelId();
            ModelListSnapshot list;
            if (modelLists.TryGetValue(SelectedProviderId(switchProvider), out list))
                return list.Models.FirstOrDefault(m => string.Equals(m.Id, id, StringComparison.Ordinal));
            return null;
        }

        private void RememberSelectedModel()
        {
            string id = SelectedModelId();
            if (!string.IsNullOrWhiteSpace(displayedModelProvider) && !string.IsNullOrWhiteSpace(id)) selectedModels[displayedModelProvider] = id;
        }

        private void BindCachedModels(string providerId)
        {
            ModelListSnapshot cached;
            if (!modelLists.TryGetValue(providerId, out cached)) cached = new ModelListSnapshot { ProviderId = providerId };
            ApplyModelSnapshot(cached);
        }

        private void ApplyModelSnapshot(ModelListSnapshot snapshot)
        {
            string providerId = SelectedProviderId(switchProvider);
            if (!string.Equals(snapshot.ProviderId, providerId, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("模型列表所属 Provider 与当前选择不一致，已拒绝显示。");
            modelLists[providerId] = snapshot;
            string desired;
            if (!selectedModels.TryGetValue(providerId, out desired))
                desired = status != null && string.Equals(status.Provider, providerId, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(status.Model)
                    ? status.Model : snapshot.LastModel;
            if (!string.IsNullOrWhiteSpace(desired) && !snapshot.Models.Any(m => m.Id == desired))
                snapshot.Models.Add(new ModelView { Id = desired, DisplayName = desired, ContextWindow = "32768", Source = "previous-selection" });
            bindingModels = true;
            try
            {
                displayedModelProvider = providerId;
                switchModel.BeginUpdate();
                switchModel.Items.Clear();
                foreach (ModelView model in snapshot.Models) switchModel.Items.Add(model);
                switchModel.EndUpdate();
                ModelView chosen = snapshot.Models.FirstOrDefault(m => m.Id == desired)
                    ?? snapshot.Models.FirstOrDefault(m => m.Verified) ?? snapshot.Models.FirstOrDefault();
                if (chosen != null) switchModel.SelectedItem = chosen;
                manualModelEnabled.Checked = false;
                manualModel.Text = chosen == null ? string.Empty : chosen.Id;
                manualModelContext.Clear();
            }
            finally { bindingModels = false; }
            UpdateSelectedModel();
        }

        private void UpdateSelectedModel()
        {
            ModelView model = SelectedModel();
            string provider = SelectedProviderId(switchProvider);
            switchEffort.BeginUpdate();
            switchEffort.Items.Clear();
            switchEffort.Items.Add("（模型默认）");
            if (model != null && model.Verified)
                foreach (string level in model.ReasoningLevels) switchEffort.Items.Add(level);
            switchEffort.SelectedIndex = 0;
            switchEffort.EndUpdate();
            if (model != null && status != null && string.Equals(status.Provider, provider, StringComparison.OrdinalIgnoreCase) && status.Model == model.Id)
                SelectEffort(status.Effort);

            if (provider == "openai")
                modelInfo.Text = "内置 OpenAI：点“恢复内置 OpenAI”后，在 Codex 自己的模型菜单中选择。\r\n本工具不接管 OpenAI 模型目录；切回时恢复接管前目录与上下文，登录方式不变。";
            else
            {
                ModelListSnapshot list;
                modelLists.TryGetValue(provider, out list);
                string fallbackContext = model == null || string.IsNullOrWhiteSpace(model.ContextWindow) ? "32768" : model.ContextWindow;
                string detail = model == null || !model.Verified
                    ? "模型元数据未验证：仅文本；当前上下文 " + fallbackContext + " tokens（已保存值或保守默认）；可在高级设置指定。"
                    : (model.SupportsImages ? "支持图片 + 文本" : "仅文本") + "；上下文：" + ValueOr(model.ContextWindow, "未提供") + " tokens；来源：" + ValueOr(model.Source, "已验证目录");
                string refreshed = list == null || string.IsNullOrWhiteSpace(list.RefreshedAt) ? "本地内置/缓存列表" : "上次联网刷新：" + list.RefreshedAt;
                string warning = list != null && list.Warnings.Count > 0 ? "\r\n提示：" + string.Join("\r\n", list.Warnings.ToArray()) : string.Empty;
                modelInfo.Text = detail + "\r\n" + refreshed + "。刷新只获取模型名单，不发送对话。" + warning;
            }
            UpdateModelControls();
        }

        private void UpdateModelControls()
        {
            bool custom = !string.IsNullOrWhiteSpace(SelectedProviderId(switchProvider)) && SelectedProviderId(switchProvider) != "openai";
            ModelView selected = SelectedModel();
            switchModel.Enabled = !busy && custom && !manualModelEnabled.Checked;
            manualModelEnabled.Enabled = !busy && custom;
            manualModel.Enabled = !busy && custom && manualModelEnabled.Checked;
            manualModelContext.Enabled = !busy && custom && manualModelEnabled.Checked && (selected == null || !selected.Verified);
            switchEffort.Enabled = !busy && custom && selected != null && selected.Verified && switchEffort.Items.Count > 1;
            refreshModels.Enabled = !busy && custom;
        }

        private void LoadProviderModels(bool refresh)
        {
            if (busy) return;
            ProviderView provider = switchProvider.SelectedItem as ProviderView;
            if (provider == null) return;
            RememberSelectedModel();
            if (refresh)
            {
                if (provider.Id == "openai") return;
                string message = "将向以下 Provider 获取可用模型列表：\r\n\r\n" + provider.Id + "\r\nBase URL：" + provider.BaseUrl +
                    "\r\n\r\n只调用 GET /models，不发送对话、图片或生成请求。若该 Provider 使用 API Key，请求会携带对应 Key；请确认网址可信。服务商可能有自己的接口访问规则。\r\n\r\n刷新失败会保留旧列表。是否继续？";
                if (MessageBox.Show(this, message, "确认联网刷新模型", MessageBoxButtons.YesNo, MessageBoxIcon.Information, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
                if (provider.ProcessUserKeyConflict)
                {
                    if (MessageBox.Show(this, "当前进程与 User 保存的 API Key 不一致。是否先同步为 User 值再刷新？", "检测到旧 Key 冲突", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
                    if (!SynchronizeProcessEnvironment(provider.EnvKey))
                        MessageBox.Show(this, "本工具当前进程已同步 Key，但 Windows 广播失败。之后请完全重启启动器与 Codex。", "系统广播失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
            BindCachedModels(provider.Id);
            var args = Args(refresh ? "RefreshModels" : "ListModels");
            args.AddRange(new[] { "-ProviderId", provider.Id, "-Json" });
            if (refresh) args.Add("-ConfirmModelRefresh");
            SetBusy(true, refresh ? "正在联网刷新模型名单……" : "正在读取本地模型名单……");
            var worker = new BackgroundWorker();
            worker.DoWork += delegate(object sender, DoWorkEventArgs e)
            {
                CommandResult result = bridge.Run(args, null);
                if (!result.Success) throw new InvalidOperationException(result.CombinedOutput);
                e.Result = ModelListSnapshot.Parse(result.StandardOutput);
            };
            worker.RunWorkerCompleted += delegate(object sender, RunWorkerCompletedEventArgs e)
            {
                if (IsDisposed) return;
                SetBusy(false, "准备就绪");
                if (e.Error != null)
                {
                    modelInfo.Text = "模型列表读取失败；已保留此 Provider 的旧列表，可重试或使用高级手动 ID。";
                    ShowError("模型列表读取失败", e.Error.Message + "\r\n\r\n此前模型列表与 Codex 配置均未由本次读取替换。");
                    return;
                }
                try
                {
                    ApplyModelSnapshot((ModelListSnapshot)e.Result);
                    if (refresh)
                    {
                        ModelListSnapshot result = (ModelListSnapshot)e.Result;
                        string warnings = result.Warnings.Count > 0 ? "\r\n\r\n" + string.Join("\r\n", result.Warnings.ToArray()) : string.Empty;
                        ShowSuccess("模型名单已刷新", "已获取 " + result.Models.Count + " 个模型。请选择所需模型并点“应用选择”，然后完全重启 Codex，更新才会应用到原生模型目录。" + warnings);
                    }
                }
                catch (Exception ex) { ShowError("模型列表显示失败", ex.Message); }
            };
            worker.RunWorkerAsync();
        }

        private void SelectBackup(string name)
        {
            for (int i = 0; i < backups.Items.Count; i++)
                if (string.Equals(((BackupView)backups.Items[i]).Name, name, StringComparison.Ordinal)) { backups.SelectedIndex = i; return; }
        }

        private void ApplyProviderSwitch()
        {
            ProviderView provider = switchProvider.SelectedItem as ProviderView;
            if (provider == null) { ShowError("缺少选择", "请先选择 Provider。"); return; }
            if (provider.Id == "openai") { UseOpenAi(); return; }
            string modelId = SelectedModelId();
            if (string.IsNullOrWhiteSpace(modelId)) { ShowError("缺少模型", "请先选择模型；列表为空时可刷新，或启用高级手动 ID。"); return; }
            ModelView model = SelectedModel();
            bool unverified = model == null || !model.Verified;
            long customContext = 0;
            if (unverified && manualModelEnabled.Checked && !string.IsNullOrWhiteSpace(manualModelContext.Text) &&
                (!long.TryParse(manualModelContext.Text.Trim(), out customContext) || customContext < 1024 || customContext > 10000000))
            {
                ShowError("上下文无效", "未验证模型的上下文必须是 1024 至 10000000 的整数 tokens；留空使用已保存值，未保存过则默认 32768。");
                return;
            }
            if (unverified && customContext == 0 &&
                (model == null || !long.TryParse(model.ContextWindow, out customContext) || customContext < 1024 || customContext > 10000000)) customContext = 32768;
            var warnings = new List<string>();
            if (!string.IsNullOrWhiteSpace(provider.EnvKey) && !provider.KeyPresent)
                warnings.Add("API Key 环境变量 “" + provider.EnvKey + "” 当前不可见，切换后可能无法请求。");
            if (warnings.Count > 0)
            {
                string message = string.Join("\r\n", warnings.ToArray()) + "\r\n\r\n仍要继续切换吗？";
                if (MessageBox.Show(this, message, "切换前警告", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            }
            if (unverified)
            {
                string fallbackContext = model == null || string.IsNullOrWhiteSpace(model.ContextWindow) ? "32768" : model.ContextWindow;
                string warning = "模型 “" + modelId + "” 的能力元数据尚未验证。仅知道模型名不能证明其支持图片、工具调用或大上下文。\r\n\r\n本次按仅文本配置；上下文：" + (customContext > 0 ? customContext.ToString() : fallbackContext + "（已保存值或保守默认）") + " tokens。不会自动开启图片输入或推理档位。请确认此 ID 确实属于目标 Provider。\r\n\r\n仍要继续吗？";
                if (MessageBox.Show(this, warning, "确认使用未验证模型", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            }
            bool replaceCatalog = status != null && !string.IsNullOrWhiteSpace(status.CatalogPath) && !status.CatalogManaged;
            if (replaceCatalog && MessageBox.Show(this, "检测到非本工具管理的模型目录：\r\n" + status.CatalogPath + "\r\n\r\n本次切换将暂时接管 model_catalog_json 并保留原设置；切回 OpenAI 时恢复。原目录文件不会被覆盖。\r\n\r\n是否允许接管？", "确认接管现有模型目录", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            var args = Args("SetProvider");
            args.AddRange(new[] { "-ProviderId", provider.Id, "-Model", modelId, "-ManageModelCatalog" });
            if (unverified) args.Add("-AllowUnverifiedModel");
            if (customContext > 0) args.AddRange(new[] { "-ContextWindow", customContext.ToString() });
            if (replaceCatalog) args.Add("-ReplaceExistingCatalog");
            if (switchEffort.SelectedIndex > 0) args.AddRange(new[] { "-ReasoningEffort", Convert.ToString(switchEffort.SelectedItem) });
            RunAction("正在切换 Provider、模型与独立目录……", args, null, true, delegate
            {
                selectedModels[provider.Id] = modelId;
                nextRefreshProvider = provider.Id;
                ShowSuccess("切换成功", "持久配置与 Provider 独立模型目录已更新。请完全退出并重启 Codex / VS Code，目录不会在当前运行进程里热更新。\r\n\r\nWindows 版 Codex 仍可能显示“自定义 / Custom”；该标签不等于切换失败。不要在第三方 Provider 下选择未受其支持的 GPT 模型。旧任务也可能保留自己的模型设置，请核对后再继续。");
            });
        }

        private void UseOpenAi()
        {
            if (MessageBox.Show(this, "将切换到内置 OpenAI Provider，移除第三方模型/推理强度覆盖；若模型目录由本工具接管，将恢复接管前的目录与上下文。登录方式不变。\r\n\r\n是否继续？", "恢复内置 OpenAI", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            RunAction("正在恢复内置 OpenAI……", Args("UseOpenAI"), null, true, delegate
            {
                nextRefreshProvider = "openai";
                ShowSuccess("操作成功", "已选择内置 OpenAI Provider。请完全退出并重启 Codex，再在其原生模型菜单选择。登录方式未被修改。");
            });
        }

        private void FillProviderForm()
        {
            ProviderView provider = switchProvider.SelectedItem as ProviderView;
            if (provider == null || provider.Id == "openai") return;
            if (provider.CommandAuth || provider.AdvancedConfig || provider.OpenAiAuth || provider.InlineSecret)
            {
                ShowError("高级 Provider 只读", "该 Provider 使用高级认证、headers/query 参数或旧内联 token。为防止静默改变认证语义，GUI 不允许把它载入通用编辑表单。可继续将它设为当前，或先使用专门的密钥迁移功能。");
                return;
            }
            providerId.Text = provider.Id;
            providerName.Text = provider.Name;
            providerUrl.Text = provider.BaseUrl;
            providerEnv.Text = provider.EnvKey;
            providerNoAuth.Checked = string.IsNullOrWhiteSpace(provider.EnvKey);
        }

        private void SaveProviderDefinition()
        {
            if (string.IsNullOrWhiteSpace(providerId.Text) || string.IsNullOrWhiteSpace(providerUrl.Text))
            {
                ShowError("信息不完整", "Provider ID 和 Base URL 必填。");
                return;
            }
            if (!providerNoAuth.Checked && string.IsNullOrWhiteSpace(providerEnv.Text))
            {
                ShowError("信息不完整", "需要认证时必须填写密钥环境变量名。");
                return;
            }
            ProviderView existing = status == null
                ? null
                : status.Providers.FirstOrDefault(p => string.Equals(p.Id, providerId.Text.Trim(), StringComparison.OrdinalIgnoreCase));
            if (existing != null && (existing.CommandAuth || existing.AdvancedConfig || existing.OpenAiAuth || existing.InlineSecret))
            {
                ShowError("高级 Provider 只读", "该 ID 已用于高级认证、headers/query 参数或旧内联 token。为防止改变认证语义，通用表单拒绝覆盖它。");
                return;
            }
            var args = Args("ConfigureProvider");
            args.AddRange(new[] { "-ProviderId", providerId.Text.Trim(), "-ProviderName", providerName.Text.Trim(), "-BaseUrl", providerUrl.Text.Trim() });
            if (providerNoAuth.Checked) args.Add("-NoAuth");
            else args.AddRange(new[] { "-EnvKey", providerEnv.Text.Trim() });
            RunAction("正在保存 Provider 定义……", args, null, true, delegate { ShowSuccess("保存成功", "Provider 定义已写入用户级配置；尚未自动设为当前 Provider。"); });
        }

        private void ToggleSmartContext()
        {
            var args = Args("ToggleLongContext");
            if (status != null && !status.ContextManaged && status.ContextWindow == "872000" && status.CompactLimit == "800000")
            {
                if (MessageBox.Show(this, "检测到旧工具留下的 872K / 800K 覆盖，但没有可恢复标记。继续会移除这两个覆盖并回到模型默认。\r\n\r\n是否继续？", "关闭旧长上下文覆盖", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
                args.Add("-ForceRemoveUnmanagedContext");
            }
            RunAction("正在切换智能长上下文……", args, null, true, delegate { ShowSuccess("操作成功", "上下文设置已更新。请重启 Codex 后生效。"); });
        }

        private void ApplyLegacyContext()
        {
            if (MessageBox.Show(this, "872K / 800K 是 GPT-5.6 的旧预设。第三方 Provider 或其他模型未必支持。\r\n\r\n确认应用？", "确认旧预设", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            var args = Args("SetContext");
            args.AddRange(new[] { "-ContextWindow", "872000", "-AutoCompactLimit", "800000" });
            RunAction("正在应用 872K 预设……", args, null, true, delegate { ShowSuccess("操作成功", "已写入 872K / 800K 上下文预设。"); });
        }

        private void RestoreContext()
        {
            var args = Args("ResetContext");
            if (status != null && !status.ContextManaged && (!string.IsNullOrWhiteSpace(status.ContextWindow) || !string.IsNullOrWhiteSpace(status.CompactLimit)))
            {
                string answer;
                if (!PromptDialog.Ask(this, "删除手工上下文覆盖", "这些值没有工具所有权标记。输入 REMOVE 才会删除手工覆盖：", false, out answer) || answer != "REMOVE") return;
                args.Add("-ForceRemoveUnmanagedContext");
            }
            RunAction("正在恢复上下文设置……", args, null, true, delegate { ShowSuccess("操作成功", "已恢复启用前的值，或回到模型默认。"); });
        }

        private void ApplyCustomContext()
        {
            long window;
            long compact;
            if (!long.TryParse(contextWindow.Text.Replace("_", string.Empty), out window) || !long.TryParse(contextCompact.Text.Replace("_", string.Empty), out compact) || window <= 0 || compact <= 0 || compact >= window)
            {
                ShowError("数值无效", "上下文和压缩阈值必须是正整数，且压缩阈值必须小于上下文窗口。");
                return;
            }
            var args = Args("SetContext");
            args.AddRange(new[] { "-ContextWindow", window.ToString(), "-AutoCompactLimit", compact.ToString() });
            RunAction("正在应用自定义上下文……", args, null, true, delegate { ShowSuccess("操作成功", "自定义上下文已保存。"); });
        }

        private void UpdateKeyProviderFields()
        {
            keyValue.Clear();
            keyValue.ClearUndo();
            overwriteKey.Checked = false;
            ProviderView provider = keyProvider.SelectedItem as ProviderView;
            if (provider == null) return;
            keyEnv.Text = provider.EnvKey;
        }

        private void SaveApiKey()
        {
            string env = keyEnv.Text.Trim();
            string secret = keyValue.Text;
            if (env.Length == 0 || secret.Length == 0) { ShowError("信息不完整", "请填写环境变量名和 API Key。"); return; }
            bool allowOverwrite = false;
            string existingUser = Environment.GetEnvironmentVariable(env, EnvironmentVariableTarget.User);
            if (!string.IsNullOrWhiteSpace(existingUser) && !string.Equals(existingUser, secret, StringComparison.Ordinal))
            {
                string confirmation;
                if (!PromptDialog.Ask(this, "覆盖已有 User API Key", "环境变量已有不同值，且环境变量不在配置备份中。输入完整变量名确认覆盖：\r\n" + env, false, out confirmation) || confirmation != env) return;
                allowOverwrite = true;
            }
            var args = Args("SetApiKey");
            args.AddRange(new[] { "-EnvKey", env, "-ReadSecretFromStdin" });
            if (allowOverwrite) args.Add("-ForceOverwriteApiKey");
            keyValue.Clear();
            keyValue.ClearUndo();
            RunAction("正在安全保存 API Key……", args, secret, true, delegate
            {
                ShowEnvironmentOperationSuccess(env, "保存成功", "Key 已保存为当前 Windows 用户环境变量，值不会显示。GUI 已同步当前进程环境；仍需重启 Codex。");
            });
            secret = string.Empty;
        }

        private void RemoveApiKey()
        {
            string env = keyEnv.Text.Trim();
            if (env.Length == 0) { ShowError("缺少变量名", "请先选择 Provider 或填写环境变量名。"); return; }
            string sharedWarning = string.Empty;
            if (status != null)
            {
                string[] references = status.Providers
                    .Where(p => string.Equals(p.EnvKey, env, StringComparison.OrdinalIgnoreCase))
                    .Select(p => p.Id)
                    .ToArray();
                if (references.Length > 1)
                    sharedWarning = "\r\n\r\n警告：该变量同时被这些 Provider 引用：" + string.Join(", ", references);
            }
            string answer;
            if (!PromptDialog.Ask(this, "删除 User API Key", "环境变量不在配置备份中。输入完整变量名确认删除：\r\n" + env + sharedWarning, false, out answer) || answer != env) return;
            var args = Args("RemoveApiKey");
            args.AddRange(new[] { "-EnvKey", env, "-ForceRemoveApiKey" });
            RunAction("正在删除 API Key……", args, null, true, delegate
            {
                ShowEnvironmentOperationSuccess(env, "删除成功", "User 级环境变量已删除，GUI 当前进程已同步。请重启 Codex。");
            });
        }

        private void MigrateLegacySecret()
        {
            ProviderView provider = keyProvider.SelectedItem as ProviderView;
            if (provider == null) { ShowError("缺少选择", "请选择包含旧内联 token 的 Provider。"); return; }
            string env = keyEnv.Text.Trim();
            if (env.Length == 0) env = "CODEX_" + provider.Id.ToUpperInvariant().Replace('-', '_') + "_API_KEY";
            string overwriteWarning = overwriteKey.Checked
                ? "\r\n\r\n你已允许覆盖已有 User 变量；该旧值不在配置备份中，覆盖后无法由本工具恢复。"
                : string.Empty;
            if (overwriteKey.Checked)
            {
                string overwriteConfirm;
                if (!PromptDialog.Ask(this, "确认覆盖环境变量", "输入完整变量名确认允许覆盖：\r\n" + env, false, out overwriteConfirm) || overwriteConfirm != env) return;
            }
            if (MessageBox.Show(this, "将把旧 config.toml 内联 token 移入 User 环境变量 “" + env + "”。精确备份仍可能含旧 token。" + overwriteWarning + "\r\n\r\n是否继续？", "迁移旧密钥", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            var args = Args("MigrateLegacySecret");
            args.AddRange(new[] { "-ProviderId", provider.Id, "-EnvKey", env });
            if (overwriteKey.Checked) args.Add("-ForceOverwriteEnvironmentVariable");
            RunAction("正在迁移旧内联 token……", args, null, true, delegate
            {
                bool broadcastOk = SynchronizeProcessEnvironment(env);
                overwriteKey.Checked = false;
                if (broadcastOk)
                    ShowSuccess("迁移成功", "实时配置已改为 env_key，GUI 当前进程已同步。请重启 Codex；旧备份仍需妥善保管。");
                else
                    MessageBox.Show(this, "迁移已成功，GUI 当前进程也已同步，但 Windows 环境变更广播失败。请完全退出长期运行的启动器，必要时注销或重启 Windows，再启动 Codex。\r\n\r\n旧备份仍需妥善保管。", "迁移成功，但系统广播失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            });
        }

        private void RestoreSelectedBackup()
        {
            BackupView selected = backups.SelectedItem as BackupView;
            if (selected == null) { ShowError("没有备份", "请选择一个可恢复备份。"); return; }
            string warning = selected.ContainsSecret ? "\r\n\r\n警告：该备份可能含旧内联 token。" : string.Empty;
            if (MessageBox.Show(this, "将恢复备份：\r\n" + selected.Name + "\r\n" + selected.Operation + warning + "\r\n\r\n恢复前会再次备份当前配置。是否继续？", "恢复备份", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            var args = Args("RestoreBackup");
            args.AddRange(new[] { "-BackupName", selected.Name, "-ConfirmRestoreBackup" });
            RunAction("正在恢复备份……", args, null, true, delegate { ShowSuccess("恢复成功", "配置已恢复，请重启 Codex。"); });
        }

        private void ValidateConfig()
        {
            var args = Args("Validate");
            args.Add("-Json");
            RunAction("正在离线校验配置……", args, null, false, delegate(CommandResult result)
            {
                var serializer = new JavaScriptSerializer();
                var parsed = serializer.DeserializeObject(result.StandardOutput) as Dictionary<string, object>;
                bool skipped = parsed != null && parsed.ContainsKey("Skipped") && Convert.ToBoolean(parsed["Skipped"]);
                string message = parsed != null && parsed.ContainsKey("Message") ? Convert.ToString(parsed["Message"]) : result.StandardOutput;
                if (skipped)
                    MessageBox.Show(this, "当前 Codex 不支持该离线解析方式，校验已跳过。\r\n\r\n" + message, "校验未完成", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                else
                    ShowSuccess("校验完成", message);
            });
        }

        private void DirectProbe()
        {
            ProviderView activeProvider = status == null
                ? null
                : status.Providers.FirstOrDefault(p => string.Equals(p.Id, status.Provider, StringComparison.OrdinalIgnoreCase));
            if (activeProvider != null && activeProvider.ProcessUserKeyConflict)
            {
                if (MessageBox.Show(this, "当前 Process 与 User 环境变量中的 API Key 不一致。直接探测会优先继承 GUI 进程值。\r\n\r\n是否先把 GUI 当前进程同步为 User 值再继续？", "检测到旧 Key 冲突", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
                if (!SynchronizeProcessEnvironment(activeProvider.EnvKey))
                    MessageBox.Show(this, "GUI 当前进程已同步为 User Key，可以继续本次探测；但 Windows 环境变更广播失败。之后请退出长期运行的启动器，必要时注销或重启 Windows。", "系统广播失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            string answer;
            if (!PromptDialog.Ask(this, "直接 Responses API 探测", "此操作会发送一个 tools=[] 的小请求，可能计费。输入 PROBE 才会继续：", false, out answer) || answer != "PROBE") return;
            var args = Args("DirectProbe");
            args.Add("-ConfirmDirectProbe");
            RunAction("正在执行安全直接探测……", args, null, false, delegate(CommandResult result)
            {
                ShowSuccess("探测完成", string.IsNullOrWhiteSpace(result.StandardOutput) ? "Provider 返回成功响应。" : result.StandardOutput);
            });
        }

        private void OpenConfigDirectory()
        {
            string path = status == null ? string.Empty : status.ConfigPath;
            string directory = string.IsNullOrWhiteSpace(path) ? null : Path.GetDirectoryName(path);
            OpenDirectory(directory, "配置目录尚不存在。");
        }

        private void OpenBackupDirectory()
        {
            string config = status == null ? string.Empty : status.ConfigPath;
            string directory = string.IsNullOrWhiteSpace(config) ? null : Path.Combine(Path.GetDirectoryName(config), "switch-tools", "backups");
            OpenDirectory(directory, "备份目录尚不存在。");
        }

        private void OpenDirectory(string path, string missingMessage)
        {
            if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) { ShowError("目录不存在", missingMessage); return; }
            Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
        }

        private void CreateDesktopShortcut()
        {
            object shell = null;
            object shortcut = null;
            try
            {
                string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
                string linkPath = Path.Combine(desktop, "Codex 切换工具.lnk");
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                if (shellType == null) throw new InvalidOperationException("Windows Script Host 不可用。");
                shell = Activator.CreateInstance(shellType);
                shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { linkPath });
                Type shortcutType = shortcut.GetType();
                string existingTarget = File.Exists(linkPath)
                    ? Convert.ToString(shortcutType.InvokeMember("TargetPath", BindingFlags.GetProperty, null, shortcut, null))
                    : string.Empty;
                string warning = "快捷方式将指向当前 EXE：\r\n" + Application.ExecutablePath +
                                 "\r\n\r\n请将 EXE 保留在此位置；移动或删除后快捷方式会失效。";
                if (!string.IsNullOrWhiteSpace(existingTarget) && !string.Equals(existingTarget, Application.ExecutablePath, StringComparison.OrdinalIgnoreCase))
                    warning += "\r\n\r\n同名快捷方式当前指向：\r\n" + existingTarget + "\r\n继续将覆盖它。";
                if (MessageBox.Show(this, warning + "\r\n\r\n是否继续？", "创建桌面快捷方式", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
                shortcutType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { Application.ExecutablePath });
                shortcutType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { AppDomain.CurrentDomain.BaseDirectory });
                shortcutType.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { "中文 Codex Provider、模型与上下文配置工具" });
                shortcutType.InvokeMember("IconLocation", BindingFlags.SetProperty, null, shortcut, new object[] { Application.ExecutablePath + ",0" });
                shortcutType.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
                ShowSuccess("快捷方式已创建", linkPath);
            }
            catch (Exception ex) { ShowError("创建快捷方式失败", ex.Message); }
            finally
            {
                if (shortcut != null && Marshal.IsComObject(shortcut)) Marshal.FinalReleaseComObject(shortcut);
                if (shell != null && Marshal.IsComObject(shell)) Marshal.FinalReleaseComObject(shell);
            }
        }

        private void ShowEnvironmentOperationSuccess(string name, string title, string message)
        {
            if (SynchronizeProcessEnvironment(name))
                ShowSuccess(title, message);
            else
                MessageBox.Show(this, message + "\r\n\r\n但 Windows 环境变更广播失败。请完全退出长期运行的启动器，必要时注销或重启 Windows，再启动 Codex。", title + "（系统广播失败）", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        private static bool SynchronizeProcessEnvironment(string name)
        {
            string userValue = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.User);
            string machineValue = Environment.GetEnvironmentVariable(name, EnvironmentVariableTarget.Machine);
            return ApplyEffectiveEnvironment(name, userValue, machineValue, true);
        }

        private static bool ApplyEffectiveEnvironment(string name, string userValue, string machineValue, bool broadcast)
        {
            string effective = !string.IsNullOrWhiteSpace(userValue) ? userValue : machineValue;
            Environment.SetEnvironmentVariable(name, effective, EnvironmentVariableTarget.Process);
            if (!broadcast) return true;
            try
            {
                IntPtr result;
                IntPtr sent = NativeEnvironmentMethods.SendMessageTimeout(
                    new IntPtr(NativeEnvironmentMethods.HwndBroadcast),
                    NativeEnvironmentMethods.WmSettingChange,
                    IntPtr.Zero,
                    "Environment",
                    NativeEnvironmentMethods.SmtoAbortIfHung,
                    5000,
                    out result);
                return sent != IntPtr.Zero;
            }
            catch { return false; }
        }

        private void SetBusy(bool value, string text)
        {
            busy = value;
            UseWaitCursor = value;
            foreach (Control control in actionControls) control.Enabled = !value;
            UpdateModelControls();
            closeButton.Enabled = !value;
            bottomStatus.Text = text;
        }

        private void ShowError(string title, string message)
        {
            if (string.IsNullOrWhiteSpace(message)) message = "未知错误。";
            MessageBox.Show(this, message, title, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        private void ShowSuccess(string title, string message)
        {
            if (operationValidationSkipped)
                MessageBox.Show(this, message + "\r\n\r\n配置已写入并保留备份，但当前 Codex 未完成离线解析校验；请重启后留意错误。", title + "（校验已跳过）", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            else
                MessageBox.Show(this, message, title, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private static string ValueOr(string value, string fallback)
        {
            return string.IsNullOrWhiteSpace(value) ? fallback : value;
        }
    }

    internal static class Program
    {
        private static Mutex singleInstance;

        [STAThread]
        private static int Main(string[] args)
        {
            bool selfTestRequested = args.Length > 0 && string.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase);
            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                if (selfTestRequested)
                {
                    string config = args.Length > 1 ? args[1] : null;
                    if (args.Length >= 4)
                    {
                        string expected = (args[2] + Environment.NewLine + args[3]).Trim();
                        string embedded = PowerShellBridge.GetBuildFingerprint().Replace("\r\n", "\n").Replace("\r", "\n");
                        expected = expected.Replace("\r\n", "\n").Replace("\r", "\n");
                        if (!string.Equals(expected, embedded, StringComparison.OrdinalIgnoreCase)) return 23;
                    }
                    int selfTestCode = 0;
                    string extractedDirectory;
                    using (var bridge = new PowerShellBridge(config))
                    {
                        extractedDirectory = bridge.CoreDirectoryForTest;
                        if (!bridge.CoreDirectoryAclIsPrivateForTest()) selfTestCode = 26;
                        var statusArgs = new List<string> { "-Action", "Status", "-Json", "-SkipCodexValidation" };
                        CommandResult result = bridge.Run(statusArgs, null);
                        if (!result.Success && selfTestCode == 0) selfTestCode = 21;
                        else
                        {
                            StatusSnapshot.Parse(result.StandardOutput);
                            using (var form = new MainForm(bridge, config, true))
                            {
                                string[] expectedTabs = { "状态总览", "Provider 与模型", "上下文窗口", "密钥、备份与诊断" };
                                if (form.TabCountForTest != 4 || !form.TabTitlesForTest.SequenceEqual(expectedTabs)) selfTestCode = 22;
                                else if (form.Icon == null || form.Icon.Width < 16 || form.Icon.Height < 16) selfTestCode = 27;
                                else if (!MainForm.RunEnvironmentSynchronizationSelfTest()) selfTestCode = 24;
                                else if (!form.RunModelSelectionSelfTest()) selfTestCode = 28;
                                string previewPath = Environment.GetEnvironmentVariable("CST_GUI_PREVIEW_PATH");
                                if (selfTestCode == 0 && !string.IsNullOrWhiteSpace(previewPath)) form.RenderPreviewForTest(previewPath);
                            }
                        }
                    }
                    if (Directory.Exists(extractedDirectory)) return 25;
                    return selfTestCode;
                }

                bool created;
                singleInstance = new Mutex(true, "Local\\CodexSwitchToolsGui-5E5E8F40", out created);
                if (!created)
                {
                    MessageBox.Show("Codex 配置切换工具已经在运行。", "请勿重复启动", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return 0;
                }

                using (var powerShell = new PowerShellBridge(null))
                    Application.Run(new MainForm(powerShell, null, false));
                return 0;
            }
            catch (Exception ex)
            {
                if (selfTestRequested)
                {
                    try { Console.Error.WriteLine(ex.ToString()); } catch { }
                    return 1;
                }
                MessageBox.Show(ex.Message, "Codex 配置切换工具", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            finally
            {
                if (singleInstance != null) singleInstance.Dispose();
            }
        }
    }
}
