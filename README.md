# SnowLuma Login-Probe Fix

修 SnowLuma 在**多账号**环境下「探测登录」拿不到 UIN 的问题：WebUI 里点「探测登录 / 重新探测」只显示

```
未检测到可用的账号身份信息
```

注入本身是正常的（`[Hook] pipe connected` 照常出现），坏的只是账号识别这一步，所以 OneBot 起不来。

- 适用：SnowLuma 1.14.x（`index.mjs` 打包版），Windows 10/11
- 不改 QQ：只动 SnowLuma 自己的 `index.mjs`，动手前自动备份
- 幂等：跑第二遍会直接告诉你「已经是修复版」，不会重复改

## 症状与根因

SnowLuma 的 `probeProcessLoginInfo()` 会去读 QQ 本地 ptlogin 接口：

```
https://127.0.0.1:4301/pt_get_uins?callback=ptui_getuins_CB&pt_local_tk=0
```

返回长这样：

```js
var var_sso_uin_list=[{"uin":29003269,...},{"uin":2312821679,...,"nickname":"..."}];
```

而 `tryPtloginMethod()` 里写死了：

```js
if (target.length === 1) { ... }   // 只要不是「恰好 1 个」，就 return "fallback"
return "fallback";                  // -> probe 返回 null -> 前端显示「未检测到账号身份信息」
```

所以：

| 场景 | 结果 |
|---|---|
| 本地只有一个 QQ 账号 | 返回 1 条，命中，正常 |
| 两个及以上账号（多开、或列表里存了多个号） | 返回多条，**必然**走 fallback，探测失败 |

这跟 QQ 是 9.9.36 还是 9.9.37 无关。9.9.37 确实另有变化（偶数端口 4310/4312 不再回明文 HTTP，原代码 `EVEN_PT_PORTS` 假设偶数=HTTP），但奇数端口仍在，所以主要卡点是上面这个「单账号假设」。

## 快速开始

1. 退出 SnowLuma（托盘退出，或任务管理器结束 `node.exe`）
2. 把 `SnowLuma-LoginProbe-Fix.ps1` 和 `run.cmd` 放到**任意目录**（不用放进 SnowLuma 目录）
3. 双击 `run.cmd`

脚本会自己找 SnowLuma 目录、打完补丁、重启运行时。刷新 WebUI，再点「重新探测」即可。

也可以直接跑 PowerShell：

```powershell
# 全自动：找目录 + 打补丁 + 重启 + 校验
powershell -NoProfile -ExecutionPolicy Bypass -File .\SnowLuma-LoginProbe-Fix.ps1 -Restart -Verify

# 装在奇怪位置时指定目录
powershell -NoProfile -ExecutionPolicy Bypass -File .\SnowLuma-LoginProbe-Fix.ps1 -Path "X:\Apps\SnowLuma" -Restart
```

### 参数

| 参数 | 说明 |
|---|---|
| `-Path` | SnowLuma 目录（含 `index.mjs`）。省略则自动探测：`$env:SNOWLUMA_HOME` → 脚本所在目录及其上级 → 正在运行的实例 → `%USERPROFILE%\SnowLuma` → `%LOCALAPPDATA%\SnowLuma` → `%ProgramFiles%\SnowLuma` → 各固定盘符根目录 `\SnowLuma` |
| `-Restart` | 打完补丁后重启运行时（杀旧 `node index.mjs`，用 SnowLuma 自带 `node.exe` 起新的） |
| `-Verify` | 通过 WebUI 接口对每个 QQ 进程跑一次 `probe-login` 并打表，确认修好 |
| `-Password` | WebUI 密码，配合 `-Verify`；省略则交互输入（不写任何文件） |
| `-Port` | WebUI 端口，默认从 `config\runtime.json` 的 `webuiPort` 读，读不到用 `5099` |

### 校验输出长这样

```
PID      UIN            状态         备注
-------  -------------  ----------   ----
19480    29003269       online
21792    2312821679     available

√ 成功识别 2/2 个 QQ 进程的账号
```

## 它做了什么

1. 在 SnowLuma 目录写出 `qq-uin-probe.ps1`：枚举 QQ 主进程（过滤掉 `--type=` 子进程），从命令行里取 `--from-multiple-login <uin>`，输出 `PID|UIN`。
2. 把 `index.mjs` 里 `tryPtloginMethod(port)` 整段替换为：

   - `tryPtloginMethod(port, pid)`：多带一个 PID
   - `snowLumaResolveAccount(pid, accounts)`：多账号时按归属挑人
   - `snowLumaFetchPtloginBothSchemes(port)`：http/https 都试一遍

3. 替换调用点 `await tryPtloginMethod(port)` → `await tryPtloginMethod(port, pid)`。
4. 跑 `node --check` 校验语法；不通过自动还原备份。
5. 返回值仍是 `{port, uin, nickName, identityKnown}`，额外带 `accountCount`，前端与 OneBot 侧无需改动。

**选人顺序**：

1. 列表只有 1 条 → 直接用
2. 该 PID 命令行里有 `--from-multiple-login <uin>` → 精确命中
3. 其他 QQ 主进程都没被认领、只剩一个空闲账号 → 归给它
4. 只有一个账号带 nickname → 用它
5. 兜底取第一个

**改动文件**（都在 SnowLuma 目录内）：

| 文件 | 说明 |
|---|---|
| `index.mjs` | 打过补丁的运行时（原文件备份为 `index.mjs.bak-<时间戳>`） |
| `qq-uin-probe.ps1` | 新增的账号归属助手 |
| `logs\stdout.log` / `logs\stderr.log` | 用 `-Restart` 启动时的输出 |

## 回滚

```powershell
# <SnowLuma> 换成你的安装目录，<时间戳> 换成实际备份名
Copy-Item "<SnowLuma>\index.mjs.bak-<时间戳>" "<SnowLuma>\index.mjs" -Force
```

然后重启 SnowLuma 即可。

## 已知边界

- 端口列表仍是 SnowLuma 原来那套 `4301/4303/4305/4307/4309`（奇数）与 `4302..4310`（偶数）。QQ 若换端口段，需要跟着改 `ODD_PT_PORTS` / `EVEN_PT_PORTS`。
- 三个及以上账号同时在线、且都不是 `--from-multiple-login` 拉起时，「唯一空闲账号」推断会失效，退化成 nickname/第一个。多开请用带账号参数的启动方式。
- SnowLuma 自动更新会整包覆盖 `index.mjs`，补丁会丢。更新后重跑一次本脚本即可。
- 只处理 Windows。Linux/macOS 上 SnowLuma 的探测路径不同，本脚本不适用。

## FAQ

**Q：跑完 WebUI 还是显示未检测到账号？**
先确认 `-Verify` 有没有打出表。打不出来看 `logs\stderr.log`；能打出表但页面没变，刷新页面/重新登录 WebUI。

**Q：会不会影响 QQ？**
不会。脚本只写 SnowLuma 目录，QQ 安装目录零改动。

**Q：会不会破坏 SnowLuma？**
改动前备份，改完 `node --check`，失败自动还原。锚点找不到时直接退出，一个字节都不写。

**Q：别人也遇到这个吗？**
只要本地登录过两个及以上 QQ 账号，就会命中同一处判断，属于代码里的单账号假设，不是个例。单账号用户不会受影响。

## License

MIT，见 [LICENSE](LICENSE)。
