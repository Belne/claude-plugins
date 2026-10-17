# Claude Code 插件 toast-notifier：弹出 Windows Toast 系统通知
# 由插件 hooks/hooks.json 中的 Stop / Notification 事件自动触发，也可手动调用
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File toast.ps1 -Event stop
#   powershell -NoProfile -ExecutionPolicy Bypass -File toast.ps1 -Event notify
#   powershell -NoProfile -ExecutionPolicy Bypass -File toast.ps1 -Title "标题" -Message "任意内容"
# 文案优先级：
#   stop    状态文件摘要（10 分钟内）> 固定文案
#   notify  stdin hook JSON 的 message 字段 > 固定文案
#   custom  显式传入的 -Title / -Message

param(
  [string]$Event = 'stop',
  [string]$Title,
  [string]$Message
)

# 状态文件：Claude 在回合结束前写入的本次任务摘要（第一行=适用目录或 *，其余行=摘要）
$summaryFile = Join-Path $env:USERPROFILE '.claude\toast-summary.txt'

# 读取 stdin 上的 hook JSON（Stop 带 cwd，Notification 带 message）
$hook = $null
try {
  if ([Console]::IsInputRedirected) {
    $raw = [Console]::In.ReadToEnd()
    if ($raw -and $raw.Trim().StartsWith('{')) { $hook = $raw | ConvertFrom-Json }
  }
} catch { }

# ===== 自愈安装：focus.exe 或全局 AUMID 注册缺失时当场补齐 =====
# （新设备拷贝插件后无需手动安装，首次 Stop/Notification hook 自动完成；
#   检测仅两个 Test-Path，常态开销可忽略；能跑到这里说明插件已被加载，
#   settings.json 的市场注册必然已生效，无需也无法在此处理）
try {
  $needInstall = (-not (Test-Path (Join-Path $PSScriptRoot 'focus.exe'))) -or
    (-not (Test-Path 'HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ToastNotifier'))
  if ($needInstall) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install.ps1')
  }
} catch { }

# ===== 会话注册：点击通知回到原 WT 标签（多会话并行路由）=====
# 记录 session_id ↔ WT_SESSION/tab 标题/工作目录 的映射，并注册会话专属
# AUMID + COM CustomActivator（LocalServer32 = focus.exe --session <id>），
# 点击通知时系统 DCOM 启动 focus.exe 并带会话号，实现每条通知精确路由回原标签。
$sessionAumid = $null
try {
  $sessionId = ''
  if ($hook -and $hook.session_id) { $sessionId = [string]$hook.session_id }
  if ($sessionId -and $env:WT_SESSION) {
    $shortId = $sessionId.Substring(0, [Math]::Min(8, $sessionId.Length))
    $aumid = "ClaudeCode.Session.$shortId"
    # CLSID 由 session_id 的 MD5 确定性生成（同会话重复注册结果一致）
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hash = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($sessionId))
    $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    $clsid = '{' + ('{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0,8), $hex.Substring(8,4), $hex.Substring(12,4), $hex.Substring(16,4), $hex.Substring(20,12)) + '}'

    # claude 进程 PID：沿父进程链向上找 node/claude 进程（hook 经 bash 执行，
    # 直接取父进程会误记成 bash；点击时用它判断会话是否存活）
    $claudePid = 0
    try {
      $cur = $PID
      for ($i = 0; $i -lt 6; $i++) {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $p) { break }
        if ($p.Name -match '^(node|claude)') { $claudePid = [int]$p.ProcessId; break }
        $cur = [int]$p.ParentProcessId
      }
    } catch { }
    # tab 标题：仅当共享 console 标题可靠时记录（hook 在独立 pty 时读到的是
    # shell 路径，不可靠；此时留空，点击端靠窗口聚焦兜底）
    $tabTitle = ''
    try { $tabTitle = [Console]::Title } catch { }
    if ($tabTitle -match '\.exe($|\s)') { $tabTitle = '' }
    $projName = if ($hook.cwd) { Split-Path ([string]$hook.cwd) -Leaf } else { 'Session' }
    $focusExe = Join-Path $PSScriptRoot 'focus.exe'

    # 1) 会话状态注册表（focus.exe --session 读取）
    # 覆盖保护：已有记录的 claude 进程仍存活时跳过写入——防止 claude --resume
    # 衍生实例（同 session_id）用新 tab 的环境覆盖原实例的定位信息
    $sessKey = "HKCU:\Software\ClaudeCode\Sessions\$sessionId"
    $existing = $null
    try { $existing = Get-ItemProperty $sessKey -ErrorAction Stop } catch { }
    $keepExisting = $false
    if ($existing -and $existing.parent_pid -and $claudePid -and ([int]$existing.parent_pid -ne $claudePid)) {
      try { if (Get-Process -Id ([int]$existing.parent_pid) -ErrorAction Stop) { $keepExisting = $true } } catch { }
    }
    if ($keepExisting) {
      # 只刷新时间戳，保留原实例的窗口/tab 定位
      Set-ItemProperty -Path $sessKey -Name 'updated' -Value (Get-Date).ToString('s')
    } else {
      New-Item -Path $sessKey -Force | Out-Null
    Set-ItemProperty -Path $sessKey -Name 'wt_session' -Value $env:WT_SESSION
    Set-ItemProperty -Path $sessKey -Name 'tab_title' -Value $tabTitle
    Set-ItemProperty -Path $sessKey -Name 'cwd' -Value ([string]$hook.cwd)
    Set-ItemProperty -Path $sessKey -Name 'parent_pid' -Value $claudePid
    Set-ItemProperty -Path $sessKey -Name 'aumid' -Value $aumid
    Set-ItemProperty -Path $sessKey -Name 'clsid' -Value $clsid
      Set-ItemProperty -Path $sessKey -Name 'updated' -Value (Get-Date).ToString('s')
    }

    # 2) 会话专属 AUMID：通知独立分组，CustomActivator 指向 focus.exe --session <id>
    $aumidKey = "HKCU:\Software\Classes\AppUserModelId\$aumid"
    New-Item -Path $aumidKey -Force | Out-Null
    Set-ItemProperty -Path $aumidKey -Name 'DisplayName' -Value ("Claude Code - " + $projName)
    Set-ItemProperty -Path $aumidKey -Name 'IconUri' -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    Set-ItemProperty -Path $aumidKey -Name 'CustomActivator' -Value $clsid
    $srvKey = "HKCU:\Software\Classes\CLSID\$clsid\LocalServer32"
    New-Item -Path $srvKey -Force | Out-Null
    Set-ItemProperty -Path $srvKey -Name '(Default)' -Value ('"{0}" --session {1}' -f $focusExe, $sessionId)

    $sessionAumid = $aumid

    # 3) 清理超过 7 天未更新的旧会话注册（防止注册表膨胀）
    Get-ChildItem 'HKCU:\Software\ClaudeCode\Sessions' -ErrorAction SilentlyContinue | ForEach-Object {
      $p = Get-ItemProperty $_.PSPath
      $expired = $true
      if ($p.updated) { try { $expired = ((Get-Date) - [DateTime]$p.updated).TotalDays -gt 7 } catch { } }
      if ($expired) {
        if ($p.aumid) { Remove-Item ("HKCU:\Software\Classes\AppUserModelId\" + $p.aumid) -Recurse -Force -ErrorAction SilentlyContinue }
        if ($p.clsid) { Remove-Item ("HKCU:\Software\Classes\CLSID\" + $p.clsid) -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
} catch { }

# 未显式传 Title 时：默认标题，多项目并行时用项目名区分
if (-not $Title) {
  $Title = 'Claude Code'
  if ($hook -and $hook.cwd) { $Title = 'Claude Code - ' + (Split-Path $hook.cwd -Leaf) }
}

if (-not $Message) {
  if ($Event -eq 'notify') {
    if ($hook -and $hook.message) { $Message = [string]$hook.message }
    else { $Message = '需要你的参与或确认' }
    # 过滤纯等待提醒（空闲 60 秒就会触发一次，是通知噪音）：
    # 只保留权限确认等真正需要用户参与的通知
    if ($Message -match 'waiting for your input|等待(你的)?输入') {
      exit 0
    }
  } elseif ($Event -eq 'stop') {
    $Message = '任务已完成，等待你的下一步指示'
    # 读取状态文件摘要：10 分钟内写入且目录匹配才生效，用后即删避免过期重复
    try {
      if (Test-Path $summaryFile) {
        $fresh = ((Get-Date) - (Get-Item $summaryFile).LastWriteTime).TotalMinutes -lt 10
        $lines = @(Get-Content $summaryFile -Encoding UTF8)
        if ($fresh -and $lines.Count -ge 2) {
          $scope = [string]$lines[0]
          $myCwd = ''
          if ($hook -and $hook.cwd) { $myCwd = [string]$hook.cwd }
          if ($scope -eq '*' -or ($myCwd -and $scope -eq $myCwd)) {
            $sum = (($lines | Select-Object -Skip 1) -join ' ').Trim()
            if ($sum) { $Message = $sum }
          }
        }
        Remove-Item $summaryFile -Force -ErrorAction SilentlyContinue
      }
    } catch { }
  } else {
    $Message = 'Claude Code 提醒'
  }
}

# XML 转义，防止消息内容破坏 Toast 模板
$safeTitle = [System.Security.SecurityElement]::Escape($Title)
$safeMessage = [System.Security.SecurityElement]::Escape($Message)

$xmlText = @"
<toast duration="short">
  <visual>
    <binding template="ToastGeneric">
      <text>$safeTitle</text>
      <text>$safeMessage</text>
    </binding>
  </visual>
  <audio src="ms-winsoundevent:Notification.Default"/>
</toast>
"@

try {
  [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
  [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

  $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
  $xml.LoadXml($xmlText)
  $toast = New-Object Windows.UI.Notifications.ToastNotification $xml

  # AUMID 优先级：会话专属（独立分组 + 点击精确路由）> 全局 ClaudeCode.ToastNotifier
  # > Explorer（系统必带兜底）。会话/全局 AUMID 均注册了 COM CustomActivator（focus.exe），
  # 点击通知时系统按需启动 focus.exe 聚焦/恢复终端。
  $appIds = @()
  if ($sessionAumid) { $appIds += $sessionAumid }
  $appIds += 'ClaudeCode.ToastNotifier', 'Microsoft.Windows.Explorer'
  foreach ($appId in $appIds) {
    try {
      [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
      break
    } catch { }
  }
} catch { }

exit 0
