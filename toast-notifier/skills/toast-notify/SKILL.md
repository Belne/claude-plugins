---
name: toast-notify
description: 弹出 Windows Toast 系统通知。当任务完成、构建/测试出结果、需要用户参与或决策、以及回合结束前写入任务摘要时使用。触发词：通知、弹窗、提醒用户。
---

# Windows Toast 通知（toast-notifier 插件）

本机已安装 toast-notifier 插件，通过 WinRT API 弹系统通知（无第三方依赖）。

> 路径约定：`<插件根目录>` = 本 skill 目录（`skills\toast-notify\`）上两级（含 `.claude-plugin\` 的目录），按实际安装位置解析，勿硬编码绝对路径。

## 主动弹出自定义内容

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<插件根目录>\hooks\toast.ps1" -Title "标题" -Message "内容"
```

## 回合结束摘要（Stop hook 自动读取）

结束回合前，若有值得告知的结果，写入状态文件（10 分钟内有效、用后即删；第一行为适用目录，`*` 表示任意项目）：

```powershell
Set-Content "$env:USERPROFILE\.claude\toast-summary.txt" -Value "*`n✅ 构建成功：APK 已输出，12 个测试全部通过" -Encoding utf8
```

不写则 Stop 弹默认文案「任务已完成」。

## 点击通知恢复会话（自动，无需操作）

通知可点击：点击后自动回到该会话所在的 Windows Terminal 窗口和标签（多会话并行时各自独立路由）；会话已退出时自动在新标签执行 `claude --resume <session_id>` 恢复上下文。机制：

- toast.ps1（Stop/Notification hook）把 session_id ↔ WT_SESSION/tab 标题/claude PID 写入 `HKCU\Software\ClaudeCode\Sessions\<session_id>`，并动态注册会话专属 AUMID（通知按会话分组，DisplayName = Claude Code - 项目名；7 天未更新自动清理）
- 点击 → 系统 DCOM 启动 `hooks/focus.exe --session <id>`（COM CustomActivator；这台 Win10 的 Toast protocol activation 被沙箱拒绝，CustomActivator 是唯一通路）→ **AttachConsole(claude PID) 实时读取该会话进程的控制台标题**（WT 每 tab 一个 ConPTY，claude 的控制台标题即 tab 标题）→ UIA 按核心会话名（剥离 ✳◐◑ 状态符）在所有 WT 窗口里定位并切换 tab → 三级前台化（SetForegroundWindow → TOPMOST toggle → SwitchToThisWindow）
- 重新编译 focus.exe：`csc /target:winexe /r:"GAC 绝对路径\UIAutomationClient.dll" /r:"...UIAutomationTypes.dll" focus.cs`（csc 默认路径找不到这两个 dll）
- 排查日志：`~/.claude/toast-focus.log`
- 已知取舍：hook 注册时常拿不到 tab 标题（独立 pty 所限，注册表 tab_title 留空）——v1.1.0 起点击时实时从 claude 进程控制台取标题，空注册的老会话同样正确路由；仍存的限制：同标题多 tab 时选第一个，claude 进程已死时退化为窗口级聚焦 + `claude --resume`

## 注意

- 仅支持 Windows（WinRT Toast）
- 每次修改 toast.ps1 后必须重新保存为 UTF-8 带 BOM（PS 5.1 中文必需）
- Stop / Notification 事件由插件 hooks/hooks.json 自动触发，无需手动调用
