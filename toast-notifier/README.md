# toast-notifier

Claude Code 插件：在任务完成或需要用户参与时弹出 Windows Toast 系统通知。

## 功能

- **Stop hook**：每回合结束弹窗；若 Claude 在回合结束前写入了摘要文件（`~/.claude/toast-summary.txt`，10 分钟内有效、用后即删），则显示该摘要而非固定文案
- **Notification hook**：权限确认时弹窗（「等待输入」类空闲提醒已过滤为静默）
- **自由内容**：Claude 可随时调用 toast.ps1 弹出任意标题与内容（用法见 `skills/toast-notify/SKILL.md`）
- **点击通知恢复会话**：通知按会话独立分组（Claude Code - 项目名），点击后自动回到该会话所在的 Windows Terminal 窗口和标签（多会话并行时各自精确路由）；会话已退出时自动在新标签执行 `claude --resume <session_id>` 恢复上下文（60 秒防抖）。原理：hook 把 session_id ↔ WT_SESSION/tab 标题/claude PID 写入 `HKCU\Software\ClaudeCode\Sessions\`，点击经 COM CustomActivator（这台 Win10 上 Toast 的 protocol activation 被沙箱拒绝，CustomActivator 是唯一通路）DCOM 启动 `focus.exe --session <id>` 完成 UIA 切 tab + 强制前台。排查日志：`~/.claude/toast-focus.log`

## 安装 / 移植到其他设备（Windows）

- **方式一·市场安装（推荐）**：`/plugin marketplace add <用户名>/<市场仓库>` → `/plugin install toast-notifier@<市场名>`。**无需任何手动初始化**——focus.exe 随插件附带，首次 Stop/Notification hook 若发现它或全局 AUMID 缺失会自动补编译/注册（toast.ps1 内置自愈安装）。
- **方式二·手动拷贝源码目录**：把整个 `plugins-local` 文件夹复制到新设备的 `~/.claude/plugins-local/`（OneDrive / Git 同步可免手动），再跑一次初始化脚本（自动合并 settings.json 的市场配置——已有配置原样保留——并完成编译和注册，全程 HKCU 无需管理员；此脚本仅存在于源码目录）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\plugins-local\toast-notifier\setup-device.ps1"
```

3. 重启 Claude Code 生效

> focus.exe 是 .NET Framework 4 程序，Win10+ 开箱可跑；重编译只为与 focus.cs 保持同步。

## 维护

- 修改 `hooks/toast.ps1` 后：重存为 UTF-8 带 BOM，并刷新插件缓存（删除 `~/.claude/plugins/` 下对应缓存目录后重启，或通过 `/plugin` 界面更新）
- 仅支持 Windows。macOS/Linux 可在 toast.ps1 中按系统分支改用 `osascript` / `notify-send`

## 目录结构

```
plugins-local/
├── .claude-plugin/marketplace.json      # 本地插件市场（目录源）
└── toast-notifier/
    ├── .claude-plugin/plugin.json       # 插件清单
    ├── hooks/
    │   ├── hooks.json                   # Stop / Notification 事件注册
    │   ├── toast.ps1                    # Toast + 会话注册脚本
    │   ├── focus.cs / focus.exe         # 点击激活器（DCOM 启动，切 tab + 前台化 + resume）
    │   └── install.ps1                  # 编译 + 注册全局 AUMID（被自愈机制调用）
    ├── setup-device.ps1                 # 新设备一键初始化（合并 settings.json + 调 install）
    ├── skills/toast-notify/SKILL.md     # 教 Claude 如何弹自由内容/写摘要
    └── README.md
```
