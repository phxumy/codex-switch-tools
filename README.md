<p align="center">
  <img src="assets/CodexSwitchTools-icon-source.png" width="112" alt="Codex Switch Tools 图标">
</p>

# Codex Switch Tools（Windows）

一个面向 Codex CLI、Codex 桌面端和 IDE 扩展的中文配置工具，用来管理用户级 Provider、请求模型、上下文窗口、API Key、配置备份和诊断。

**[下载最新版中文 EXE](https://github.com/phxumy/codex-switch-tools/releases/latest/download/CodexSwitchTools.exe)** · [发行版与更新说明](https://github.com/phxumy/codex-switch-tools/releases/latest) · [SHA-256 校验文件](https://github.com/phxumy/codex-switch-tools/releases/latest/download/SHA256SUMS.txt)

下载后直接双击即可，不需要克隆仓库、安装 Python、安装 PowerShell 7 或以管理员身份运行。它是原生 Windows Forms 单文件程序，使用 Windows 自带的 .NET Framework 4.x 和 Windows PowerShell 5.1；BAT/PowerShell 入口保留给自动化和故障恢复。

> [!IMPORTANT]
> 这个工具修改的是“下次启动预计使用的持久配置”，不是模型服务器。它不能证明服务端最终用了哪个模型，也不会替你判断第三方 Provider 是否可信。执行真实探测前，务必先核对 Base URL。

## 下载、安装与第一次启动

1. 打开[最新发行版](https://github.com/phxumy/codex-switch-tools/releases/latest)，在 **Assets** 中下载 `CodexSwitchTools.exe` 和同一版本的 `SHA256SUMS.txt`。不要把自动生成的 `Source code (zip)` 当成安装包；普通用户只需要 EXE。
2. 把 EXE 放到一个不会随便移动的固定目录，例如 `D:\Tools\CodexSwitchTools\`。
3. 可选：用 PowerShell 核对文件哈希：

   ```powershell
   Get-FileHash -Algorithm SHA256 .\CodexSwitchTools.exe
   ```

   输出应与同一发行版 `SHA256SUMS.txt` 中 EXE 的值一致。哈希不一致时不要运行，重新从本仓库的发行版下载。
4. 双击 EXE。程序没有代码签名，Windows SmartScreen 可能显示“未知发布者”；先核对下载网址、版本和哈希，再自行决定是否信任。不要关闭系统安全防护，不要运行来源不明的同名 EXE；单位电脑受管理策略限制时联系管理员。
5. 先在“状态总览”核对配置路径。默认是 `%USERPROFILE%\.codex\config.toml`；如果设置了 `CODEX_HOME`，则是 `%CODEX_HOME%\config.toml`。
6. 进入“密钥、备份与诊断”，点击“创建中文桌面快捷方式”。快捷方式会指向当前 EXE，因此创建后不要再移动 EXE。

v1.1.1 起，EXE、窗口标题栏、Alt+Tab、桌面快捷方式和任务栏都使用项目自己的蓝橙切换图标。

升级时先退出旧工具，用新 EXE 替换固定目录中的旧文件，再启动即可。用户配置和备份不存放在 EXE 内，不会因替换 EXE 被清空。发行版目标是 Windows 10/11 x64；自动测试运行在 GitHub Windows runner，未逐一验证所有 Windows 10/11 版本或企业加固环境，详见“兼容性与测试”。

## 先弄清三个概念

| 概念 | 它表示什么 | 工具能否验证 |
|---|---|---|
| Provider | 请求发往哪套 API 配置，包括 Base URL 和认证方式 | 能检查配置形状，不能判断服务商是否可信 |
| 模型 ID | 发给 Provider 的模型名称字符串 | 能写入，不能证明服务端没有重映射 |
| 上下文窗口 | `model_context_window` 和自动压缩阈值 | 能写入，不能证明目标模型真的支持该数值 |

三者相互独立。v1.2.0 的 GUI 会同时管理所选第三方 Provider 的模型目录与适用上下文，避免把官方 DeepSeek 的窗口直接带到物理所等其他服务；命令行不带 `-ManageModelCatalog` 的传统切换仍保留原上下文。无论哪种方式，工具记录的能力都不等于服务端实际支持保证。

## 一分钟快速上手

如果只想使用当前 Codex，不配置第三方 API：

1. 在“状态总览”确认 Provider 是 `openai`。
2. 去“上下文窗口”：
   - 如果工具显示了可检测的内置模型，优先使用“按目录开启长上下文”；
   - 如果显示“UI / 模型默认”，工具无法知道具体模型上限，不要盲点自动模式；
   - `872K / 800K` 是 GPT-5.6 的旧兼容预设，不是所有模型都适用；
   - 只有在模型或服务商明确给出限制时才填写自定义值。
3. 操作成功后，**完全退出并重新启动 Codex/VS Code**。
4. 可以重新打开原任务继续聊，不强制新建任务。若原任务已经自动压缩，扩大窗口不会恢复此前被压缩掉的原始历史；想从第一条消息完整利用新窗口时，再新建任务。

如果要配置第三方 Provider，请按“保存 Provider 定义 → 保存 Key → 应用 Provider 与模型 → 重启”的顺序操作，详见后文。

## 四个标签页怎么用

### 1. 状态总览

这里是每次操作前后的检查页。

- 顶部粗体摘要显示 Provider 和请求模型的“下次启动预计值”。
- `配置文件` 是工具实际要读写的用户级 `config.toml`。
- `请求模型` 显示 `UI / 模型默认` 时，表示根配置没有显式 `model` 值，不代表工具已经识别出某个具体模型。
- `上下文` 和 `自动压缩` 显示“模型默认”时，表示工具没有写对应的根级覆盖。
- `工具管理上下文：是` 表示存在恢复标记，可以回到首次启用前的值。
- 自定义 Provider 会列出 Base URL、`env_key` 以及当前进程能否看到该变量，但不会显示密钥内容。

按钮含义：

- **刷新状态**：重新读取配置、备份和环境变量，不写任何内容。
- **校验配置**：尝试让当前 PATH 中的 Codex 解析配置。找不到 Codex、版本不支持或使用非标准配置文件名时可能显示“已跳过”。
- **打开配置目录**：用资源管理器打开配置所在目录。

“校验完成”只说明当前 Codex 能解析配置，不说明 Base URL、Key、模型权限或服务端模型一定正确。

### 2. Provider 与模型

页面上半部分负责“把谁设为当前”，下半部分负责“新增或修改 Provider 定义”。这两件事故意分开，避免保存端点时意外切换当前服务。

#### 切换已有第三方 Provider

1. 在 `Provider` 下拉框选择目标 Provider。
2. 从模型下拉框选择模型。工具会读取已保存的列表和内置的已知模型元数据，并记住该 Provider 上次选择。
3. 想获取服务商新模型时，先确认 Base URL，再点击“刷新模型列表”。它只在你点击后发送 `GET <Base URL>/models`；不会自动发送聊天或图片，也不会自动切换当前模型。
4. `推理强度` 不确定时选“模型默认”。已知模型只提供其元数据声明的档位；未知模型不自动套用其他模型的推理强度。
5. 点击“应用选择”。程序会生成该 Provider 独立的模型目录，写入 `model_catalog_json`、Provider 和模型配置；已有非本工具管理的目录需要明确确认才能替换。
6. 如果弹出未知能力、上下文或 Key 警告，先核对再确认。
7. 成功后**完全退出并重启 Codex/VS Code**。Codex 在启动时加载模型目录，不会因工具保存配置立刻热更新菜单。

Codex 的模型菜单应使用当前 Provider 的目录，但部分桌面版本仍可能把第三方模型显示为“自定义 / Custom”。以本工具状态页中的 Provider、模型 ID 和目录为准；**DeepSeek Provider 下不要点击 GPT / 5.6 等 OpenAI 模型**。本工具能阻止自己界面里的明显错配，不能拦截 Codex 原生界面之后重新写入模型的操作。若原生菜单仍旧，先重启并检查是否有任务或 profile 覆盖，不要靠点击不相干的模型“刷新”。

#### 新模型、视觉模型与自动发现

不需要把模型永远固定成 `deepseek-v4-pro`，也不需要每次先手工找名称。常规流程是“选 Provider → 刷新模型列表 → 选模型 → 应用 → 重启”。

`GET /models` 通常只提供模型 ID 等基本信息，**不保证包含上下文长度、图片输入或推理档位**。工具按“Provider 端点 + 模型 ID”匹配元数据，不能仅凭名字含有 `vision` 就宣称支持图片。

| 服务与模型 | v1.2.0 随附的已知能力 | 使用边界 |
|---|---|---|
| 官方 DeepSeek `deepseek-v4-pro`、`deepseek-v4-flash` | 1,048,576 tokens，文本输入 | 仅匹配官方 DeepSeek API 端点；不自动等同于同名第三方模型 |
| 官方 DeepSeek `deepseek-v4-flash-vision-exp` | 1,048,576 tokens，文本与图片输入 | 实验视觉模型；须同时使用支持图片输入的 Responses 接口 |
| 物理所 IPHY `deepseek-v4-pro` | 已知配置为 262,144 tokens，文本输入 | 与官方 DeepSeek 分开管理；不假设物理所开放全部官方模型 |
| 其他或新发布的模型 | 标为元数据未验证，保守回退为文本、32,768 tokens | 不是服务商容量声明，应用前需要确认；真实限制可能更低 |

物理所或其他服务是否开放某个新模型，以其实际 `/models` 返回和服务说明为准。离线内置项只表示工具知道这个模型的配置，不能证明当前账户有权限。

如果 `/models` 不受支持、网络失败，或服务商提供了尚未列出的模型，可以勾选“高级：手动输入模型 ID（通常不需要）”后输入准确 ID。只有确认服务商能力后才应用未知模型，并按文档设置自定义上下文；不要为了去掉警告随意放大窗口。未知模型不会自动启用图片能力。

刷新需要把当前 Provider 的 Bearer Key 发给它的 Base URL，因此只使用可信 HTTPS 端点；本机 HTTP 测试服务例外。高级 command auth、额外 headers/query 等认证定义不由通用刷新动作执行。Key 缺失、认证失败或刷新失败时，先修正连接，已有列表和选择不应被误当成刷新成功。

依据：[DeepSeek Codex 配置](https://api-docs.deepseek.com/quick_start/agent_integrations/codex/)、[模型列表接口](https://api-docs.deepseek.com/api/list-models/)、[Codex 配置参考](https://developers.openai.com/codex/config-reference/)。模型清单会变化，以刷新结果和服务商最新说明为准。

模型目录是兼容层，不只是名称清单。已验证的 Codex 版本要求目录提供基础指令；本工具生成一段简短、中性的编程助手指令，不复制旧版的大段 GPT 提示词或用户私人提示词。因此第三方模型的基础行为不保证与 Codex 内置模型完全相同。

#### 恢复内置 OpenAI

点击“恢复内置 OpenAI”后会：

- 写入 `model_provider = "openai"`；
- 删除根级自定义 `model` 和 `model_reasoning_effort` 覆盖；
- 对本工具管理的模型目录及相关上下文，恢复到首次接管前的状态：原来没有自定义目录时恢复 Codex 内置目录，原来有目录时恢复原路径；
- 不擅自删除未被本工具接管的目录或上下文；保留登录方式、自定义 Provider 定义和 Windows 环境变量。

它不是“恢复出厂设置”，也不会替你登录或删除第三方 API Key。

#### 新增或更新 Responses API Provider

1. `Provider ID`：自定义的稳定标识，必须以英文字母开头，只能含英文字母、数字、`_`、`-`，最多 64 个字符。不要使用保留 ID `openai`、`ollama`、`lmstudio`。
2. `显示名称`：只用于阅读，可以写服务商名称。
3. `Base URL`：完全照服务商文档填写。工具不会擅自添加或删除 `/v1`。公网服务应使用 HTTPS。
4. `密钥环境变量`：填一个专用名称，例如 `CODEX_MY_PROVIDER_API_KEY`。不要复用 `PATH`、`HOME`、`CODEX_HOME` 等系统变量。
5. 只有目标端点确实无需 Bearer Key 时，才勾选“此 Provider 不需要 Bearer Key”。
6. 点击“保存 Provider 定义”。此时只保存定义，**不会保存 Key，也不会设为当前 Provider**。
7. 去“密钥、备份与诊断”保存 Key。
8. 回到本页上半部分，选择刚保存的 Provider，刷新并选择模型，点击“应用选择”。接口不支持模型列表时才使用高级手动输入。
9. 重启 Codex。

“从选中项填入”只会把简单 Provider 填入表单，不写配置。使用 command auth、headers、query、OpenAI 登录或旧内联 token 的高级 Provider 会保持只读，防止通用表单破坏其认证语义。

工具生成的基础结构类似：

```toml
model = "provider-model-id"
model_provider = "cst_my_provider"
# GUI 应用模型时还会写入本机生成的独立 model_catalog_json 路径。

[model_providers.cst_my_provider]
name = "My Provider"
base_url = "https://example.com/v1"
wire_api = "responses"
requires_openai_auth = false
env_key = "CODEX_MY_PROVIDER_API_KEY"
```

### 3. 上下文窗口

#### “按目录开启长上下文”

这是最保守的自动模式。只有同时满足以下条件时才会启用：

- 当前 Provider 是内置 `openai`；
- 用户配置根部已有明确的内置模型 ID；
- 没有设置自定义 `model_catalog_json`；
- 本机 Codex 自带目录能为该模型给出高于默认值的 `max_context_window`。

如果状态显示 `UI / 模型默认`，工具不知道该用哪个模型目录，自动模式会拒绝猜测。可先在 Codex 中选择一个明确模型并让它成为持久配置，或依据官方配置说明手工设置根级 `model`，再回到工具刷新状态。

#### “使用 872K / 800K 预设”

这会直接写入：

```toml
model_context_window = 872000
model_auto_compact_token_limit = 800000
```

它是 GPT-5.6 的旧兼容预设，不是跨模型、跨 Provider 的通用推荐。第三方服务可能拒绝请求、截断输入、产生额外费用或延迟。只有明确确认目标支持时才使用。

#### “应用自定义值”

- “上下文 tokens”必须是正整数；
- “自动压缩阈值”必须是正整数且小于上下文窗口；
- 工具只检查数字关系，不检查服务端上限；
- 自动模式和自定义模式计算的压缩阈值都不是 OpenAI 官方通用推荐值。

#### “恢复之前 / 模型默认”

工具第一次管理上下文时，会记录启用前两个字段是缺失还是已有数值。之后无论切换自动、预设还是自定义，恢复按钮都会回到**第一次启用前**的状态，而不是上一次修改前的状态。

如果这两个值不是本工具写入、没有所有权标记，程序会要求输入 `REMOVE`，避免误删手工配置。

上下文改动需要重启 Codex 才能可靠生效。

### 4. 密钥、备份与诊断

#### 保存或更新 API Key

1. 选择 Provider；页面会填入它当前引用的环境变量名。
2. 确认“环境变量”与 Provider 定义中的 `env_key` 完全一致。
3. 在密码框粘贴新 Key。
4. 点击“保存 / 更新 Key”。覆盖不同的已有 User 值时，需要输入完整变量名确认。
5. 重启 Codex/VS Code；少数长期运行的启动器可能需要注销 Windows 后才能继承新变量。

**这个按钮只写 Windows 当前用户环境变量，不会修改 Provider 的 `env_key`。** 如果你在此处手工改了变量名，必须回到“Provider 与模型”同步更新 Provider 定义，否则 Codex 仍会读取旧变量名。

Windows User 环境变量存放在当前用户配置中，不是加密保险箱；同一 Windows 用户下的进程可以读取。API Key 不会进入普通 Provider TOML，但也不会进入配置备份。

#### 删除 User Key

“删除 User Key”只删除 User scope。若系统存在同名 Machine 环境变量，新进程可能自动回落到 Machine 值，因此“删除成功”不等于系统中已不存在同名 Key。工具不会删除 Machine scope，也无法判断其他程序是否仍引用该变量。

建议每个 Provider 使用独立变量名，不要共享。

#### 迁移旧内联 token

“迁移旧内联 token”会把受支持的单行 `experimental_bearer_token`：

1. 写入 Windows User 环境变量；
2. 把 Provider 改为引用 `env_key`；
3. 从实时 `config.toml` 删除内联 token。

迁移前创建的精确配置备份仍可能包含明文旧 token。迁移验证完成且确定不再需要回滚后，可从“打开备份目录”中人工检查并安全清理相应旧备份。

#### 备份与恢复

备份位于：

```text
<Codex 配置目录>\switch-tools\backups\<时间戳-随机串>\
```

- 每次实际修改一个已经存在的配置时，工具先保存原始 `config.toml`；无变化不会产生备份，首次创建配置时没有“原文件”可保存。
- 备份是未加密的完整 TOML 快照，不包含 Windows 环境变量，也不会自动过期或清理。
- “恢复选中备份”不是合并，而是用备份完整覆盖当前配置；恢复前会再次备份当前配置。
- 恢复可能同时回退 Provider、模型、认证、上下文和未知字段，也可能重新引入旧内联 token，但不会恢复 API Key 环境变量。

不要把含密钥的备份目录同步到不可信云盘，也不要未经检查公开上传。

#### 离线校验配置

它调用当前 PATH 中找到的第一个 `codex` 做解析检查，有超时保护。校验可能因 Codex 版本或路径而跳过；即使成功，也不验证网络、Key、计费、模型权限或服务端重映射。

#### 直接 Responses 探测

这个按钮会向当前简单 Responses Provider 的 `<Base URL>/responses` 发送一个真实 `tools=[]` 小请求：

- 可能产生费用；
- 会把真实 Bearer Key 发给当前 Base URL；
- 只支持简单 `env_key` 或无认证 Provider；
- 不测试 streaming、完整 agent、工具、MCP、hooks、高级 headers/query 或 Codex 的全部客户端行为；
- 输出脱敏只是尽力而为，公开错误信息前仍应人工检查。

公网 Base URL 必须优先使用 HTTPS。程序对非本机 `http://` 只会警告而不会强制阻止，继续探测可能明文传输 Bearer Key。只有受信任的 `localhost` 服务才适合 HTTP。

#### 创建桌面快捷方式

它创建或更新桌面的 `Codex 切换工具.lnk`，指向当前 EXE 并使用内嵌图标。若同名快捷方式指向别处，GUI 会先确认。

- 移动或删除 EXE 后快捷方式会失效，需要在新位置重新创建；
- 企业策略禁用 Windows Script Host、桌面不可写或被重定向时，创建可能失败；
- 它不会创建开始菜单项，也不会自动固定到任务栏。

## 常见操作配方

### 只开启或关闭长上下文

1. 状态总览确认当前 Provider、模型和已有上下文。
2. 打开“上下文窗口”。
3. 优先使用可用的自动目录模式；否则只使用经模型/服务商文档确认的预设或自定义值。
4. 刷新状态，确认 `工具管理上下文：是`。
5. 重启 Codex。
6. 想关闭时点击“恢复之前 / 模型默认”，再重启。

### 从内置 OpenAI 切换到第三方 Provider

1. 保存 Provider 定义。
2. 保存与其 `env_key` 同名的 User API Key。
3. 选择 Provider，刷新模型列表，选择目标模型，应用选择。
4. 检查生成的目录和上下文；未知模型先核实服务商限制。
5. 可选：先做离线校验；只有确认 Base URL 和费用后才做真实探测。
6. 完全退出并重启 Codex。

### 从第三方 Provider 回到内置 OpenAI

1. 点击“恢复内置 OpenAI”。
2. 检查状态页，确认工具管理的目录和上下文已恢复到接管前状态；此前的手动覆盖仍需自行核实。
3. 重启 Codex，并确认原有 OpenAI 登录仍有效。
4. 自定义 Provider 和 User Key 会保留；若确实不再需要 Key，可另行删除 User Key。

### 配置失败后回滚

1. 不要继续反复改动；先打开“密钥、备份与诊断”。
2. 在备份下拉框按操作说明选择目标快照。
3. 点击“恢复选中备份”，确认整文件覆盖。
4. 如恢复的 Provider 使用环境变量，另行检查相应 User/Machine Key，因为备份不包含环境变量。
5. 重启 Codex。

## 切换后必须新建任务吗？

**通常不必。** 完全退出 Codex/VS Code，重新启动后，再打开原任务可以继续使用。

但有三种例外需要留意：

- 原任务或界面保存了自己的模型选择时，它可能继续覆盖用户配置；请在状态页和 Codex 界面两边核对。
- 原任务已经自动压缩过历史时，扩大窗口不会恢复此前丢失的原始上下文。
- 想做严格的切换验证，最好先建一个短的新任务测试 Provider、模型和上下文，再回原任务继续。

## 配置优先级与“真正调用了什么”

状态页只展示用户持久配置预计让下次启动采用的值。运行时还可能受以下因素影响：

- CLI 的 `-c`、`-m`、`--profile` 等临时参数；
- 可信项目配置中允许覆盖的字段；项目级配置不能覆盖 Provider/认证相关字段；
- 桌面端 UI 或已有任务保存的选择；
- Provider 对模型别名的服务端重映射。

因此本工具不会把“请求模型 ID”说成“已证明的实际后端模型”。

Codex 官方配置说明：

- [Config basics](https://developers.openai.com/codex/config-basic/)
- [Configuration reference](https://developers.openai.com/codex/config-reference/)
- [Authentication](https://developers.openai.com/codex/auth/)

## 数据位置与安全边界

| 数据 | 默认位置 | 是否加密 | 是否随配置备份恢复 |
|---|---|---:|---:|
| Codex 用户配置 | `%USERPROFILE%\.codex\config.toml` | 否 | 是，整文件 |
| 工具配置备份 | `.codex\switch-tools\backups` | 否 | 不适用 |
| Provider 模型目录与发现缓存 | `.codex\switch-tools` 下，按 Provider 分开保存 | 否，不保存 API Key | 不是整文件配置备份的一部分 |
| User API Key | Windows User 环境变量 | 否 | 否 |
| GUI 临时内嵌核心 | `%LOCALAPPDATA%\CodexSwitchTools\Runtime` | 否，限制当前用户与 SYSTEM | 否，退出时尽力清理 |
| 桌面快捷方式 | Windows 桌面 | 否 | 否 |

普通配置写入使用并发哈希检查、同目录临时文件、同盘原子替换、唯一备份和可用时的 Codex 解析；失败会尝试回滚。自定义 ACL、文件属性或加密元数据不保证在替换后完全保留。

不要为了绕过权限错误而以管理员身份运行。高级 `-ConfigPath` 可以指向任意可写绝对路径，提权会扩大误操作范围。

## 常见问题排查

### 改完没有生效

1. 完全退出 Codex、VS Code 和长期存活的启动器，而不是只关闭一个标签页。
2. 重新打开工具并刷新状态，确认持久配置已经写入。
3. 检查是否有 CLI 参数、profile、可信项目配置或 UI 选择覆盖。
4. Key 刚写入时，必要时注销 Windows，让新进程继承 User 环境变量。

### DeepSeek 下仍显示“自定义”，或出现 OpenAI 模型菜单

1. 确认运行的是 v1.2.0 或更新版，并在工具里重新选 Provider、模型，再“应用选择”。
2. 检查状态中的模型目录已由本工具管理，然后完全退出并重启 Codex。
3. 部分 Codex 桌面版本可能仍显示“自定义”；这不是对实际后端身份的判断。不要在 DeepSeek 下选择原生菜单中的 GPT 模型。
4. 检查 profile、已有任务和 UI 保存的模型是否覆盖用户配置；必要时用一个短的新任务验证。
5. 工具只能控制自己写入的配置，不能保证每个 Codex 版本的原生菜单呈现完全相同。

### 刷新后没有新模型，或视觉模型不能收图片

- `/models` 返回的是这个端点和账户可见的模型，不是所有服务商的公共模型合集；物理所未部署的模型不会因为官方发布就自动可用。
- 未提供 `/models` 的服务需要使用高级手动模型；401/403 则先检查 Key、权限和 Base URL。
- 模型 ID 本身不能证明图片能力；未知模型不会自动标成视觉模型。官方已验证视觉模型之外，需先确认服务端和 Codex 接口均支持图片。
- 刷新列表不会自动改动已选模型，确认后还需要“应用选择”和重启。

### Key 显示存在但请求仍 401

- 核对 Provider 的 `env_key` 与密钥页变量名是否完全一致；
- 检查 Process、User、Machine 是否存在同名不同值；
- 确认 Key 属于当前服务商和模型；
- 关闭旧进程后重试。

### “按目录开启长上下文”不可用

常见原因是状态为 `UI / 模型默认`、当前不是内置 OpenAI、设置了 `model_catalog_json`，或本机目录没有比默认值更大的可信上限。此时工具会拒绝猜测，这是预期保护。

### 任务栏或快捷方式仍显示旧图标

Windows 可能缓存 EXE 和固定项图标：

1. 退出旧版本程序；
2. 用 v1.1.1 或更新的 EXE 覆盖固定位置文件；
3. 删除旧桌面快捷方式，再用 GUI 重新创建；
4. 如果固定过任务栏，先取消固定，启动新 EXE 后再固定；
5. 仍未刷新时，重启 Windows 资源管理器或注销一次。

### 校验显示“已跳过”

这不等于失败，也不等于配置正确。确认 Codex 已安装、PATH 指向预期版本；随后可重启 Codex观察实际解析结果。真实探测只在明确理解其网络和计费风险后使用。

### 恢复后 Key 不见了或变成旧认证

备份恢复会整体回退 TOML，但不会恢复环境变量。检查备份是否重新引入旧 `experimental_bearer_token`，并单独核对 User/Machine 环境变量。

## 命令行版

保留以下入口：

- `Codex-Switch-Tools.bat`：交互式文本菜单；
- `Codex-Switch-Tools.ps1`：非交互自动化核心；
- `Toggle-CodexLongContext.*`：仅为旧流程兼容保留。

> [!WARNING]
> 新用户不要优先使用 `Toggle-CodexLongContext.*`。旧脚本默认不遵循新的 `CODEX_HOME` 路由，也没有当前核心的上下文所有权标记、并发检查和完整回滚保护。

示例：

```powershell
.\Codex-Switch-Tools.ps1 -Action Status -Json
.\Codex-Switch-Tools.ps1 -Action ConfigureProvider -ProviderId cst_demo -ProviderName Demo -BaseUrl https://example.com/v1 -EnvKey CODEX_DEMO_API_KEY
.\Codex-Switch-Tools.ps1 -Action ListModels -ProviderId deepseek -Json
.\Codex-Switch-Tools.ps1 -Action RefreshModels -ProviderId deepseek -Json
.\Codex-Switch-Tools.ps1 -Action SetProvider -ProviderId deepseek -Model deepseek-v4-pro -ManageModelCatalog
.\Codex-Switch-Tools.ps1 -Action SetContext -ContextWindow 872000 -AutoCompactLimit 800000
.\Codex-Switch-Tools.ps1 -Action ResetContext
.\Codex-Switch-Tools.ps1 -Action UseOpenAI
.\Codex-Switch-Tools.ps1 -Action ListBackups -Json
```

`ListModels` 不联网；`RefreshModels` 会向所选 Provider 发出模型列表请求。`SetProvider -ManageModelCatalog` 启用与 GUI 相同的独立目录管理；没有此标志的脚本调用保留原行为。未知模型需要显式 `-AllowUnverifiedModel`；接管已有非本工具目录需要显式 `-ReplaceExistingCatalog`，不要在不核实的情况下批量添加这两个确认标志。

不要通过命令行参数传 API Key。核心的 `SetApiKey` 动作只接受标准输入。BAT 会从 PATH 选择 PowerShell，文本菜单创建同名桌面快捷方式时可能直接覆盖；日常使用更推荐 EXE。

## 兼容性与测试

目标环境：Windows 10/11 x64、.NET Framework 4.x、Windows PowerShell 5.1。不需要额外安装 PowerShell 7；已安装时会优先使用符合版本信息检查的标准安装。Windows Script Host 仅在创建快捷方式时需要。CI 的 Windows runner 与本地隔离测试不能等同于所有 Windows 10/11、ARM64 或企业安全策略环境的认证；这些组合需以实际验证为准。

核心隔离测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh.exe -NoProfile -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ModelCatalog.ps1
pwsh.exe -NoProfile -File .\tests\Test-ModelCatalog.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CodexCatalogIntegration.ps1
pwsh.exe -NoProfile -File .\tests\Test-CodexCatalogIntegration.ps1
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
- GUI 单文件构建、四个中文标签页、内嵌核心、应用/窗口图标和 PS5 fallback；
- GUI/配置路径含空格、`&`、括号和中文；
- UTF-8 BOM/无 BOM、CRLF/LF、注释、数组和多行字符串；
- Provider → OpenAI → Provider；
- 模型列表读取/刷新、本地 mock、按 Provider 分离目录、未知模型确认和目录/上下文恢复；
- 上下文开启/恢复、手工值保护；
- Key 标准输入、零回显和删除确认；
- 备份列表/整文件恢复；
- 校验失败和异常自动回滚；
- loopback mock 的真实 Codex `/v1/responses` 路由；
- 安全直接探测；
- 仓库密钥和私人路径扫描。

GitHub Actions 在 Windows 上运行 PowerShell 5.1、PowerShell 7 和 GUI 构建自测，并用固定版本 Codex CLI `0.150.1` 验证生成目录确实能被 `app-server` 的 `model/list` 读取。集成测试只发送初始化和模型列表 RPC，使用临时配置、dummy Key 和 loopback 路由，不创建任务或发送推理请求。本机没有 Codex 时可选集成测试会明确跳过；CI 则必须安装并通过指定版本。另已本机验证 Codex `0.152.1` 的同一目录读取行为。真实 Provider Key 和可能计费的请求不会进入 CI。tag 发行流程先通过这些检查，再从该 tag 源码构建 EXE、生成校验文件并上传到 GitHub Releases。

## 从源码构建中文 EXE

系统要求：64 位 Windows，带 .NET Framework 4.x 的 `csc.exe`。

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\build-gui.ps1
```

输出：

- `dist/CodexSwitchTools.exe`
- `SHA256SUMS.txt`

构建脚本会把当前 PowerShell 核心和多尺寸 ICO 作为资源嵌入 EXE，同时把 ICO 写入 Windows 可执行文件资源，因此窗口和任务栏使用相同图标。

## 文件说明

- `dist/CodexSwitchTools.exe`：推荐的中文桌面版；
- `assets/CodexSwitchTools.ico`：16–256 px 多尺寸 Windows 应用图标；
- `assets/CodexSwitchTools-icon-source.png`：图标源图与 README 预览；
- `src/CodexSwitchTools.Gui.cs`：WinForms GUI 源码；
- `src/CodexSwitchTools.Gui.manifest`：无需管理员权限的应用清单；
- `build-gui.ps1`：可复现构建脚本；
- `Codex-Switch-Tools.bat`：文本菜单入口；
- `Codex-Switch-Tools.ps1`：唯一配置、备份和探测核心；
- `tests/Run-Tests.ps1`：核心回归测试；
- `tests/Test-ModelCatalog.ps1`：模型发现、目录隔离与恢复回归测试；
- `tests/Test-CodexCatalogIntegration.ps1`：可选 Codex 原生目录/图片能力读取验证，无推理请求；
- `tests/Test-GuiSmoke.ps1`：GUI 构建、隐藏窗口和图标自测；
- `tests/Test-LocalProviderRoute.ps1`：本地 mock 路由测试；
- `tests/Test-RepositoryHygiene.ps1`：仓库敏感信息扫描。

## 维护者发布发行版

1. 更新 `VERSION`、`CHANGELOG.md` 和对应 `releases/v<版本>.md`，完成本地测试。
2. 提交并推送代码，再为同一提交创建并推送对应 `v<版本>` tag；tag 必须与 `VERSION` 一致。
3. `Windows executable release` 工作流先调用兼容性测试，再重新构建 EXE，上传 `CodexSwitchTools.exe` 与 `SHA256SUMS.txt`。只有发布 job 获得仓库内容写权限，测试 job 只读。
4. 检查工作流结果、发行版 Assets 和下载后哈希，再向用户提供下载链接。源码 ZIP 不代替可执行文件附件。

发布后的 EXE 和哈希按版本保留；重跑已发布版本不会静默覆盖附件，修复应发布新版本。工作流使用 GitHub 提供的临时 `GITHUB_TOKEN`，不需要把个人 token 或任何 Provider API Key 写进仓库。

## 免责声明

本项目不是 OpenAI 官方工具。Provider、模型、上下文上限和第三方 API 的可用性、费用与服务条款由相应服务商决定。EXE 没有商业代码签名；哈希只能证明文件与同一发布内容一致，不能替代可信下载来源。
