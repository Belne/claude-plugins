---
name: hot-reload
description: Flutter 热重载调试（常驻 flutter run + 命令管道 + 多 ROM 安装弹框自动确认）。设备与项目参数化，适配任意 adb 设备；改完代码向命令文件追加 r / R / q 即可驱动重载/重启/退出。
---

# Flutter 热重载调试（flutter run 常驻 + 命令管道）

> 路径约定：本文中 `<本 skill 目录>` = 本 SKILL.md 所在目录（安装后的 `...\skills\hot-reload\`），命令中的脚本路径一律相对它解析，勿硬编码绝对路径。

## 背景 / 为什么

- 打整包 + `adb install` 每轮分钟级，拖慢调试迭代。
- 目标工作流：`flutter run` 后台常驻并附着设备，改完代码发送热重载，手机秒级更新。
- ⚠️ `flutter install` 默认走 release 且**不会重新构建**，会把旧 APK 直接装上设备。需要全新 APK 时必须先显式 `flutter build apk --debug`。

## 前置检查（每次现查，勿信记忆里的值）

1. **设备**：`adb devices -l` 现查在线设备，取 serial（USB 直连是硬件 serial 如 `10AE760SUF002Y8`；无线调试是 `IP:5555`，**IP 随网络变化**）。多台在线时所有 adb 命令都要带 `-s <serial>`。
2. **包名 / Activity**：从当前项目读，勿预设——`grep applicationId android/app/build.gradle*`（kts 写 `applicationId = "x"`，groovy 写 `applicationId "x"`）。前台验证：`adb -s <serial> shell "dumpsys activity activities | grep topResumedActivity"`。
3. **命令文件按项目隔离**（防多项目并行会话互踩）：`/tmp/flutter_run_cmds_<项目目录名>.txt`（Git Bash 的 `/tmp` 即用户 Temp）。

## 启动（四步）

0. **挂载安装弹框自动确认 watcher**（必须先做）：多数厂商 ROM 对每次安装强制弹「未知来源风险确认」，`flutter run` 自带的安装步骤会触发并卡住。后台启动 watcher（`run_in_background=true`）：
   ```bash
   powershell -NoProfile -ExecutionPolicy Bypass -File "<本 skill 目录>\scripts\install-confirm.ps1" -Watch -Minutes 240
   ```
   多设备时加 `-Device <serial>`。前提：手机亮屏且解锁（锁屏时弹框无法被自动点击）。watcher 挂着期间不要再跑一次性安装模式，两边同时点会冲突。

1. **创建空的命令文件**（后台 flutter run 从这里读 stdin）：
   ```bash
   > /tmp/flutter_run_cmds_<项目目录名>.txt
   ```

2. **后台启动**（`run_in_background=true`），用 `tail -f` 把文件实时喂给 flutter run 的 stdin：
   ```bash
   tail -f /tmp/flutter_run_cmds_<项目目录名>.txt | flutter run -d <现查的 serial>
   ```
   （Git Bash 的 `/tmp` 即当前用户 Temp 目录，天然按用户隔离）

3. **等待就绪**：启动一个后台 until 循环，grep 第 2 步任务输出文件，出现以下任一标记即已附着：
   - `Flutter run key commands`
   - `A Dart VM Service`
   - `Syncing files to device`

## 热重载 / 热重启 / 退出

向命令文件追加一行：

| 动作 | 命令 |
|---|---|
| 热重载（普通 UI / 逻辑改动） | `echo r >> <命令文件>` |
| 热重启（结构性改动：main()、provider 结构） | `echo R >> <命令文件>` |
| 退出 flutter run 会话 | `echo q >> <命令文件>` |

每次改完代码立即发送 `r`，让用户在设备上实时看到效果。

## 需要全新 APK（非热重载场景，如原生代码/依赖变更后重装）

```bash
flutter build apk --debug
powershell -NoProfile -ExecutionPolicy Bypass -File "<本 skill 目录>\scripts\install-confirm.ps1" -Apk "build\app\outputs\flutter-apk\app-debug.apk" -Launch
```
APK 路径缺省就是 `<当前目录>\build\app\outputs\flutter-apk\app-debug.apk`，包名缺省自动从 build.gradle 解析。装完如需接回热重载会话：`flutter attach -d <serial>`（不再触发安装）。

## 故障处理 / 恢复（全部实测踩坑）

- **flutter run 卡在 Installing / `INSTALL_FAILED_ABORTED: User rejected permissions`**：安装弹框没被点掉。检查 watcher 任务是否活着、手机是否亮屏解锁。
- **watcher 在跑却永远不点弹框**：① 看 watcher 任务输出的中文是否乱码——**乱码 = 编码又坏了**（PS 5.1 GBK 控制台解码 adb 的 UTF-8 XML，中文匹配串全失效；脚本开头 `[Console]::OutputEncoding = UTF8` 是修复，勿删）。② 弹框文案变了：dump 看实际文案（`adb -s <s> shell "uiautomator dump /data/local/tmp/ui.xml && cat /data/local/tmp/ui.xml"`，整串放一个引号里防 Git Bash 路径转换），往脚本 `$script:matchTable` 加一行。
- **手动排查前先 TaskStop watcher**：两个 uiautomator 实例并发会崩（`UiAutomationService already registered`，一方 FATAL），还可能弄断流式安装会话。
- **弹框已确认、App 已启动但 flutter run 无输出**：安装会话被上述崩溃弄断，dart 进程成僵尸。`taskkill //F //PID <dart_pid>` 清掉后重跑 flutter run（APK 已是新的，重跑只为恢复附着）。
- **flutter run 进程退出**（设备断连、构建失败）：Read 任务输出文件定位原因，修复后从「启动」重新执行。
- **脚本文件必须保持 UTF-8 带 BOM**（PS 5.1 中文必需），校验：`head -c 3 文件 | od -A n -t x1` 应为 `ef bb bf`。
- **手动兜底点弹框**：从 dump 的 `bounds="[x1,y1][x2,y2]"` 算中心，`adb -s <s> shell input tap <x> <y>`。
- **会话结束**：先 `q` 退出 flutter run，再 TaskStop 后台任务，避免遗留进程。

## 环境要求 / 示例（换机/换项目按此核对）

- Windows 10+ + PowerShell 5.1（主）/ Git Bash（管道用）；本机 Flutter/JDK/镜像自行确认
- 设备每次现查（`adb devices -l`）：USB 是硬件 serial，无线是 `IP:5555`（IP 随网络变化）
- watcher 权限：用户级 settings.json 应有放行规则指向本 skill 的 install-confirm.ps1（`Bash(powershell -NoProfile -ExecutionPolicy Bypass -File "<install-confirm.ps1 实际路径>:*)`，路径按插件实际安装位置替换）
