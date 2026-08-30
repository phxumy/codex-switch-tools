# Codex Long Context Toggle（Windows）

一个双击即可使用的小工具，用来在 Codex 的模型默认上下文和长上下文之间切换。

> 当前长上下文参数为 **872K**，并在约 **800K** token 时触发自动压缩。已在 Windows、Codex CLI 0.150.1、`gpt-5.6-sol` 上测试。Codex 和模型上限可能更新，请在使用新版模型时留意官方说明。

## 功能

- 一键开启长上下文：
  - `model_context_window = 872000`
  - `model_auto_compact_token_limit = 800000`
- 再次运行会关闭长上下文，并删除这两个覆盖项，让 Codex 恢复模型默认值。
- 每次修改前，为 `%USERPROFILE%\.codex\config.toml` 创建带时间戳的备份。
- 将配置写入 TOML 顶层，不影响其他 Codex 设置。
- 写入后调用本机 Codex 解析配置；校验失败会自动恢复。
- 兼容 Windows PowerShell 5.1。

## 使用方法

1. 下载本仓库，并确保下面两个文件位于同一文件夹：
   - `Toggle-CodexLongContext.bat`
   - `Toggle-CodexLongContext.ps1`
2. 双击 `Toggle-CodexLongContext.bat`。
3. 看到成功提示后，完全退出并重新打开 Codex 桌面端。
4. 需要切回默认上下文时，再双击一次。

如需桌面入口，右键 BAT，选择“发送到 → 桌面快捷方式”。

## 切换后必须新建聊天吗？

不必。重启 Codex 后可以重新打开原来的任务继续使用。

但如果任务已经发生过自动压缩，切换到长上下文不会恢复此前被压缩掉的原始历史。只有在希望从第一条消息开始完整利用长窗口时，才建议新建任务。

## 安全设计

- 只管理 `model_context_window` 和 `model_auto_compact_token_limit`。
- 每次修改保留时间戳备份，例如：
  `config.toml.context-toggle-20260830-210000-000.bak`
- 使用同目录临时文件替换配置。
- 关闭长上下文后不写死默认窗口大小，而是移除覆盖项，以便跟随 Codex 后续更新。
- BAT 只对同目录的辅助脚本使用 `ExecutionPolicy Bypass`，不会修改系统执行策略。

## 要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1 或更高版本
- 已安装 Codex CLI 或 Codex 桌面端

配置字段说明可参考 [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)。

## 文件

- `Toggle-CodexLongContext.bat`：双击入口。
- `Toggle-CodexLongContext.ps1`：备份、切换、校验和回滚逻辑。
