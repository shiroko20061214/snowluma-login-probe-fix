<#
  SnowLuma Login-Probe Fix  (SnowLuma 登录探测修复)
  ------------------------------------------------------------------
  修什么问题：SnowLuma 的 /api/processes/:pid/probe-login 在本地
  快速登录列表返回多个账号时，直接走 fallback -> null，WebUI 显示
  「未检测到可用的账号身份信息」，OneBot 也就起不来。

  修法：多账号时按进程归属挑人（--from-multiple-login 优先，其次
  排除法，最后 nickname/first），并给本地 ptlogin 端口加 http/https
  双协议回退。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\SnowLuma-LoginProbe-Fix.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\SnowLuma-LoginProbe-Fix.ps1 -Restart -Verify
    powershell -NoProfile -ExecutionPolicy Bypass -File .\SnowLuma-LoginProbe-Fix.ps1 -Path "X:\SomeWhere\SnowLuma"

  参数：
    -Path      SnowLuma 目录（含 index.mjs）。省略则自动探测：
               $env:SNOWLUMA_HOME -> 脚本所在目录 -> 正在运行的实例
               -> %USERPROFILE%\SnowLuma -> %LOCALAPPDATA%\SnowLuma
               -> %ProgramFiles%\SnowLuma -> 各固定盘符根目录\SnowLuma
    -Restart   打完补丁后重启 SnowLuma 运行时
    -Verify    打完补丁后通过 WebUI 接口逐个进程探测账号并打表
    -Password  WebUI 密码（配合 -Verify；省略则交互输入，不落盘）
    -Port      WebUI 端口（默认从 config\runtime.json 读，读不到用 5099）
#>
[CmdletBinding()]
param(
  [string]$Path,
  [switch]$Restart,
  [switch]$Verify,
  [string]$Password,
  [int]$Port = 0
)

$ScriptVersion = '1.1.0'
$ErrorActionPreference = 'Stop'
try {
  [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
  $OutputEncoding = New-Object Text.UTF8Encoding($false)
} catch { }

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }

function Resolve-SnowLumaRoot {
  param([string]$Hint)
  $cands = New-Object System.Collections.Generic.List[string]
  if ($Hint) { $cands.Add($Hint) }
  if ($env:SNOWLUMA_HOME) { $cands.Add($env:SNOWLUMA_HOME) }
  if ($PSCommandPath) {
    $here = Split-Path -Parent $PSCommandPath
    $cands.Add($here)
    $cands.Add((Split-Path -Parent $here))
  }
  # 正在运行的实例（命令行里带 index.mjs）
  try {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
      $cl = $_.CommandLine
      if (-not $cl -or $cl -notmatch 'index\.mjs') { return }
      $exe = $_.ExecutablePath
      if ($exe -and $exe -match '^(.*)\\node\.exe$') { $cands.Add($Matches[1]) }
      if ($cl -match '"?([A-Za-z]:\\[^"]*?)\\index\.mjs"?') { $cands.Add($Matches[1].TrimEnd('\')) }
    }
  } catch { }
  $cands.Add((Join-Path $env:USERPROFILE 'SnowLuma'))
  $cands.Add((Join-Path $env:LOCALAPPDATA 'SnowLuma'))
  $cands.Add((Join-Path $env:ProgramFiles 'SnowLuma'))
  # 各固定盘符根目录下的 SnowLuma
  try {
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Root -match '^[A-Za-z]:\\$' } | ForEach-Object {
      $cands.Add((Join-Path $_.Root 'SnowLuma'))
    }
  } catch { }
  foreach ($c in $cands) {
    if (-not $c) { continue }
    try { if (Test-Path (Join-Path $c 'index.mjs')) { return (Resolve-Path $c).Path } } catch { }
  }
  return $null
}

function Get-WebUiPort {
  param([string]$Root, [int]$Explicit)
  if ($Explicit -gt 0) { return $Explicit }
  $p = 5099
  try {
    $cfg = Join-Path $Root 'config\runtime.json'
    if (Test-Path $cfg) {
      $j = Get-Content $cfg -Raw -ErrorAction Stop | ConvertFrom-Json
      if ($j.webuiPort -and [int]$j.webuiPort -gt 0) { $p = [int]$j.webuiPort }
    }
  } catch { }
  return $p
}

function Restart-SnowLumaRuntime {
  param([string]$Root, [string]$Node, [int]$WebPort)
  $killed = @()
  try {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
      $cl = $_.CommandLine
      if (-not $cl -or $cl -notmatch 'index\.mjs') { return }
      $exe = $_.ExecutablePath
      $sameExe  = $exe -and ($exe -ieq $Node)
      $sameRoot = $cl -match [regex]::Escape($Root)
      if ($sameExe -or $sameRoot) {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; $killed += $_.ProcessId } catch { }
      }
    }
  } catch { }
  if ($killed.Count -gt 0) {
    Say ("已停止旧运行时 PID=" + ($killed -join ',')) 'Yellow'
    Start-Sleep -Milliseconds 900
  } elseif (Get-NetTCPConnection -State Listen -LocalPort $WebPort -ErrorAction SilentlyContinue) {
    Say ("× 端口 $WebPort 有进程在监听，但没能确认它是不是这个目录的 SnowLuma。" ) 'Red'
    Say '  请先从托盘/任务管理器退出 SnowLuma，再重跑一次脚本。' 'Red'
    return $false
  } else {
    Say '没找到正在跑的运行时（可能本来就停了），直接启动新的。' 'Yellow'
  }
  $logs = Join-Path $Root 'logs'
  if (-not (Test-Path $logs)) { New-Item -ItemType Directory -Path $logs | Out-Null }
  $np = Start-Process -FilePath $Node -ArgumentList './index.mjs' -WorkingDirectory $Root -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $logs 'stdout.log') -RedirectStandardError (Join-Path $logs 'stderr.log')
  Start-Sleep -Seconds 3
  if (-not (Get-Process -Id $np.Id -ErrorAction SilentlyContinue)) {
    Say '× 运行时没能起来，看 logs\stderr.log' 'Red'
    return $false
  }
  if (Get-NetTCPConnection -State Listen -LocalPort $WebPort -ErrorAction SilentlyContinue) {
    Say ("√ 运行时已重启 PID=" + $np.Id + "，WebUI $WebPort 已监听") 'Green'
  } else {
    Say ("√ 运行时已启动 PID=" + $np.Id + "，$WebPort 尚未监听，稍等几秒刷新页面") 'Green'
  }
  return $true
}

function Test-LoginProbe {
  param([string]$Pwd, [int]$WebPort)
  $Base = "http://127.0.0.1:$WebPort"
  if (-not $Pwd) {
    $sec = Read-Host '输入 SnowLuma WebUI 密码（只用于本次校验，不写文件）' -AsSecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $Pwd = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
  }
  try {
    $login = Invoke-RestMethod -Uri "$Base/api/login" -Method Post -Body (@{ password = $Pwd } | ConvertTo-Json -Compress) -ContentType 'application/json' -TimeoutSec 15
  } catch {
    Say "× 连不上 WebUI（$Base）或密码不对" 'Red'
    return $false
  }
  $h = @{ Authorization = "Bearer $($login.token)" }
  try {
    $procs = (Invoke-RestMethod -Uri "$Base/api/processes" -Headers $h -TimeoutSec 15).list
  } catch {
    Say '× 取进程列表失败' 'Red'
    return $false
  }
  if (-not $procs -or $procs.Count -eq 0) {
    Say '× WebUI 里没看到 QQ 进程，先启动 QQ 并登录' 'Red'
    return $false
  }
  Say ''
  Say ('{0,-8} {1,-14} {2,-12} {3}' -f 'PID', 'UIN', '状态', '备注') 'Cyan'
  Say ('{0,-8} {1,-14} {2,-12} {3}' -f '-------', '-------------', '----------', '----') 'DarkGray'
  $ok = 0
  foreach ($p in $procs) {
    $uin = ''
    $note = ''
    try {
      $pr = Invoke-RestMethod -Uri "$Base/api/processes/$($p.pid)/probe-login" -Headers $h -TimeoutSec 25
      if ($pr.info -and $pr.info.identityKnown) { $uin = [string]$pr.info.uin; $ok++ }
      else { $note = '探测仍拿不到账号' }
    } catch {
      $note = '探测请求失败'
    }
    Say ('{0,-8} {1,-14} {2,-12} {3}' -f $p.pid, $uin, $p.status, $note)
  }
  Say ''
  if ($ok -gt 0) { Say ("√ 成功识别 " + $ok + "/" + $procs.Count + " 个 QQ 进程的账号") 'Green'; return $true }
  Say '× 一个都没识别出来，把 logs 目录里最新的日志发出来看看' 'Red'
  return $false
}

Say "SnowLuma Login-Probe Fix v$ScriptVersion" 'Cyan'

# ---------- 1. 定位 SnowLuma ----------
$root = Resolve-SnowLumaRoot -Hint $Path
if (-not $root) {
  Say '× 没找到 SnowLuma 目录（需要包含 index.mjs）。请用 -Path 指定，例如：' 'Red'
  Say '  powershell -ExecutionPolicy Bypass -File .\SnowLuma-LoginProbe-Fix.ps1 -Path "D:\SnowLuma"' 'Yellow'
  Say '  也可以先设置环境变量 SNOWLUMA_HOME 指向该目录。' 'Yellow'
  exit 1
}
$bundle = Join-Path $root 'index.mjs'
Say "SnowLuma: $root" 'Cyan'

# ---------- 2. node ----------
$node = Join-Path $root 'node.exe'
if (-not (Test-Path $node)) {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { $node = $cmd.Source } else { Say '× 找不到 node.exe（SnowLuma 目录里没有，PATH 里也没有）' 'Red'; exit 1 }
}
Say "node: $node" 'Cyan'

$webPort = Get-WebUiPort -Root $root -Explicit $Port
Say "WebUI 端口: $webPort" 'Cyan'

# ---------- 3. 已打过就跳过 ----------
$src = [IO.File]::ReadAllText($bundle)
if ($src.Contains('snowLumaResolveAccount')) {
  Say '√ 已经是修复版，无需重复打补丁。' 'Green'
  if ($Restart) { if (-not (Restart-SnowLumaRuntime -Root $root -Node $node -WebPort $webPort)) { exit 4 } }
  else { Say '（加 -Restart 可以顺手重启运行时）' 'DarkGray' }
  if ($Verify) { if (-not (Test-LoginProbe -Pwd $Password -WebPort $webPort)) { exit 5 } }
  exit 0
}

# ---------- 4. 写账号归属探测脚本 ----------
$helper = Join-Path $root 'qq-uin-probe.ps1'
$helperBody = @'
# SnowLuma helper: 输出每个 QQ 主进程与其登录账号的对应关系 "<pid>|<uin or empty>"
$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" | ForEach-Object {
    $cl = $_.CommandLine
    if (-not $cl) { return }
    if ($cl -match '--type=') { return }
    $u = ''
    if ($cl -match '--from-multiple-login\s+(\d{5,12})') { $u = $Matches[1] }
    else {
        $m = [regex]::Match($cl, 'application\.asar\\background\.js.*?\s(\d{5,12})(\s|")')
        if ($m.Success) { $u = $m.Groups[1].Value }
    }
    "$($_.ProcessId)|$u"
}
'@
[IO.File]::WriteAllText($helper, $helperBody.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
Say "写出助手脚本: $helper" 'Cyan'

# ---------- 5. 打补丁 ----------
$startMarker = 'async function tryPtloginMethod(port) {'
$endMarker = 'async function getQqProcessCount() {'
$a = $src.IndexOf($startMarker)
$b = $src.IndexOf($endMarker)
if ($a -lt 0 -or $b -lt 0 -or $b -le $a) {
  Say '× 找不到补丁锚点，这个 index.mjs 版本可能太新/太旧。已跳过，未修改任何文件。' 'Red'
  exit 2
}

$jsPath = $helper.Replace('\', '\\').Replace('"', '\"')
$part1 = @'
async function snowLumaListQqMainProcessUins() {
	try {
		const { stdout } = await execAsync("powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"
'@
$part2 = @'
\"", EXEC_OPTIONS);
		const map = /* @__PURE__ */ new Map();
		for (const raw of stdout.split(/\r?\n/)) {
			const line = raw.trim();
			if (!line) continue;
			const sep = line.indexOf("|");
			if (sep <= 0) continue;
			const pid = Number(line.slice(0, sep));
			if (!Number.isInteger(pid) || pid <= 0) continue;
			const uin = line.slice(sep + 1).trim();
			map.set(pid, uin || null);
		}
		return map;
	} catch {
		return null;
	}
}
async function snowLumaResolveAccount(pid, accounts) {
	const normalized = [];
	for (const account of accounts) {
		const uin = String(account.uin || account.account || "");
		if (!uin) continue;
		normalized.push({
			uin,
			nickName: account.nickname || ""
		});
	}
	if (normalized.length === 0) return null;
	if (normalized.length === 1) return normalized[0];
	const processUins = await snowLumaListQqMainProcessUins();
	if (processUins) {
		const own = processUins.get(pid);
		if (own) {
			const hit = normalized.find((account) => account.uin === own);
			if (hit) return hit;
		}
		const claimed = new Set(Array.from(processUins.values()).filter(Boolean));
		const unclaimedProcesses = Array.from(processUins.entries()).filter(([otherPid, uin]) => otherPid !== pid && !uin);
		if (unclaimedProcesses.length === 1) {
			const free = normalized.filter((account) => !claimed.has(account.uin));
			if (free.length === 1) return free[0];
		}
	}
	const withNickname = normalized.filter((account) => account.nickName);
	if (withNickname.length === 1) return withNickname[0];
	return normalized[0];
}
async function snowLumaFetchPtloginBothSchemes(port) {
	const primary = port % 2 !== 0;
	const first = [await fetchPtlogin(port, primary), await fetchPtlogin(port, primary)];
	if (first[0] !== null || first[1] !== null) return first;
	return [await fetchPtlogin(port, !primary), await fetchPtlogin(port, !primary)];
}
async function tryPtloginMethod(port, pid) {
	const [res1, res2] = await snowLumaFetchPtloginBothSchemes(port);
	if (res1 === null && res2 === null) return "fallback";
	const target = [res1, res2].filter((r) => r !== null).reduce((a, b) => a.length <= b.length ? a : b);
	if (target.length === 0) return "fallback";
	const account = target.length === 1 ? {
		uin: String(target[0].uin || target[0].account || ""),
		nickName: target[0].nickname || ""
	} : await snowLumaResolveAccount(pid, target);
	if (!account || !account.uin) return "fallback";
	return {
		port,
		uin: String(account.uin),
		nickName: account.nickName || "",
		identityKnown: true,
		accountCount: target.length
	};
}
'@
$replacement = $part1 + $jsPath + $part2

$out = $src.Substring(0, $a) + $replacement + $src.Substring($b)
$callMarker = 'await tryPtloginMethod(port)'
if (-not $out.Contains($callMarker)) {
  Say '× 找不到调用点，已跳过，未修改任何文件。' 'Red'
  exit 2
}
$out = $out.Replace($callMarker, 'await tryPtloginMethod(port, pid)')

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$bundle.bak-$stamp"
Copy-Item $bundle $backup -Force
[IO.File]::WriteAllText($bundle, $out, (New-Object Text.UTF8Encoding($false)))
Say "已备份: $backup" 'Cyan'

# ---------- 6. 语法校验，失败回滚 ----------
& $node --check $bundle 2>$null
if ($LASTEXITCODE -ne 0) {
  Copy-Item $backup $bundle -Force
  Say '× 语法校验失败，已回滚到原文件。' 'Red'
  exit 3
}
Say '√ 补丁已应用，语法校验通过。' 'Green'

# ---------- 7. 可选重启 ----------
if ($Restart) {
  if (-not (Restart-SnowLumaRuntime -Root $root -Node $node -WebPort $webPort)) { exit 4 }
}

# ---------- 8. 可选校验 ----------
if ($Verify) {
  if (-not (Test-LoginProbe -Pwd $Password -WebPort $webPort)) { exit 5 }
}

Say ''
Say '完成。打开 WebUI → 进程注入 → 点「重新探测」，应当显示账号 UIN。' 'Green'
Say '（多开时每行 QQ.exe 对应各自账号；单账号机器行为不变。）' 'DarkGray'
