# 事故报告：一次「帮我清一下 C 盘」引发的连锁故障

> 本文记录一次真实的 Windows 磁盘清理任务，包括成功的部分和**四次人为失误**。
> 失败部分比成功部分更有价值——它们揭示了「AI Agent 驱动本机 Windows 时最容易犯的错」。

## 起点

用户的原话是一句话：

> 我需要一个磁盘清理的东西，帮我在GitHub上找一下

最终演变成：选型开源工具 → 全盘扫描 → 四轮分档清理 → 关系统级预留 → 数据搬迁 → **误删用户软件** → **破坏开发环境** → 修复 → 复盘。

## 最终成绩

| 磁盘 | 起始可用 | 结束可用 | 释放 | 使用率变化 |
|---|---|---|---|---|
| C: | 61.59 GB | 104.25 GB | **+42.66 GB** | 69.2% → 47.9% |
| D: | 544.89 GB | 617.34 GB | **+72.45 GB** | 27.5% → 17.9% |
| 合计 | | | **+115.12 GB** | |

主要释放项：

| 项目 | 释放 |
|---|---|
| 生死狙击2（免安装游戏） | 44.69 GB |
| Windows「保留存储」关闭 | 14.36 GB |
| 系统/用户垃圾、缓存、安装包 | ~20 GB |
| 微信/剪映/QQ音乐/联想残留 | ~12 GB |
| 旧版本（QQ/Qoder/cxstudy） | 3.33 GB |
| Windows 错误报告（WER） | 1.33 GB |
| MCP 索引缓存 | 2.33 GB |

---

## 失误一：把 junction 目标当成「死副本」，删掉了用户的微信

### 现场

```
C:\Program Files\Tencent\weixin       ← 看起来"程序在这里"
D:\电脑管家迁移文件\weixin             ← 看起来"这是迁移残留"
```

判断依据是微信进程的 `Path` 属性显示 `C:\Program Files\Tencent\Weixin\Weixin.exe`。

### 真相

```
C:\Program Files\Tencent\weixin
  LinkType : Junction
  Target   : D:\电脑管家迁移文件\weixin
```

联想电脑管家的「C 盘搬家」把程序实体移到了 D 盘，在 C 盘原位置留了个 junction。微信一直是通过这个链接运行的。

**进程的 `Path` 显示解析后的路径，不是链接路径**——从进程信息完全看不出它是链接。

删掉 D 盘实体后 junction 断链，微信当场消失：目录还在、快捷方式还在、注册表还在，但打不开。

### 修复

1. 确认聊天数据完好（`%APPDATA%\Tencent\xwechat\xwechat_files` 不在被删范围）
2. 从官方 CDN 下载对应版本安装包（`https://dldir1v6.qq.com/weixin/Universal/Windows/WeChatWin_<ver>.exe`），校验 PE 头与版本
3. 清理断链 junction + 残留注册表卸载项，再重装

用户最终装到了 `D:\AA\Documents\Weixin`，顺带把程序挪出了 C 盘。

### 教训

> 删「重复目录」之前，必须查 `LinkType`。

现在这条已经写成 skill：`windows-link-safety`。

---

## 失误二：让管理员脚本无限自我提权重启，用户看到终端一直闪

### 现场

`.bat` 包装层写了自提权：

```bat
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
```

### 真相

`net session` 依赖 LanmanServer 服务。只要它在提权后的窗口里**仍然**返回失败，就会形成「提权 → 仍失败 → 再提权」的无限循环，每个窗口弹一下立刻消失。

### 修复

`.bat` 改成**纯 ASCII、完全不自提权**，只提示用户「右键 → 以管理员身份运行」；权限检查放在 `.ps1` 里用 `WindowsPrincipal.IsInRole`。

---

## 失误三：`.ps1` 少了 BOM，脚本一进去就语法崩

### 现场

用户报告「运行后终端一直闪」。日志里是：

```
At admin_cleanup.ps1:155 char:42
+ if ($env:SKIP_PAUSE -ne '1') { Read-Host "鎸夊洖杞﹀叧闂? }
The string is missing the terminator: ".
```

### 真相

文件是 UTF-8 **无 BOM**。调用它的 `powershell.exe`（5.1）按 ANSI/GBK 读，中文字符串变乱码后把引号弄断，整个脚本解析失败。

而我的语法检查用的是 **pwsh 7**（能正确读 UTF-8），所以显示 0 错误——**测错了运行时就等于没测**。

### 修复

```powershell
$text = [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($true)))
```

以后一律用 `powershell.exe -File` 实测非管理员路径。

### 这一个 bug 的代价

不只是一个脚本失败：**用户把 v2 脚本连跑了两次都卡住**，因为脚本在报出语法错误前先进入了那段极慢的目录统计（见失误四）。

---

## 失误四：把「慢」当成「死机」，误判了两次

### 现场

脚本连续两次都停在：

```
--- 2/4  清理上次 DISM 失败留下的残留 ---
  TrustedInstaller 服务：Stopped
```

看起来像卡死。

### 真相

真正的原因是紧接着的一次目录统计：

| 目录 | 文件数 | PowerShell 5.1 耗时 |
|---|---|---|
| `C:\Windows\WinSxS\Temp` | 588 | **92.7 秒** |
| `C:\Windows\Logs\CBS` | 3 | 0.00 秒 |

同一个操作在 pwsh 7 里是瞬间完成的。92 秒的静默等待，对用户来说和死机没有区别。

### 修复

1. **不统计这个目录**——反正下一步就要整目录删掉
2. 每个慢操作前打显式进度标记：`→ 统计 C:\ProgramData\Microsoft\Search ...`
3. 目录统计改用「不跟进 reparse point + 20 万次循环上限」的手动栈遍历

---

## 失误五（最严重）：迁移全局模块目录，破坏了自己的运行环境

### 现场

为了省 C 盘空间，把 `C:\Users\AA\AppData\Roaming\npm` 整体迁到 `D:\dev-store\npm-global`，并删除了原目录。

### 连锁反应

1. **482 个 junction 断链** —— 位于 `D:\dsh-home\profiles\node_modules\*`，目标全是那个被迁走的目录
2. DSH Desktop 下次启动时模块解析失败 → **自动重建 profile**
3. 重建把配置重置成最小版：

| 指标 | 正常 | 被重置后 |
|---|---|---|
| `package.json` 的 bundles | 6 个 | 2 个（丢了 memory-evolve / photoshop / pentest / remote） |
| `cordis.patch.yml` | 3171 字节（6 个 MCP 服务） | 217 字节，内容是 `[]` |
| `node_modules` | 有实体包 | 只剩 pnpm 元数据 |

4. 症状：会话里 `memory` / `dtodo` / `skill_manage` 与全部 MCP 工具返回 **unknown tool**

### 修复（三步）

```powershell
# 1. 在原路径重建 junction 别名（不需要管理员）
cmd /c 'mklink /J "C:\Users\AA\AppData\Roaming\npm" "D:\dev-store\npm-global"'

# 2. 从健康快照找回配置
#    快照在 %APPDATA%\DSH Desktop\health-snapshots\<hash>\slot-*\
#    挑字节数最大、日期最新的那组，拷回 $DSH_HOME\profiles\desktop\
#       package.json / cordis.patch.yml / pnpm-lock.yaml / pnpm-workspace.yaml

# 3. 重装依赖
cd $env:DSH_HOME\profiles\desktop
dsh plugin --profile desktop install

# 4. 不启动应用的配置校验
dsh --profile desktop --dump-config     # 应输出数百行且无 Error
```

修复后 `--dump-config` 输出 619 行，包含全部插件与 MCP 服务；482 个链接抽查 40 个全部恢复。

### 教训

> 动全局模块目录时，优先**只加 junction 别名**，不要搬实体。

---

## 还有一类：删了却不释放空间

这不是失误，是 Windows 的反直觉行为。共遇到 9 种，全部写进了
[`skills/windows-disk-cleanup/references/pitfalls.md`](../skills/windows-disk-cleanup/references/pitfalls.md)：

1. 文件被进程持有句柄 → 目录消失但簇未归还
2. `-ErrorAction SilentlyContinue` 吞掉 Access Denied → 报 OK 实则没删
3. 归 `TrustedInstaller` 所有 → 管理员也删不掉，要先 `takeown`
4. WinSxS 硬链接 → 累加值掉 5 GB，空间不变
5. Windows「保留存储」15 GB → 任何扫描都看不见，`fsutil` 才报
6. 清理脚本把隔离区当垃圾二次移动 → 自我嵌套
7. 还原点删除 → `vssadmin` 的 Used ≠ 立即可回收
8. Defender 被第三方杀软接管 → Quarantine 是历史遗留
9. 显式 DENY ACE → DENY 优先于任何 Allow

---

## 复盘：五个失误的共同结构

| 失误 | 表面判断 | 缺失的那一步检查 |
|---|---|---|
| 删微信 | 进程路径显示在 C 盘 | 没查 `LinkType` |
| bat 闪屏 | 脚本起不来 | 没意识到判断条件在提权后仍可能为真 |
| 脚本乱码 | 语法正确 | 没在真正的运行时（5.1）上测 |
| 误判死机 | 92 秒无输出 | 没给慢操作加进度标记 |
| 破坏 DSH | 迁目录省空间 | 没查谁依赖那个目录 |

**共同点：都是"证据看起来充分，但检查维度少了一个"。**

所以这个仓库里的每个 skill 都以「检查清单」结尾，而不是「步骤列表」。

---

## 证据附录

关键命令与观测值，便于他人核对自己是否遇到同一问题。

```powershell
# 判断是否链接
(Get-Item 'C:\Program Files\Tencent\weixin' -Force) | Select-Object LinkType, Target

# 断链判定（Test-Path 对 junction 本身返回 True，不可靠）
@(Get-ChildItem 'D:\dsh-home\profiles\node_modules\@deepseek-ai\dsh-fs' -Force).Count   # 0 = 断链

# 保留存储
fsutil volume diskfree C:          # 看 Volume storage reserved bytes
DISM /Online /Get-ReservedStorageState

# 显式 DENY ACE
icacls "D:\LeStoreDownload\某文件.exe"

# TrustedInstaller 保护
takeown /f "C:\Windows\WinSxS\Temp" /r /a /d Y
icacls  "C:\Windows\WinSxS\Temp" /grant "Administrators:(OI)(CI)F" /t /c /q

# DSH profile 健康检查
dsh --profile desktop --dump-config
```

## License

MIT —— 随意取用，如果能帮你少踩一个坑就值了。
