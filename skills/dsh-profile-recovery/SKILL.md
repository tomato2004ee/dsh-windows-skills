---
name: dsh-profile-recovery
description: DSH Desktop 插件集体消失（memory/dtodo 等工具返回 unknown tool）时的诊断与恢复——从 health-snapshot 找回被重置的 profile 配置并重装依赖
---

# DSH Desktop profile 恢复

## 症状

会话运行中，部分工具突然不可用：

```
Error: unknown tool "memory"
Error: unknown tool "dtodo"
Error: unknown tool "skill_manage"
```

同时 MCP 服务（paper-search、绘图、zotero、新闻等）也从工具表里消失，技能目录变成精简版。

**关键判断：这不是会话问题，是 profile 配置被重置了。** 记忆数据本身通常完好。

## 成因

最常见的触发：**profile 依赖的模块路径失效**。

实例：把 `%APPDATA%\npm` 迁到别处并删除原目录后，DSH Desktop 下次启动时模块解析失败，触发自动重建 profile —— 重建时把配置覆盖成了最小版。

另一种：profile 安装过程被中断，留下 `.desktop.incomplete-<pid>-<uuid>` 残骸。

## 诊断

### 1. 确认 profile 位置

```powershell
"DSH_HOME = $env:DSH_HOME"
Get-ChildItem "$env:DSH_HOME\profiles" -Directory
```

注意有两个可能的位置：

- `C:\Users\<u>\.dsh\profiles\` —— 早期/命令行
- `D:\dsh-home\profiles\` 或 `$env:DSH_HOME\profiles\` —— 桌面端实际使用的

**以 `$env:DSH_HOME` 为准**，别只看 `.dsh`。

### 2. 检查配置是否被重置

```powershell
$dp = Join-Path $env:DSH_HOME 'profiles\desktop'
Get-Item "$dp\cordis.patch.yml","$dp\package.json" | Select-Object Name, Length
Get-ChildItem "$dp\node_modules" -Force   # 只有 pnpm 元数据 = 包全丢了
```

判据：

| 指标 | 正常 | 被重置 |
|---|---|---|
| `cordis.patch.yml` | 数 KB，含 MCP 配置 | 几百字节，内容是 `[]` |
| `package.json` 的 `dsh.profile.bundles` | 含 memory-evolve / photoshop 等 | 只剩 base + web-app |
| `package.json` 的 `dependencies` | 非空 | `{}` |
| `node_modules` | 有实体包 | 只有 `.modules.yaml` 等元数据 |

### 3. 确认记忆数据还在

```powershell
foreach ($p in "$env:USERPROFILE\.dsh\memories", (Join-Path $env:DSH_HOME 'memories')) {
    if (Test-Path $p) {
        '{0}  {1} 个文件' -f $p, @(Get-ChildItem $p -Recurse -File -Force).Count
        Get-ChildItem $p -Directory | Select-Object -ExpandProperty Name
    }
}
```

正常会看到 `daily/`、`projects/`、`advisor/`、`USER.md`、`SUGGESTIONS.jsonl`。数据在磁盘上就没丢。

## 恢复

### 第一步：从 health-snapshot 找回旧配置

DSH Desktop 每次成功启动都会存一份快照：

```powershell
$snaps = Get-ChildItem "$env:APPDATA\DSH Desktop\health-snapshots" -Directory
foreach ($s in $snaps) {
    foreach ($slot in Get-ChildItem $s.FullName -Directory) {
        $f = Join-Path $slot.FullName 'cordis.patch.yml'
        if (Test-Path $f) {
            '{0}  {1,6} 字节  {2}' -f $s.Name.Substring(0,12), (Get-Item $f).Length, $slot.Name
        }
    }
}
```

**挑字节数最大、日期最新的那组**（被重置后的快照只有几百字节，健康的通常几 KB）。

每个 slot 里通常有：

```
cordis.patch.yml      ← MCP 服务与插件配置
package.json          ← bundles 列表 + dependencies
pnpm-lock.yaml
pnpm-workspace.yaml
manifest.json         ← 快照元信息（含各文件 sha256，可用于校验）
home/settings.yaml
```

### 第二步：备份现状，再覆盖

```powershell
$dp  = Join-Path $env:DSH_HOME 'profiles\desktop'
$bak = Join-Path $dp ('_broken-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $bak | Out-Null

$good = 'C:\Users\<u>\AppData\Roaming\DSH Desktop\health-snapshots\<hash>\slot-1'
foreach ($f in 'package.json','cordis.patch.yml','pnpm-lock.yaml','pnpm-workspace.yaml') {
    $src = Join-Path $good $f
    if (Test-Path $src) {
        Copy-Item (Join-Path $dp $f) $bak -Force -ErrorAction SilentlyContinue   # 备份坏的
        Copy-Item $src $dp -Force
    }
}
```

**先备份再覆盖**——万一恢复后起不来，还能退回能启动的最小配置。

### 第三步：重装依赖

```powershell
Set-Location (Join-Path $env:DSH_HOME 'profiles\desktop')
dsh plugin --profile desktop install
```

`dsh plugin` 会把剩余参数**转发给 profile 目录里的 pnpm**，所以 `install` 等价于在该目录跑 `pnpm install`。

成功标志：`Packages: +N` / `Done in Xs`，之后 `node_modules` 出现实体包。

### 第四步：不启动应用的配置校验

这一步很关键——**不要靠重启来试错**：

```powershell
$out = & dsh --profile desktop --dump-config 2>&1 | Out-String
$out -match 'memory-evolve'      # 应为 True
$out -match 'mcp-paper-search'   # 应为 True
$out -match 'Error|Cannot find'  # 应为 False
```

`--dump-config` 会打印合成后的完整配置树然后退出，不启动应用、不影响当前会话。输出几百行且无 Error，就说明配置合法。

### 第五步：验证 MCP 依赖路径

旧配置里的 MCP 服务用**绝对路径**指向全局安装的脚本，这些路径必须仍然可达：

```powershell
$paths = @(
    'C:\Users\<u>\AppData\Roaming\npm\node_modules\paper-search-mcp-nodejs\dist\server.js',
    'C:\Users\<u>\AppData\Roaming\npm\node_modules\mcp-image\dist\index.js'
    # ...
)
foreach ($p in $paths) { '{0,-90} {1}' -f $p, $(if (Test-Path -LiteralPath $p) { 'OK' } else { '缺失' }) }
```

如果之前迁移过 `%APPDATA%\npm`，在原路径建 junction 就能全部恢复：

```powershell
cmd /c 'mklink /J "C:\Users\<u>\AppData\Roaming\npm" "D:\dev-store\npm-global"'
```

### 第六步：重启 DSH Desktop

配置在磁盘上正确了，但**当前进程还在用旧配置**，工具不会自己回来。关闭窗口重新打开即可。

⚠️ 重启会关闭当前会话窗口，历史记录仍在会话列表里。

## 恢复后的收尾

- 删除 `.incomplete-<pid>-<uuid>` 残骸目录（重建失败的产物，通常只有几 MB）
- 确认记忆工具可用后，把这次事故写进项目记忆
- 保留 `_broken-backup-*` 一段时间，确认稳定后再删

## 预防

| 措施 | 说明 |
|---|---|
| 迁移全局模块目录时**只在原路径建 junction 别名** | 不要搬实体，从根上避免依赖断裂 |
| 迁移后立刻验证依赖方 | `Get-ChildItem <junction> -Force` 计数 > 0 |
| 定期备份 profile 的 4 个配置文件 | `package.json` / `cordis.patch.yml` / lock / workspace |
| 保留几组 health-snapshot | 这是官方自带的恢复手段，别清掉 |

## 关联技能

- `windows-link-safety` —— 如何发现并避免链接断裂
- `windows-admin-scripting` —— 需要提权操作时的脚本规范
