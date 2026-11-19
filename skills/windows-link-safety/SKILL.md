---
name: windows-link-safety
description: 删除任何"重复目录""迁移副本"之前的安全检查——如何识别 junction/符号链接，以及迁移全局目录会连锁断掉哪些东西（含一次删掉微信的完整复盘）
---

# 删除前先查链接

Windows 上「看起来有重复的两份数据」经常不是重复，而是**一个链接指向另一个实体**。删错一边，另一边的程序当场消失。

本技能来自一次真实事故：清理磁盘时删掉「迁移副本」，把用户的微信删没了。

## 什么时候必须查

准备删除以下任一类目录前：

- 名字含 `迁移`、`搬家`、`backup`、`old`、`副本`、`copy` 的目录
- 出现在「两个位置都有同名目录」的情况
- `C:\Program Files\*` 下的目录（联想/厂商工具经常用 junction）
- 空的或看起来只有几字节的目录（可能是断链）
- 迁移全局模块目录（`%APPDATA%\npm`、`AppData\Local\pnpm` 等）之前

## 怎么查

### 单个目录

```powershell
$p = 'C:\Program Files\Tencent\weixin'
$i = Get-Item -LiteralPath $p -Force
$i.LinkType    # Junction / SymbolicLink / HardLink / 空
$i.Target      # 指向哪里
($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
```

### 批量列出某目录下的所有链接

```powershell
cmd /c 'dir /a:l "C:\Program Files\Tencent"'
```

PowerShell 版：

```powershell
Get-ChildItem 'C:\Program Files\Tencent' -Force |
    Where-Object { $_.LinkType } |
    Select-Object Name, LinkType, Target
```

### 扫描整个盘时记录链接清单

遍历时遇到 reparse point **不要进入**，但要记下来：

```powershell
if ((($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0) {
    $li = Get-Item -LiteralPath $d.FullName -Force
    $links += [pscustomobject]@{ Path = $d.FullName; Type = $li.LinkType; Target = ($li.Target -join ';') }
    continue
}
```

删除前检查这份清单里**有没有任何链接指向你要删的目标**。

### 判断是不是断链

**`Test-Path` 不可靠**——它对 junction/symlink 本身会返回 `True`，哪怕目标早已不存在。

```powershell
# 错误判断
Test-Path 'D:\dsh-home\profiles\node_modules\@deepseek-ai\dsh-fs'   # 断链也返回 True

# 正确判断：能否读到子项
@(Get-ChildItem 'D:\dsh-home\profiles\node_modules\@deepseek-ai\dsh-fs' -Force -ErrorAction SilentlyContinue).Count
# 0 → 断链
```

## 事故复盘：删「迁移副本」把微信删没了

### 现场

```
C:\Program Files\Tencent\weixin      ← 看起来"程序在这里"
D:\电脑管家迁移文件\weixin            ← 看起来"这是死副本"
```

微信进程的 `Path` 属性显示 `C:\Program Files\Tencent\Weixin\Weixin.exe`，于是判断「C 盘这份是活的，D 盘那份可以删」，把 D 盘目录删了。

### 真相

```
C:\Program Files\Tencent\weixin
  LinkType : Junction
  Target   : D:\电脑管家迁移文件\weixin
```

联想电脑管家「C 盘搬家」把程序**实体**移到了 D 盘，在 C 盘原位置留了个 junction。微信是通过链接正常运行。

**进程的 `Path` 显示的是解析后的路径，不是链接路径**——这是最迷惑人的一点。从进程信息完全看不出它是链接。

删掉 D 盘实体后，junction 变成断链 → 微信直接消失：目录还在、快捷方式还在、注册表还在，但打不开。

### 代价

程序本体丢失（本机 0.88 GB），需要重新下载官方安装包重装。**聊天数据没丢**，因为数据目录（`%APPDATA%\Tencent\xwechat\xwechat_files`）不在被删范围内。

同一台机器上剪映也是这个模式：`C:\Users\...\AppData\Local\JianyingPro` 是空壳（0 字节），实体在 `D:\电脑管家迁移文件\JianyingPro`。那次因为空壳确实是 0 字节，判断对了；微信那次反向，判断错了。

### 正确做法

1. 先跑一遍链接检查
2. 如果发现是 junction：**要么删链接本身（`cmd /c rmdir <link>`，不碰目标），要么删目标并确认没有别的链接依赖它**
3. 判断「谁是实体」：`LinkType` 为空的那个才是实体

## 迁移全局目录的连锁影响

删除/迁移以下目录前，**必须先找出所有依赖它的链接**：

| 目录 | 典型依赖者 |
|---|---|
| `C:\Users\<u>\AppData\Roaming\npm` | 各工具的 junction、全局 CLI 的 shim、AI Agent 的 profile 依赖树 |
| `C:\Users\<u>\AppData\Local\pnpm` | pnpm store 的旧位置 |
| `C:\Program Files\*` | 厂商工具的搬迁链接 |

### 本机实例：迁移 npm 目录导致 482 个链接断裂

把 `C:\Users\AA\AppData\Roaming\npm` 迁到 `D:\dev-store\npm-global` 并删除原目录之后：

1. **482 个 junction 断链** —— 位于 `D:\dsh-home\profiles\node_modules\*`，目标全是 `C:\Users\AA\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\node_modules\...`
2. **DSH Desktop 启动时模块解析失败 → 自动重建 profile**
3. **profile 配置被重置成最小版** —— bundles 从 6 个掉到 2 个、`cordis.patch.yml` 从 3171 字节变成空数组 `[]`、`node_modules` 清空
4. 表现：会话里 memory / dtodo / skill_manage 与全部 MCP 工具消失

**修复只需一行**：

```powershell
# 把旧路径重建为指向新位置的 junction（junction 不需要管理员权限）
cmd /c 'mklink /J "C:\Users\AA\AppData\Roaming\npm" "D:\dev-store\npm-global"'
```

旧路径立刻恢复为别名，482 个链接自动全部可用。

### 教训

动全局模块目录时，优先选**加一层 junction 别名**，而不是搬实体：

```powershell
# 推荐：实体留在原处，只在需要的地方建链接
# 或：先搬实体，立刻在原路径建 junction 指回去
cmd /c 'mklink /J "<原路径>" "<新路径>"'
```

## 删除前的检查清单

- [ ] 已用 `Get-Item $p -Force` 确认 `LinkType` 为空
- [ ] 已扫描全盘 junction 清单，确认没有链接指向该目标
- [ ] 已确认进程的 `Path` **不是**通过链接解析出来的
- [ ] 如果目标是「迁移副本」，已确认另一边不是 junction
- [ ] 如果是全局模块目录，已确认所有依赖方并准备在原路径建别名
- [ ] 删除后立刻验证依赖方仍可访问（`Get-ChildItem` 计数 > 0）
