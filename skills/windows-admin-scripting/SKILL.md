---
name: windows-admin-scripting
description: 给普通用户交付 Windows 提权脚本的三条铁律——UTF-8 BOM、禁止 bat 自提权、不要吞掉 Access Denied，以及 PowerShell 5.1 与 7 的行为差异
---

# 给用户写 Windows 管理员脚本

场景：AI Agent 在非管理员会话里工作，需要把一组需要提权的操作打包成脚本交给用户自己双击运行。

这里每一条都来自实际翻车：脚本闪退、窗口无限闪、报"成功"其实没删。

## 三条铁律

### 铁律一：`.ps1` 必须存成 UTF-8 **with BOM**

`.ps1` 里有中文时，如果存成 UTF-8 无 BOM：

- PowerShell 7 读得对 → **你的语法检查通过**
- Windows PowerShell 5.1 按 ANSI/GBK 读 → 中文变乱码 → **把字符串引号弄断**

实际报错长这样：

```
The string is missing the terminator: ".
```

整个脚本解析失败、瞬间退出，用户只看到窗口一闪。

```powershell
# write 工具默认产出 UTF-8 无 BOM，必须补 BOM
$p = 'path\to\script.ps1'
$text = [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($true)))

# 验证
$b = [System.IO.File]::ReadAllBytes($p)[0..2]
'{0:X2} {1:X2} {2:X2}' -f $b[0],$b[1],$b[2]   # 应为 EF BB BF
```

另外：用 `edit` 工具改过带 BOM 的文件后，**BOM 会丢失**，必须重新补。

### 铁律二：`.bat` 里**不要**写自提权

错误写法：

```bat
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
```

只要 `net session` 在提权后的窗口里**仍然**返回失败（它依赖 LanmanServer 服务，条件不满足时不分权限都会失败），就会变成：

> 提权 → 仍失败 → 再提权 → 再失败……

每个新窗口弹出后立刻消失，**用户看到的就是终端一直闪**。

正确做法：`.bat` 只做纯 ASCII 的包装，**完全不自提权**，让用户右键选「以管理员身份运行」，脚本内部自己检查权限：

```bat
@echo off
chcp 65001 >nul
title My Cleanup - Run as Administrator

net session >nul 2>&1
if errorlevel 1 (
    echo [!] Not running as administrator.
    echo [!] Close this window, then right-click this file
    echo     and choose "Run as administrator".
)

powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0script.ps1"
echo.
echo Finished. Press any key to close this window.
pause >nul
```

要点：
- `.bat` 内容**保持纯 ASCII**（中文全部放 `.ps1` 里），彻底避开 cmd 的编码坑
- `-NoExit` + `pause` 保证窗口不会一闪而过，出错也能看到报文

### 铁律三：不要用 `-ErrorAction SilentlyContinue` 包住删除操作

```powershell
# 危险：报 OK，其实一个都没删
Get-ChildItem $dir | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host "[OK] 清理完成"
```

`-ErrorAction SilentlyContinue` 会把 **Access Denied 静默吞掉**，脚本欢快地打印「完成」，用户以为清干净了，实际磁盘一点没变。

正确写法：捕获、记录、如实汇报。

```powershell
$fail = 0
foreach ($x in Get-ChildItem $dir -Force -ErrorAction SilentlyContinue) {
    try { Remove-Item -LiteralPath $x.FullName -Recurse -Force -ErrorAction Stop }
    catch { $fail++; Write-Host ("  [FAIL] {0}  {1}" -f $x.Name, $_.Exception.Message) -ForegroundColor Yellow }
}
Write-Host ("删除成功 {0} 项，失败 {1} 项" -f ($ok), $fail)
```

**判定「占用」还是「权限」看错误文本：**

| 错误文本 | 含义 | 对策 |
|---|---|---|
| `being used by another process` | 文件被占用 | 关进程 / 重启后再删 |
| `Access to the path '...' is denied.` | 权限不足 | 提权，或 `takeown` + `icacls` |

## 脚本骨架

```powershell
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function Pause-IfNeeded { if ($env:SKIP_PAUSE -ne '1') { Read-Host "按回车关闭" } }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "  [x] 当前不是管理员权限，脚本不会做任何修改。" -ForegroundColor Red
    Write-Host "  请右键本文件 -> 以管理员身份运行"
    Pause-IfNeeded
    exit 1
}

# ... 实际操作，每步带 "→ 正在做 xxx" 进度标记 ...

Pause-IfNeeded
```

`SKIP_PAUSE=1` 环境变量用于**自动化测试**：设置后脚本走完就退出，不会卡在 `Read-Host`。

## 接管受保护目录的正确顺序

```powershell
function Take-Own {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    # /a 把所有权给 Administrators 组而不是当前用户，重装/多用户环境更稳
    & takeown.exe /f $Path /r /a /d Y 2>&1 | Out-Null
    & icacls.exe  $Path /grant "Administrators:(OI)(CI)F" /t /c /q 2>&1 | Out-Null
}
```

删之前先 `Take-Own`，删之后**用 `Test-Path` 验证**，别信返回值。

## 必须用目标运行时实测

写完脚本后，**用 `powershell.exe`（5.1）而不是 `pwsh` 测**，因为你交付的 `.bat` 调用的就是 5.1：

```powershell
$env:SKIP_PAUSE = '1'
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File 'path\to\script.ps1' 2>&1
if ($out -match 'ParserError|missing the terminator|Unexpected token') { '语法/编码失败' }
elseif ($out -match '不是管理员权限') { 'OK：语法正确、中文正常、安全退出' }
```

非管理员路径安全退出，就说明编码和语法没问题。

## PowerShell 5.1 与 7 的行为差异

| 差异点 | 5.1 | 7 |
|---|---|---|
| `.ps1` 编码 | 无 BOM 时按 ANSI/GBK 读 | 按 UTF-8 读 |
| `Get-ChildItem -Recurse` 跟进 junction | **会**（有环时死循环） | 默认不跟进 |
| 枚举海量/特殊 ACL 目录 | 极慢 | 快 |
| `Test-Path` 对断链 junction | 返回 True | 返回 True |

**`C:\Windows\WinSxS\Temp` 在 5.1 里枚举 588 个文件要 92.7 秒**（约 6 个文件/秒），7 里是瞬间。所以：**这种目录不要做递归统计，直接 `takeown` + 整目录删**，否则用户以为程序卡死就关窗了（本机连续两次都卡在这一步）。

## 每一步都打进度标记

无法区分的「慢」和「死机」，是这类脚本最常见的用户投诉来源。

```powershell
Write-Host "  → 统计 C:\ProgramData\Microsoft\Search ..." -NoNewline
$sz = Get-SizeSafe $p
Write-Host "`r  {0,10:N1} MB  {1}   " -f ($sz/1MB), $p
```

用户随时知道当前在哪一步；真卡住了，他能准确告诉你卡在哪个 `→` 后面。

## 交付清单

- [ ] `.ps1` 是 UTF-8 with BOM（前三字节 `EF BB BF`）
- [ ] `.bat` 纯 ASCII、无 `RunAs`/`Start-Process`、带 `-NoExit` + `pause`
- [ ] 脚本开头有 `IsInRole` 自检，非管理员时**不做任何修改**并说明怎么运行
- [ ] 没有 `Remove-Item` 被 `-ErrorAction SilentlyContinue` 包裹
- [ ] 每个慢操作前有 `→ xxx` 进度标记
- [ ] 用 `powershell.exe -File` 实测过非管理员路径
- [ ] 需要接管所有权的目录先 `takeown /a` + `icacls /grant`
