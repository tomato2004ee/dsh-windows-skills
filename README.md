# DSH Windows Skills

一套从真实事故中提炼出来的 Windows 运维技能包，面向 **AI Agent 驱动本机 Windows** 的场景。

不是"清理大师"式的技巧合集，而是**把踩过的坑写成检查清单**——每条都对应一次真实的故障或失败尝试。

## 包含的技能

| Skill | 解决的问题 |
|---|---|
| [`windows-disk-cleanup`](skills/windows-disk-cleanup/SKILL.md) | 全盘扫描 → 五档分类 → 隔离 → 验证。含 Reserved Storage、WinSxS 硬链接、TrustedInstaller 等"删了不释放"的坑 |
| [`windows-admin-scripting`](skills/windows-admin-scripting/SKILL.md) | 给普通用户写管理员脚本的三条铁律（UTF-8 BOM / 禁止自提权 / 别吞 Access Denied） |
| [`windows-link-safety`](skills/windows-link-safety/SKILL.md) | 删除前必查 junction / symlink。含一次"删迁移副本把微信删没了"的完整复盘 |
| [`dsh-profile-recovery`](skills/dsh-profile-recovery/SKILL.md) | DSH Desktop 插件集体消失（memory 等工具返回 unknown tool）时，如何从 health-snapshot 恢复 |

## 这些经验从哪来

一次"帮我把 C 盘清理一下"的请求，最终演变成：

- 释放 **115 GB**（C: 61.59 → 104 GB，D: 545 → 617 GB）
- 意外删掉用户的微信（junction 误判），随后定位并修复
- 迁移 npm 全局目录，导致 DSH Desktop 的 482 个 junction 断链、profile 被自动重置、记忆插件消失
- 踩了 9 个"删了但空间没释放"的坑
- 写了 5 个版本的管理员清理脚本才把编码和提权问题彻底解决

每条 skill 里的"坑"都标注了**实际观测到的数字**（耗时、大小、错误码），可以直接用来判断自己遇到的是不是同一个问题。

## 目录结构

```
skills/
  windows-disk-cleanup/
    SKILL.md
    scripts/scan.ps1          # 一次遍历、多项统计的扫描器
    references/pitfalls.md    # 9 个真实坑的详细复盘
  windows-admin-scripting/
    SKILL.md
  windows-link-safety/
    SKILL.md
  dsh-profile-recovery/
    SKILL.md
```

## 适用环境

- Windows 10 / 11（在 Windows 11 build 26200 上验证）
- Windows PowerShell 5.1 与 PowerShell 7 都兼容
- 部分操作需要管理员权限，SKILL 里逐条标注

## 使用方式

这些 SKILL.md 遵循 `skill` 的通用格式（YAML frontmatter + Markdown 正文），
可以放进任何支持该格式的技能目录，例如：

```powershell
# 复制到 DSH 技能库
Copy-Item -Recurse skills\* "$env:USERPROFILE\.agents\skills\"
```

## License

MIT
