---
name: windows-disk-cleanup
description: Windows 磁盘占用分析与分档清理——全盘扫描、五档风险分类、隔离区回收，以及"删了却不释放空间"的九类坑
---

# Windows 磁盘清理

面向「帮我把 C 盘清一下」这类请求的完整方法论。核心不是"多删点东西"，而是**先算准、再分档、可回滚、最后用数字验证**。

## 何时使用

- 用户抱怨某个盘快满了
- 需要审计磁盘上到底什么在占空间
- 准备批量删除缓存/临时文件/旧版本
- 删了文件但可用空间没变化，需要排查原因

## 第一原则：只相信 `Get-PSDrive` 的 Free

任何"释放了多少"的结论都必须来自**操作前后的 `Get-PSDrive <盘>` 差值**。

不要用这些做结论：

| 不可信的指标 | 为什么 |
|---|---|
| 文件大小累加（`Length` 求和） | WinSxS 与 System32 大量共享硬链接，同一份数据被算多次 |
| `vssadmin` 的 Used Shadow Copy Storage | 删掉后不一定立即归还（实测 3.16 GB 删完只 +0.30 GB） |
| 资源管理器的"已用空间" | 包含 Reserved Storage，那部分任何扫描都看不见 |
| 脚本自己打印的 "释放 X GB" | 统计口径可能和磁盘真实变化不一致 |

## 五步流程

### 1. 算总账：先解释清楚"已用空间"的构成

```powershell
Get-PSDrive C | Select-Object @{n='FreeGB';e={[math]::Round($_.Free/1GB,2)}},
                                 @{n='UsedGB';e={[math]::Round($_.Used/1GB,2)}}
fsutil volume diskfree C:
```

`fsutil` 的关键字段：

```
Used bytes                    ← 真实文件占用
Total Reserved bytes          ← 含 Reserved Storage
Volume storage reserved bytes  ← Windows「保留存储」，即"隐形空间"
```

**扫描累加值 + Reserved bytes ≈ UsedGB 时，账就平了。** 对不上就去查下文第九条。

### 2. 全盘扫描（一次遍历，多项统计）

不要为每个指标单独扫一遍盘。一次 `DirectoryInfo` 手动栈遍历同时产出：一级/二级目录占用、分类桶、大文件、重复候选、空目录、junction 清单。

现成脚本见 [`scripts/scan.ps1`](scripts/scan.ps1)。实现要点：

```powershell
# 必须带尾反斜杠，否则 D: 表示"该盘的当前目录"而非根目录
$root = 'D:\'
$stack = [System.Collections.Generic.Stack[string]]::new()
$stack.Push($root)
while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    $di  = New-Object System.IO.DirectoryInfo($dir)
    $files = $null; $subs = $null
    try { $files = $di.GetFiles() }       catch { $files = $null }   # 无权限的目录整体跳过
    if ($null -eq $files) { continue }
    try { $subs  = $di.GetDirectories() } catch { $subs  = $null }
    foreach ($d in $subs) {
        if ((($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0) {
            # 记录 junction / symlink，绝不进入
            continue
        }
        $stack.Push($d.FullName)
    }
    foreach ($f in $files) { $total += $f.Length }
}
```

三个必守的细节：

- **用 `DirectoryInfo.GetFiles()` 而不是 `Get-ChildItem -Recurse`**。后者在超长路径上会静默漏文件。
- **跳过 reparse point**，否则 junction 环会让遍历跑不完。
- **命中"桶"目录（如 `node_modules`）后直接算子树大小、不再下钻**，避免重复计数并大幅提速。

### 3. 分五档（按风险，不按大小）

| 档 | 内容 | 判断依据 |
|---|---|---|
| **1 纯垃圾** | `Temp`、`.tmp`、`.log`、`.bak`、浏览器/应用 `Cache`、空目录 | 可直接删，重生成 |
| **2 安装包/更新残留** | `%LOCALAPPDATA%` 下的 `installer.exe`、`Downloads` 里的 setup、`DeliveryOptimization`、旧版本目录 | 可删，要用再下 |
| **3 缓存** | 包管理器 store（`uv`/`pnpm`/`npm`/`pip`/`gradle`）、`ms-playwright`、`node_modules` | 优先用官方命令（`uv cache clean` 等） |
| **4 需用户确认** | 迁移残留、聊天软件缓存、游戏缓存、`WinSxS`、系统还原点 | 有数据风险或不可逆 |
| **5 不要动** | `C:\Windows`、`System32\config`、`C:\Recovery`、`pagefile.sys`、`WinSxS\Backup`、`Windows\Installer` | 删了系统坏或无法修复 |

**档 4 和档 5 的判断必须基于证据，不能基于"这个名字看起来像垃圾"。** 例：`C:\ProgramData\Adobe\CameraRaw` 2.19 GB 看着像缓存，实际是相机/镜头配置文件，删了 Photoshop 认不出镜头参数。

### 4. 执行：能移就不删

对档 1、档 4 的文件，**移进隔离区而不是硬删**：

```powershell
$quarantine = 'D:\_cleanup-quarantine'
# 保留原始路径结构，便于精确还原
$dest = Join-Path $quarantine ($src.Substring(0,1) + '\' + $src.Substring(3))
```

对档 2、档 3 里明确可再生的（安装包、包管理器缓存），直接删即可，没必要占隔离区空间。

**隔离区必须排除在扫描/清理范围之外**，否则清理脚本会把自己的输出当成垃圾再搬一次（见 `references/pitfalls.md` 第 6 条）。

### 5. 验证

```powershell
$before = (Get-PSDrive C).Free
# ... 执行清理 ...
Start-Sleep -Seconds 2
$after = (Get-PSDrive C).Free
'实际释放 {0:N2} GB' -f (($after - $before) / 1GB)
```

差值明显小于预期时，对照下面九类坑逐条排查。

## "删了不释放"的九类坑

详见 [`references/pitfalls.md`](references/pitfalls.md)，摘要：

| # | 现象 | 真相 |
|---|---|---|
| 1 | 目录不存在了，空间没变 | 文件被进程持有句柄，NTFS POSIX 删除要等句柄关闭 |
| 2 | `Remove-Item` 报成功、实际没删 | `-ErrorAction SilentlyContinue` 吞掉了 Access Denied |
| 3 | 管理员也删不掉 | 归 `TrustedInstaller` 所有，要先 `takeown` + `icacls` |
| 4 | WinSxS 累加值掉 5 GB，空间不变 | 硬链接：删的是引用，数据仍被 System32 引用 |
| 5 | 差 15 GB 找不到 | Windows「保留存储」，`fsutil` 里叫 Volume storage reserved bytes |
| 6 | 清理脚本越跑越乱 | 隔离区被自己扫描并二次移动，形成嵌套 |
| 7 | 还原点删了没释放 | `vssadmin` 的 Used ≠ 立即可回收 |
| 8 | Defender 目录异常大 | Defender 被第三方杀软接管后，Quarantine 是历史遗留 |
| 9 | 游戏/软件目录删不掉 | 子文件带显式 DENY ACE，DENY 优先于任何 Allow |

## 不要碰的目录

```
C:\Windows\*                    系统
C:\Windows\System32\config      注册表配置单元
C:\Windows\Installer            MSI 缓存，删了软件无法修复/卸载
C:\Windows\WinSxS\Backup        组件修复要用
C:\Recovery                     恢复镜像，删了"重置此电脑"失效
C:\$Recycle.Bin                 走回收站清空，别手删
pagefile.sys / swapfile.sys     内存交换
Program Files\*\...\node_modules  全局包（删了工具就没了）
任何用户的 .git 目录
```

## 系统级可回收项（需管理员）

| 项目 | 命令 | 典型收益 |
|---|---|---|
| Windows 保留存储 | `DISM /Online /Set-ReservedStorageState /State:Disabled` | 本机 14.36 GB |
| 组件清理（DISM 被拦时） | `schtasks /Run /TN "\Microsoft\Windows\Servicing\StartComponentCleanup"` | 视硬链接而定 |
| Windows 错误报告 | 清 `C:\ProgramData\Microsoft\Windows\WER\Report*` | 本机 1.33 GB |
| Defender 遗留隔离区 | `takeown` 后删 `...\Windows Defender\Quarantine` | 本机 4.11 GB |
| 系统还原点 | `vssadmin delete shadows /for=C: /all /quiet` | 视占用，可逆性差 |

保留存储关闭是**可逆**的（`/State:Enabled` 恢复），且立即归还空间，通常是单笔收益最大的一项。

## 交付前的自检清单

- [ ] 扫描用的是 `'C:\'`（带反斜杠）而非 `'C:'`
- [ ] 遍历跳过了 reparse point，并单独列出了 junction 清单
- [ ] 每个待删目录都确认过 `(Get-Item $p -Force).LinkType` 为空
- [ ] 没有任何 `Remove-Item` 被 `-ErrorAction SilentlyContinue` 包裹
- [ ] 需 `TrustedInstaller` 的目录已 `takeown` + `icacls`
- [ ] 隔离区排除了自身路径
- [ ] 最终结论来自 `Get-PSDrive` 差值，而非脚本自报
