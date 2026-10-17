# Android 安装弹框自动确认（多 ROM）+ 静默安装
# 背景: 各厂商 ROM 对每次 adb 安装强制弹「未知来源风险确认」框, 无法从系统设置关闭。
#       vivo OriginOS / 小米 HyperOS(MIUI) / OPPO ColorOS / 原生 AOSP 文案各异。
# 原理: uiautomator 抓取弹框坐标 + input tap 自动勾选风险复选框并点确认按钮。
# 前提: 手机亮屏且解锁(锁屏时弹框无法自动点击); adb 已连接。
#
# 用法:
#   .\install-confirm.ps1 -Watch -Minutes 240   # 常驻监视: 自动确认任何安装弹框(配 flutter run 用,
#                                              # 其自带安装的弹框也会被点掉)
#   .\install-confirm.ps1                       # 一次性: push + 静默安装 <当前目录>\build\...\app-debug.apk
#   .\install-confirm.ps1 -Apk <路径> -Launch   # 安装指定 APK 并自动启动应用
#   .\install-confirm.ps1 -Device <serial> ...  # 多设备在线时必须指定目标
# 注意: -Watch 挂着时不要再跑一次性模式, 两边同时点会冲突。
param(
    [string]$Device,    # 缺省自动探测: 恰好一台在线设备时用它, 多台/零台报错
    [string]$Apk,       # 缺省取当前目录下 build\app\outputs\flutter-apk\app-debug.apk
    [string]$Package,   # 缺省从 android\app\build.gradle* 解析 applicationId (仅 -Launch 需要)
    [switch]$Launch,
    [switch]$Watch,
    [int]$Minutes = 120
)

# uiautomator XML 为 UTF-8；GBK 控制台会把 adb 输出解码成乱码，中文匹配全部失效，
# 必须强制以 UTF-8 解码（无控制台环境下降级为原行为）
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ---------- 多 ROM 弹框匹配表（有序, 首个命中生效; 支持新 ROM = 加一行） ----------
$script:matchTable = @(
    @{ Name = 'vivo OriginOS(实测)'; Risk = '已了解应用的风险检测结果'; Button = '继续安装' },
    @{ Name = '通用';                Risk = $null;                        Button = '继续安装' },
    @{ Name = '小米系';              Risk = $null;                        Button = '仍然安装' },
    @{ Name = '通用2';               Risk = $null;                        Button = '仍要安装' },
    @{ Name = 'AOSP';                Risk = $null;                        Button = '安装' }
)

$script:deviceApk = "/data/local/tmp/install-confirm.apk"
$script:deviceUi  = "/data/local/tmp/install-confirm.xml"

# ---------- 设备探测 ----------
if (-not $Device) {
    $online = @((adb devices) | Where-Object { $_ -match '^\S+\s+device\b' } | ForEach-Object { ($_ -split '\s+')[0] })
    if ($online.Count -eq 1) {
        $Device = $online[0]
    } elseif ($online.Count -eq 0) {
        Write-Error "没有在线的 adb 设备, 请先连接(或等无线设备重连)后重试"; exit 1
    } else {
        Write-Error ("检测到多台设备, 请用 -Device 指定其一: " + ($online -join ', ')); exit 1
    }
}

function Get-UiXml {
    adb -s $Device shell uiautomator dump $script:deviceUi | Out-Null
    (adb -s $Device shell cat $script:deviceUi) -join ''
}
function Tap-Node([string]$textMatch, [string]$xml) {
    $m = [regex]::Match($xml, 'text="' + $textMatch + '"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
    if ($m.Success) {
        $x = ([int]$m.Groups[1].Value + [int]$m.Groups[3].Value) / 2
        $y = ([int]$m.Groups[2].Value + [int]$m.Groups[4].Value) / 2
        adb -s $Device shell input tap $x $y
        return $true
    }
    return $false
}
function Confirm-Dialog {
    # 遍历匹配表确认当前安装弹框: 有 Risk 复选框的规则先勾选(未勾时)再点 Button;
    # 无 Risk 的规则直接点 Button。返回命中的规则名, 全未命中返回 $null。
    $xml = Get-UiXml
    foreach ($rule in $script:matchTable) {
        if ($rule.Risk) {
            $cb = [regex]::Match($xml, 'text="' + $rule.Risk + '"[^>]*checked="(\w+)"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
            if (-not $cb.Success) { continue }
            if ($cb.Groups[1].Value -ne 'true') {
                $x = ([int]$cb.Groups[2].Value + [int]$cb.Groups[4].Value) / 2
                $y = ([int]$cb.Groups[3].Value + [int]$cb.Groups[5].Value) / 2
                adb -s $Device shell input tap $x $y
            }
            for ($k = 0; $k -lt 12; $k++) {
                Start-Sleep -Milliseconds 400
                if (Tap-Node $rule.Button (Get-UiXml)) { return $rule.Name }
            }
        } else {
            if (Tap-Node $rule.Button $xml) { return $rule.Name }
        }
    }
    return $null
}
function Test-InstallDialogFocused {
    # 前台门控: 焦点明确是其他应用时才跳过 dump(防误点+防空转)。
    # 焦点信息缺失(输出为空或 mCurrentFocus=null)时必须放行——流式安装
    # (flutter run 的 Performing Streamed Install)会挤占 adb 通道, dumpsys
    # 常返回残缺结果, 此时拦截会漏掉弹框(2026-09-03 实测翻车)。
    $focus = (adb -s $Device shell "dumpsys window | grep mCurrentFocus") -join ' '
    if ([string]::IsNullOrWhiteSpace($focus)) { return $true }
    if ($focus -match 'mCurrentFocus=null') { return $true }
    return ($focus -match 'install')
}

# ---------- 常驻监视模式 ----------
if ($Watch) {
    Write-Host "监视安装弹框中(设备 $Device), 持续 $Minutes 分钟, 开始于 $((Get-Date).ToString('HH:mm:ss'))"
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
        if ((Test-InstallDialogFocused) -and ($name = Confirm-Dialog)) {
            Write-Host "已自动确认安装弹框 [$name] $((Get-Date).ToString('HH:mm:ss'))" -ForegroundColor Cyan
        }
        Start-Sleep -Milliseconds 600
    }
    adb -s $Device shell rm -f $script:deviceUi
    exit 0
}

# ---------- 一次性安装模式 ----------
if (-not $Apk) { $Apk = Join-Path (Get-Location).Path "build\app\outputs\flutter-apk\app-debug.apk" }
if (-not (Test-Path $Apk)) { Write-Error "APK 不存在: $Apk (先 flutter build apk --debug, 或用 -Apk 指定路径)"; exit 1 }
if (-not $Package) {
    # 从当前项目 build.gradle(.kts) 解析 applicationId, 兼容 kts「=」与 groovy 两种写法
    $gradle = Get-ChildItem "android\app\build.gradle*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gradle) {
        $m = Select-String -Path $gradle.FullName -Pattern 'applicationId\s*(?:=\s*)?"([^"]+)"' | Select-Object -First 1
        if ($m) { $Package = $m.Matches[0].Groups[1].Value }
    }
}

Write-Host "push $Apk -> $Device" -ForegroundColor Cyan
adb -s $Device push $Apk $script:deviceApk
if ($LASTEXITCODE -ne 0) { Write-Error "push 失败"; exit 1 }

$outFile = Join-Path $env:TEMP "install-confirm-out.txt"
$p = Start-Process adb -ArgumentList @('-s', $Device, 'shell', 'pm', 'install', '-r', '-t', $script:deviceApk) `
      -NoNewWindow -RedirectStandardOutput $outFile -PassThru

while (-not $p.HasExited) {
    Confirm-Dialog | Out-Null
    Start-Sleep -Milliseconds 400
}

adb -s $Device shell rm -f $script:deviceApk $script:deviceUi
$result = (Get-Content $outFile -Raw).Trim()

if ($result -eq 'Success') {
    Write-Host "静默安装成功" -ForegroundColor Green
    if ($Launch) {
        if (-not $Package) { Write-Warning "未能从 android\app\build.gradle* 解析 applicationId, 跳过启动"; exit 0 }
        adb -s $Device shell monkey -p $Package -c android.intent.category.LAUNCHER 1 | Out-Null
    }
} else {
    Write-Host "安装失败: $result" -ForegroundColor Red
    exit 1
}
