# flutter-hot-reload

Flutter 热重载调试插件：常驻 `flutter run` + 命令管道 + 多 ROM 安装弹框自动确认。设备与项目参数化，可移植到任意 adb 设备 / 任意 Flutter 项目。

## 结构

```
flutter-hot-reload/
├── .claude-plugin/plugin.json
└── skills/hot-reload/
    ├── SKILL.md                  # 工作流文档（前置检查、四步启动、r/R/q、故障处理）
    └── scripts/install-confirm.ps1
```

## 两个脚本模式

- `install-confirm.ps1 -Watch -Minutes N`：常驻监视，自动确认任何安装弹框（配 `flutter run` 用）
- `install-confirm.ps1 [-Apk 路径] [-Device serial] [-Launch]`：一次性 push + 静默安装 + 可选启动

设备缺省自动探测（恰好一台在线即用）；APK 路径缺省 `<CWD>\build\app\outputs\flutter-apk\app-debug.apk`；包名缺省从 `android\app\build.gradle*` 解析。

## 移植到新设备 / 新 ROM

1. **换设备**：无需改任何文件——设备现查（`adb devices -l`），多设备时传 `-Device`。换的是无线设备则注意 IP 会变。
2. **换 ROM（弹框文案不同）**：把新弹框 dump 出来看文案（手机亮屏解锁状态下）：
   ```bash
   adb shell "uiautomator dump /data/local/tmp/ui.xml && cat /data/local/tmp/ui.xml"
   ```
   往 `install-confirm.ps1` 的 `$script:matchTable` 头部加一行 `@{ Name='xx'; Risk='<复选框文案或$null>'; Button='<按钮文案>' }`。
3. **装本插件（新机器）**：
   - 市场安装：`/plugin marketplace add <用户名>/<市场仓库>` → `/plugin install flutter-hot-reload@<市场名>`
   - 或手动拷贝 `flutter-hot-reload/` 目录，在所在市场的 marketplace.json 登记，settings.json `enabledPlugins` 启用
   - 加用户级放行规则（路径按插件实际安装位置替换）：
   ```
   Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "<install-confirm.ps1 实际路径>:*)
   ```

## 维护注意

- `install-confirm.ps1` 必须保持 **UTF-8 带 BOM**（PS 5.1 中文必需），且开头 `[Console]::OutputEncoding = UTF8` 不可删（GBK 控制台下 adb 输出解码修复）。校验：`head -c 3 install-confirm.ps1 | od -A n -t x1` → `ef bb bf`
