# toast-notifier one-time install: compile focus.exe and register the global AUMID.
# Run once on each new device after copying the plugin folder. All writes are HKCU (no admin).

$ErrorActionPreference = 'Stop'
$hooks = $PSScriptRoot

# 1) Compile focus.exe (Toast click activator; every Windows box ships csc + UIA dlls)
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$gac = 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL'
$uiaClient = Join-Path $gac 'UIAutomationClient\v4.0_4.0.0.0__31bf3856ad364e35\UIAutomationClient.dll'
$uiaTypes = Join-Path $gac 'UIAutomationTypes\v4.0_4.0.0.0__31bf3856ad364e35\UIAutomationTypes.dll'
$out = Join-Path $hooks 'focus.exe'
$src = Join-Path $hooks 'focus.cs'
& $csc /nologo /target:winexe /r:$uiaClient /r:$uiaTypes /out:$out $src
if ($LASTEXITCODE -ne 0) { throw 'focus.exe compile failed' }

# 2) Register the global fallback AUMID -> COM CustomActivator -> focus.exe
#    (session-specific AUMIDs are registered automatically by toast.ps1 at runtime)
$clsid = '{8F5A2C41-9D3E-4B7A-B6C2-1E5F8A9D0C33}'
$aumidKey = 'HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ToastNotifier'
New-Item -Path $aumidKey -Force | Out-Null
Set-ItemProperty -Path $aumidKey -Name 'DisplayName' -Value 'Claude Code'
Set-ItemProperty -Path $aumidKey -Name 'IconUri' -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
Set-ItemProperty -Path $aumidKey -Name 'CustomActivator' -Value $clsid
$srvKey = "HKCU:\Software\Classes\CLSID\$clsid\LocalServer32"
New-Item -Path $srvKey -Force | Out-Null
Set-ItemProperty -Path $srvKey -Name '(Default)' -Value ('"{0}"' -f (Join-Path $hooks 'focus.exe'))

Write-Host 'toast-notifier installed: focus.exe compiled, global AUMID registered.' -ForegroundColor Green
