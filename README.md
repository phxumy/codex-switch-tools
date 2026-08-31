# Codex Switch Tools（Windows）

一个面向 Codex CLI、Codex 桌面端和 IDE 扩展的中文配置工具，用来管理 Provider、请求模型、上下文窗口、API Key、备份恢复和诊断。

从 v1.1.0 开始，推荐使用与“深信服 Winsock 开关”同类的原生 Windows Forms 桌面界面；原 BAT/PowerShell 菜单继续保留，作为自动化和故障恢复入口。

## 推荐：中文桌面版

下载或从仓库运行：

- [`dist/CodexSwitchTools.exe`](dist/CodexSwitchTools.exe)
- SHA-256 见 [`SHA256SUMS.txt`](SHA256SUMS.txt)

特点：

- 单文件 EXE，已经内嵌经过测试的 PowerShell 配置核心；
- 不需要管理员权限；
- 使用 Windows 原生 WinForms、微软雅黑和系统按钮，不依赖第三方 UI 框架；
- 优先调用标准安装位置且版本信息匹配 Microsoft 的 PowerShell 7，找不到时自动回退到受信任的系统 Windows PowerShell 5.1；
- 固定使用用户级 Codex 配置，不向普通用户提供项目配置文件选择器；
- 可在界面内创建中文桌面快捷方式“Codex 切换工具”。

使用步骤：

1. 下载 `CodexSwitchTools.exe`。
2. 双击打开。
3. 在“状态总览”确认当前持久配置。
4. 在对应标签页执行操作。
5. 写入成功后，完全退出并重新打开 Codex 或 VS Code。

EXE 没有商业代码签名，Windows SmartScreen 可能显示“未知发布者”。可先核对 SHA-256，或从源码自行构建。移动 EXE 后，已有桌面快捷方式会失效，需要在新位置重新创建。

## 中文界面

### 状态总览

- 显示用户级 `config.toml` 路径、Codex 版本、预计 Provider、请求模型、reasoning effort、上下文和认证偏好；
- 列出自定义 Provider、Base URL、`env_key` 是否存在；
- 旧内联 token 只显示“检测到”，绝不显示具体值；
- 明确写成“持久配置预计下次启动生效”，不会把静态配置误称为服务端最终模型。

### Provider 与模型

- 自动列出现有自定义 Provider；
- Provider 与模型由用户选择，不再绑定某个服务商；
- 新增/更新通用 Responses API Provider；
- Provider 定义和“设为当前”分开操作；
- 可恢复 Codex 内置 `openai` Provider，同时保留上下文、登录方式和自定义 Provider 表；
- 高级 command auth、headers 和 query params 只读提示，GUI 不会擅自覆盖。

### 上下文窗口

- 对使用原生目录且当前 Provider 为 `openai` 的内置模型，可读取本机 catalog 的 `max_context_window`；
- 第三方 Provider、自定义 catalog 和未知模型不会自动套用内置模型上限；
- 保留 GPT-5.6 的 `872000 / 800000` 旧预设，但必须单独确认；
- 支持完全自定义窗口和自动压缩阈值；
- 工具管理的上下文会记录启用前原值，恢复时还原；
- 未带工具标记的手工上下文默认拒绝删除，必须输入 `REMOVE` 确认。

> 自动压缩阈值是本工具的启发式建议，不是 OpenAI 官方推荐值。

### 密钥、备份与诊断

- API Key 使用密码框，不显示、不复制、不写命令行；
- GUI 通过重定向标准输入把 Key 交给内嵌核心，随后清空密码框；
- 覆盖已有 User Key 或允许迁移覆盖时，必须输入完整环境变量名确认；
- Key 最终写入 Windows 当前用户环境变量，Provider 配置仅保存 `env_key`；
- 支持显式迁移旧 `experimental_bearer_token`；
- 删除 Key 要求输入完整变量名确认；
- 备份恢复前会再次备份当前配置；
- 含旧内联 token 的备份会显示明显警告；
- 可执行有超时的离线配置校验；
- 可执行一个 `tools=[]` 的直接 Responses API 小请求，可能计费，因此必须输入 `PROBE`。

直接探测不会启动 Codex agent、MCP、hooks 或项目规则；它只验证简单 `env_key`/无认证 Provider 的端点、Key、模型和基础 Responses JSON 兼容性。它不等于完整复刻 Codex Rust 客户端，也不能证明服务端没有重映射模型。

## 命令行版

保留以下入口：

- `Codex-Switch-Tools.bat`：交互式文本菜单；
- `Codex-Switch-Tools.ps1`：非交互自动化核心；
- `Toggle-CodexLongContext.*`：早期独立长上下文入口，作为兼容工具保留。

示例：

```powershell
.\Codex-Switch-Tools.ps1 -Action Status -Json
.\Codex-Switch-Tools.ps1 -Action ConfigureProvider -ProviderId cst_demo -ProviderName Demo -BaseUrl https://example.com/v1 -EnvKey CODEX_DEMO_API_KEY
.\Codex-Switch-Tools.ps1 -Action SetProvider -ProviderId cst_demo -Model provider-model-id
.\Codex-Switch-Tools.ps1 -Action SetContext -ContextWindow 872000 -AutoCompactLimit 800000
.\Codex-Switch-Tools.ps1 -Action ResetContext
.\Codex-Switch-Tools.ps1 -Action UseOpenAI
.\Codex-Switch-Tools.ps1 -Action ListBackups -Json
```

不要通过命令行参数传 API Key。GUI/核心的 `SetApiKey` 动作只接受标准输入。

## 配置一个新 API Provider

假设服务商提供兼容 Responses API 的地址：

1. 打开“Provider 与模型”；
2. 输入非保留 ID，例如 `cst_my_provider`；
3. 输入显示名称和服务商给出的 Base URL，例如 `https://example.com/v1`；
4. 输入专用环境变量名，例如 `CODEX_MY_PROVIDER_API_KEY`；
5. 保存 Provider 定义；
6. 前往“密钥、备份与诊断”保存 Key；
7. 回到 Provider 页，填写真实模型 ID并“应用选择”；
8. 重启 Codex。

工具生成的结构类似：

```toml
model = "provider-model-id"
model_provider = "cst_my_provider"

[model_providers.cst_my_provider]
name = "My Provider"
base_url = "https://example.com/v1"
wire_api = "responses"
requires_openai_auth = false
env_key = "CODEX_MY_PROVIDER_API_KEY"
```

当前官方配置中，自定义 Provider 的 `wire_api` 只支持 `responses`，API Key 推荐通过 `env_key` 提供。[Codex Configuration Reference](https://developers.openai.com/codex/config-reference)

## “Codex 真正调用了什么”

状态页展示的是**用户持久配置预计让下次启动使用的 Provider 和请求模型**。以下内容仍可能覆盖它：

- CLI 的 `-c`、`-m` 或 `--profile`；
- 项目级可信配置；
- 桌面端 UI 或已有任务保存的选择；
- Provider 在服务端对模型别名再次映射。

因此静态工具不能证明服务端最终使用了哪块模型。直接探测也只能验证基础协议兼容。

## 切换后必须新建聊天吗？

通常不必。完全退出并重启 Codex 后，可以重新打开原任务继续使用。

如果原任务已经发生自动压缩，扩大上下文不会恢复此前被压缩掉的原始历史；希望从第一条消息完整利用长窗口时才建议新建任务。

## 安全与数据处理

- GUI 默认只操作用户级 `%CODEX_HOME%\config.toml`；未设置 `CODEX_HOME` 时使用 `%USERPROFILE%\.codex\config.toml`；
- 高级 CLI 参数 `-ConfigPath` 只用于隔离测试/管理员自动化，不要用它把 Provider/Auth 写入项目 `.codex/config.toml`，Codex 会忽略这些项目级字段；
- API Key 不写入新 Provider 的 TOML；
- Key 更新/删除/迁移成功后，GUI 会同步自己的 Process 环境并广播 Windows 环境变更；广播失败时会用黄色警告要求退出长期运行的启动器，必要时注销或重启 Windows；
- Windows 用户级环境变量无需管理员权限，但不是加密保险箱；
- EXE 每次启动会把内嵌核心提取到随机 LocalAppData 运行目录，关闭 ACL 继承，只允许当前用户和 SYSTEM；每次调用前再次校验完整 SHA-256，退出时清理；
- 每次配置写入执行并发哈希检查、同盘原子替换、唯一备份和可用时的 Codex 离线解析；
- 解析失败、超时或抛异常会自动回滚；
- 备份是原配置的精确副本，旧配置若含内联 token，对应备份也可能包含；
- 不删除 `forced_login_method`、`preferred_auth_method`、`model_catalog_json` 或未知配置；
- 不在后台自动发起真实 API 请求；
- 原子替换依赖文件系统 `File.Replace`；不支持时工具会停止并报错，不使用不安全覆盖回退。

保存或删除环境变量后必须完全重启 Codex/VS Code。少数长期存活的启动器或企业环境可能需要重新登录 Windows 才能继承新变量。

## 兼容性与测试

核心隔离测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh.exe -NoProfile -File .\tests\Run-Tests.ps1
```

GUI 构建/自测：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GuiSmoke.ps1
```

如本机已安装 Codex，希望把真实离线解析纳入核心测试：

```powershell
$env:CST_RUN_CODEX_INTEGRATION = '1'
.\tests\Run-Tests.ps1
```

覆盖范围包括：

- Windows PowerShell 5.1 与 PowerShell 7；
- GUI 单文件构建、4 个中文标签页、内嵌核心和 PS5 fallback；
- GUI/配置路径含空格、`&`、括号和中文；
- UTF-8 BOM/无 BOM、CRLF/LF、注释、数组和多行字符串；
- Provider→OpenAI→Provider；
- 上下文开启/恢复、手工值保护；
- Key 标准输入、零回显和删除确认；
- 备份列表/恢复；
- 校验失败和异常自动回滚；
- loopback mock 的真实 Codex `/v1/responses` 路由；
- 安全直接探测；
- 仓库密钥和私人路径扫描。

GitHub Actions 在 Windows 上运行 PowerShell 5.1、PowerShell 7 和 GUI 构建自测；真实、可能计费的 Provider 请求不会进入 CI。

## 从源码构建中文 EXE

系统要求：64 位 Windows，带 .NET Framework 4.x 的 `csc.exe`。

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build-gui.ps1
```

输出：

- `dist/CodexSwitchTools.exe`
- `SHA256SUMS.txt`

构建时会把当前 `Codex-Switch-Tools.ps1` 作为资源嵌入 EXE，因此成品可以单文件运行。

## 文件说明

- `dist/CodexSwitchTools.exe`：推荐的中文桌面版；
- `src/CodexSwitchTools.Gui.cs`：WinForms GUI 源码；
- `src/CodexSwitchTools.Gui.manifest`：无需管理员权限的应用清单；
- `build-gui.ps1`：可复现构建脚本；
- `Codex-Switch-Tools.bat`：文本菜单入口；
- `Codex-Switch-Tools.ps1`：唯一配置、备份和探测核心；
- `tests/Run-Tests.ps1`：核心回归测试；
- `tests/Test-GuiSmoke.ps1`：GUI 构建与隐藏窗口自测；
- `tests/Test-LocalProviderRoute.ps1`：本地 mock 路由测试；
- `tests/Test-RepositoryHygiene.ps1`：仓库敏感信息扫描。

## 免责声明

本项目不是 OpenAI 官方工具。Provider、模型和第三方 API 的可用性由相应服务商决定；请自行核对端点、模型上限、费用和服务条款。
