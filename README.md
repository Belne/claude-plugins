# claude-plugins

个人 Claude Code 插件市场（Windows 向） / Personal Claude Code plugin marketplace (Windows-focused).

## 安装 / Install

在 Claude Code 中执行：

```
/plugin marketplace add Belne/claude-plugins
/plugin install toast-notifier@belne-plugins
/plugin install flutter-hot-reload@belne-plugins
```

## 插件

### toast-notifier（v1.0.1）

任务完成或需要用户参与时弹出 **Windows Toast 系统通知**：

- **Stop hook**：每回合结束弹窗；Claude 可在回合结束前写入摘要文件，弹窗显示摘要而非固定文案
- **Notification hook**：权限确认等需要输入时弹窗
- **自由内容**：Claude 可随时弹出任意标题与内容
- **点击通知回到会话**：通知按会话分组，点击自动切回对应的 Windows Terminal 标签；会话已退出时自动 `claude --resume` 恢复
- 无第三方依赖（WinRT API），focus.exe 随插件附带，缺失时 hook 自愈补编译注册

详见 [toast-notifier/README.md](toast-notifier/README.md)。

### flutter-hot-reload（v1.1.0）

**Flutter 热重载调试**工作流（秒级迭代，替代分钟级的整包安装）：

- 常驻后台 `flutter run` + 命令文件管道，改完代码追加 `r` / `R` / `q` 即可热重载 / 热重启 / 退出
- `install-confirm.ps1` 自动确认各厂商 ROM 的「未知来源风险」安装弹框（vivo OriginOS 实测，小米/OPPO/AOSP 内置匹配表，新 ROM 加一行即可）
- 设备 / APK / 包名全部参数化，任意 adb 设备、任意 Flutter 项目可用
- 一次性静默安装模式：`-Apk <路径> [-Launch]`

详见 [flutter-hot-reload/README.md](flutter-hot-reload/README.md) 与技能文档。

## 环境要求

- Windows 10+（PowerShell 5.1；flutter-hot-reload 的管道部分用 Git Bash）
- flutter-hot-reload 另需 Flutter SDK + adb

## License

[MIT](LICENSE)
