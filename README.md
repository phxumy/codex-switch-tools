# Codex Switch Tools（Windows）

一个面向 Codex CLI、Codex 桌面端和 IDE 扩展的多功能配置切换器。双击 BAT 后通过菜单管理 Provider、请求模型、上下文窗口、API Key、诊断和备份。

项目重点解决旧版脚本换电脑后常见的不兼容问题：不再写死 DeepSeek/IPHY、模型名、API 地址或用户目录，也不再把某个上下文值作为唯一/自动选择；新电脑无需预先存在某个 Provider。

## 快速开始

1. 下载仓库 ZIP 并解压。
2. 保持以下两个文件位于同一目录：
   - `Codex-Switch-Tools.bat`
   - `Codex-Switch-Tools.ps1`
3. 双击 `Codex-Switch-Tools.bat`。
4. 修改完成后，完全退出并重新打开 Codex 或 VS Code。

BAT 会优先使用 PowerShell 7（`pwsh.exe`），找不到时自动回退到 Windows PowerShell 5.1。

## 主菜单

1. **显示预期生效配置与诊断**
   - 显示用户级 `config.toml`、Codex 路径/版本、Provider、请求模型、reasoning effort、上下文和 Key 是否存在。
   - 永远不显示 API Key 内容。
2. **切换 Provider 和请求模型**
   - 自动列出现有自定义 Provider。
   - 模型名由用户输入，不再写死某个厂商或模型。
   - 切换 Provider 不会偷偷修改上下文窗口或登录偏好。
3. **新增或更新通用 Responses API Provider**
   - 输入 Provider ID、显示名、Base URL、环境变量名。
   - `wire_api` 固定为当前 Codex 正式支持的 `responses`。
   - Provider 元数据写入用户级配置，Key 写入 Windows 环境变量。
4. **上下文窗口工具**
   - 对使用原生目录且当前 Provider 为 `openai` 的 Codex 内置模型，优先读取本机离线模型目录里的 `max_context_window`。
   - 自动压缩阈值是本工具的保守启发式建议，不是 OpenAI 官方推荐值；第三方 Provider、自定义 catalog 或未知模型必须显式选择预设/自定义值。
   - 支持原来的 GPT-5.6 `872000 / 800000` 预设和完全自定义。
   - 开启时记录原值，关闭时恢复原值；Provider 与上下文互不绑定。
5. **API Key 与旧秘密迁移**
   - 安全录入或删除用户级环境变量。
   - 显式迁移旧配置中的 `experimental_bearer_token`，不会自动删除。
6. **备份与恢复**
   - 每次配置写入前创建唯一备份。
   - 可从菜单恢复最近备份；恢复前还会再备份当前配置。
7. **可选真实连通测试**
   - 直接发送一个 `tools=[]` 的小型 Responses API 请求，不启动 Codex agent、MCP、hooks 或项目规则。
   - 可能产生费用，因此需要手动输入 `PROBE` 二次确认；仅支持纯 `env_key`/无认证且没有自定义 headers/query params 的 Provider。
8. **创建桌面快捷方式**

## 配置一个新 API Provider

假设服务商提供兼容 Responses API 的地址：

1. 选择菜单 **3**。
2. 输入一个非保留 ID，例如 `cst_my_provider`。
3. 输入服务商给出的 Base URL，例如 `https://example.com/v1`。工具不会擅自添加或删除 `/v1`。
4. 输入环境变量名，例如 `CODEX_MY_PROVIDER_API_KEY`，并选择是否立即保存 Key。
5. 选择是否立刻切换，然后输入服务商真实支持的模型 ID。

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

API Key 不会写入示例或仓库。

## “Codex 真正调用了什么”应如何理解

诊断页显示的是**用户持久配置预计让下次启动使用的 Provider 和请求模型**。以下内容仍可能覆盖它：

- CLI 的 `-c`、`-m` 或 `--profile` 参数；
- 项目级可信配置；
- 桌面端 UI 或已有任务保存的选择；
- API Provider 在服务端对模型别名进行再次映射。

因此，静态配置不能证明服务端最终使用了哪块模型。菜单中的直接 Responses 测试可以确认“端点、Key 与请求模型基本兼容”，但它不是 Codex Rust 客户端的完整行为复刻，也无法证明 Provider 没有在后端重映射模型。

## 切换后必须新建聊天吗？

通常不必。完全退出并重启 Codex 后，可以重新打开原任务继续使用。

如果原任务已经发生自动压缩，扩大上下文不会恢复此前被压缩掉的原始历史；希望从第一条消息完整利用长窗口时才建议新建任务。

## 安全与数据处理

- 默认只修改用户级 `%CODEX_HOME%\config.toml`；未设置 `CODEX_HOME` 时使用 `%USERPROFILE%\.codex\config.toml`。高级测试参数 `-ConfigPath` 可以指向隔离夹具，但不要用它把 Provider/Auth 写进项目 `.codex/config.toml`，Codex 会忽略这些项目级字段。
- API Key 使用 `env_key` 引用，不写入新 Provider 的 TOML。
- Key 通过 `SecureString` 隐藏输入；状态页不读取展示其内容，错误/探测输出会对当前已知 Key 做精确替换并叠加常见格式脱敏。
- Windows 用户级环境变量无需管理员权限，但会以当前用户可读取的形式保存在 Windows 中，并非加密保险箱。
- 保存 Key 后必须完全重启 Codex/VS Code；少数长期存活的启动器或企业环境可能需要重新登录 Windows 才能继承新变量。
- 每次写入执行并发哈希检查和同盘临时文件替换；本机 Codex 支持时再进行有超时的离线解析。解析失败或抛异常会自动回滚，跳过时会明确显示 `skipped`。
- 备份是原配置的精确副本。如果旧配置本来含有内联 token，对应备份也会含有它；迁移菜单会明确提醒。
- 原子替换依赖文件系统的 `File.Replace` 支持；不支持该能力的旧 FAT/部分网络盘会安全停止并报错，而不会采用不安全的覆盖回退。
- 不删除 `forced_login_method`、`preferred_auth_method`、`model_catalog_json` 或未知配置。
- 不在后台发起真实 API 测试；只有用户明确选择并确认 `PROBE` 才会发请求。

## 兼容性测试

仓库包含无第三方依赖的测试：

```powershell
# Windows PowerShell 5.1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

# PowerShell 7
pwsh.exe -NoProfile -File .\tests\Run-Tests.ps1
```

覆盖内容包括：

- 全新电脑没有 `.codex` 或 `config.toml`；
- Windows PowerShell 5.1 与 PowerShell 7；
- `CODEX_HOME`/配置路径含空格、`&`、括号和中文；
- UTF-8 BOM/无 BOM、CRLF/LF、注释、数组及多行字符串；
- Provider→OpenAI→Provider、上下文开启/恢复；
- 保留 ID、非法上下文、校验失败自动回滚；
- 旧内联 token 迁移期间零回显。

手动集成测试 `tests/Test-LocalProviderRoute.ps1` 会启动仅监听 `127.0.0.1` 的 mock 服务，使用假 Key 验证本机 Codex 实际请求 `/v1/responses`、传递所选模型且认证头与预期假值一致；它还验证菜单所用的安全直接探测器能识别 Responses-shaped 成功响应。mock 永不记录认证头内容，也不主动访问公网。CI 默认只运行不需要安装 Codex 的隔离配置测试。

## 自动化参数

PowerShell 核心支持非交互操作，适合测试或管理员脚本：

```powershell
.\Codex-Switch-Tools.ps1 -Action Status -Json
.\Codex-Switch-Tools.ps1 -Action ConfigureProvider -ProviderId cst_demo -ProviderName Demo -BaseUrl https://example.com/v1 -EnvKey CODEX_DEMO_API_KEY
.\Codex-Switch-Tools.ps1 -Action SetProvider -ProviderId cst_demo -Model provider-model-id
.\Codex-Switch-Tools.ps1 -Action SetContext -ContextWindow 872000 -AutoCompactLimit 800000
.\Codex-Switch-Tools.ps1 -Action ResetContext
.\Codex-Switch-Tools.ps1 -Action UseOpenAI
```

不要通过命令行参数传 API Key；请在交互菜单中隐藏录入。

## 文件说明

- `Codex-Switch-Tools.bat`：推荐双击入口。
- `Codex-Switch-Tools.ps1`：通用配置、备份、诊断与菜单核心。
- `Toggle-CodexLongContext.*`：早期的独立长上下文切换器，作为兼容入口保留。
- `tests/Run-Tests.ps1`：隔离配置回归测试。
- `tests/Test-LocalProviderRoute.ps1`：本机 mock 路由测试。

官方字段说明：[Codex Configuration Reference](https://developers.openai.com/codex/config-reference)。自定义 Provider 当前只支持 Responses 协议，并推荐通过 `env_key` 提供 Key。
