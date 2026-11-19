# Windows「删了但不释放空间」的九类坑

每条都来自实际观测，包含真实数字和错误码，可以直接用来比对。

---

## 1. 目录不存在了，可用空间没变 —— 文件仍被进程持有句柄

**现象**：`D:\DeliveryOptimization\Cache` 删除后目录确实消失（3.28 GB），但 D 盘可用只增加 0.83 GB。

**原因**：Windows 10 1709+ 的 NTFS 支持 POSIX 语义删除——**可以删除正在被打开的文件**。目录项消失，但簇要等最后一个句柄关闭才归还。

**典型持有者**：Windows 更新相关服务（`DoSvc`、`TrustedInstaller`）、杀软、正在写的日志。

**判断**：

```powershell
Get-Service DoSvc,TrustedInstaller | Select-Object Name, Status
```

**处理**：重启，或停止对应服务后再看。不要因为"删了没效果"反复删同一批文件——它们已经删了。

---

## 2. `Remove-Item` 报成功、实际一个都没删 —— 异常被吞了

**现象**：脚本打印 `[OK] 清理完成`，磁盘可用零变化。

**原因**：

```powershell
Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
```

`-ErrorAction SilentlyContinue` 把 `Access Denied` 静默吞掉，循环照常继续，最后统计出来的"释放量"是从枚举阶段算的、并非真实删除量。

**处理**：删完必须用 `Test-Path` 验证；批量删要 try/catch 计数失败项。

```powershell
try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop }
catch { $fail++ }
if (Test-Path -LiteralPath $p) { '未删除干净' }
```

---

## 3. 管理员也删不掉 —— 归 `TrustedInstaller` 所有

**现象**：以管理员运行，`C:\Windows\WinSxS\Temp`、`C:\Windows\Logs\CBS` 删除仍报 `Access ... is denied`。

**原因**：这些目录的属主是 `NT SERVICE\TrustedInstaller`，`Administrators` 组只有读权限。

**处理**：

```powershell
takeown /f "C:\Windows\WinSxS\Temp" /r /a /d Y
icacls  "C:\Windows\WinSxS\Temp" /grant "Administrators:(OI)(CI)F" /t /c /q
# 然后再删
```

顺序很重要：先 `takeown` 改属主，再 `icacls` 给权限。

---

## 4. WinSxS 累加值掉 5 GB，磁盘一点没变 —— 硬链接

**现象**：DISM 组件清理后，扫描 WinSxS 从 18.40 GB 变成 12.84 GB，但可用空间几乎不动。

**原因**：Windows 组件库与 `System32` 大量共享同一份数据（NTFS 硬链接）。按路径累加会重复计算；DISM 删掉的是**引用**，底层数据仍被 `System32` 引用着。

**结论**：**WinSxS 的文件大小累加值不可信**。判断真实释放只看 `Get-PSDrive` 的 Free。

同理，任何"扫描累加值"都不能当释放量用——尤其在有大量硬链接/硬链接复制的系统目录。

---

## 5. 差十几 GB 找不到 —— Windows「保留存储」

**现象**：磁盘已用 126.74 GB，全盘扫描累加只有 111.76 GB，差 15 GB 怎么都找不到。

**原因**：Windows 的 **Reserved Storage**（为系统更新预留的空间）。

**判断**：

```powershell
fsutil volume diskfree C:
```

关键字段：

```
Used bytes                     : 119,533,490,176 (111.3 GB)   ← 真实文件
Total Reserved bytes           :  16,547,979,264 ( 15.4 GB)
Volume storage reserved bytes  :  15,364,321,280 ( 14.3 GB)   ← 就是它
```

注册表佐证：

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' |
    Select-Object ShippedWithReserves, BaseHardReserveSize, BaseSoftReserveSize
# ShippedWithReserves = 1 表示出厂启用
```

**处理**（可逆，立即归还）：

```powershell
DISM /Online /Set-ReservedStorageState /State:Disabled     # 关闭
DISM /Online /Set-ReservedStorageState /State:Enabled      # 恢复
DISM /Online /Get-ReservedStorageState                     # 查询
```

本机实测释放 **14.36 GB**，是单笔收益最大的一项。

**非管理员执行会返回 `Error: 740`**（`ERROR_ELEVATION_REQUIRED`）——这反而是"命令和参数都合法、只缺提权"的证据，可用来做语法预检。

---

## 6. 清理脚本越跑越乱 —— 隔离区被自己扫描并二次移动

**现象**：把文件移进 `D:\_cleanup-quarantine` 后，发现隔离区里出现了 `D:\_cleanup-quarantine\D\_cleanup-quarantine\...` 的嵌套。

**原因**：脚本按 `foreach ($root in 'C:\','D:\')` 扫两遍。C 盘那趟把文件移进 D 盘隔离区；紧接着扫 D 盘时，**把隔离区自己当垃圾又扫了一遍**，二次移动到它自己的内部。

**处理**：

- 遍历时显式排除输出目录

```powershell
if ($dir -like "$quarantine*") { continue }
```

- 或者隔离区放在扫描范围之外的盘
- 已经嵌套的，用一条移动把它们合并回正常层级，并重建 manifest

---

## 7. 还原点删了没释放

**现象**：`vssadmin` 显示 `Used Shadow Copy Storage space: 3.16 GB`，删掉全部还原点后可用只 +0.30 GB。

**原因**：`Used` 是卷影存储的**分配量**，不等于删除后立即归还的量。存储关联重建需要时间，也可能被其它快照复用。

**处理**：`vssadmin delete shadows /for=C: /all /quiet` 之后不要立刻下结论，重启后再看；同时把上限调小防膨胀：

```powershell
vssadmin resize shadowstorage /for=C: /on=C: /maxsize=5%
```

**注意**：这属于"不可逆"操作，删除后无法用系统还原回滚，必须让用户明确同意。

---

## 8. Defender 目录异常大 —— 第三方杀软接管后的遗留

**现象**：`C:\ProgramData\Microsoft\Windows Defender` 占 4.84 GB，其中 `Quarantine` 4.11 GB。

**原因**：装第三方杀软（如火绒）后 Windows Defender 会被关闭，但它当年的隔离区、扫描历史仍在磁盘上。非管理员看不到这些目录（枚举返回 0 字节）。

**判断**：

```powershell
Get-MpComputerStatus | Select-Object AntivirusEnabled, RealTimeProtectionEnabled, IsTamperProtected
```

- `AntivirusEnabled=False` + `IsTamperProtected=False` → 已被接管，隔离区是历史遗留，可清
- `IsTamperProtected=True` → 必须先关篡改防护才能删

**注意**：Defender 关闭时 `Get-MpThreat` 返回空，**不能用它判断隔离区是否有内容**，要看目录大小。

---

## 9. 游戏/软件目录删不掉 —— 显式 DENY ACE

**现象**：某目录下所有文件删除都报 `Access to the path '...' is denied.`，连重命名也失败。

**原因**：文件带显式拒绝 ACE，例如联想商店给下载的安装包加了：

```
BUILTIN\Users:(DENY)(DE,WD,AD,WEA,WA)
```

`DE` = 删除、`WD` = 写数据。**DENY 优先于任何 Allow**，所以即使 `Authenticated Users` 有 `(M)` 修改权限也无效。

**判断**：

```powershell
icacls "D:\LeStoreDownload\某文件.exe"
```

看到 `(DENY)` 就是这种情况。

**处理**（需管理员）：

```powershell
icacls "D:\LeStoreDownload" /remove:d "Users" /t /c /q
# 或者整体接管
takeown /f "D:\LeStoreDownload" /r /a /d Y
icacls  "D:\LeStoreDownload" /grant "Administrators:(OI)(CI)F" /t /c /q
```

如果只有 `Users:(RX)`（没有 DENY），那只是权限不足，`takeown` 接管即可。

---

## 附：判断「占用」还是「权限」

| 错误文本 | 含义 | 对策 |
|---|---|---|
| `The process cannot access the file because it is being used by another process` | 被占用 | 关进程 / 重启 |
| `Access to the path '...' is denied.` | 权限（可能是 ACL、可能是沙箱） | 提权 / `takeown` / 检查 DENY ACE |

不要凭猜测归类——错误文本是最快的分诊依据。
