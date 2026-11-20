# DSH Windows Skills

A collection of Windows operations skills distilled from **real incidents**, aimed at AI agents driving a local Windows machine.

This is not a "cleanup tricks" collection. It is **checklists built from things that actually broke** — every pitfall maps to a real failure or a failed attempt.

## Skills

| Skill | Problem it solves |
|---|---|
| [`windows-disk-cleanup`](skills/windows-disk-cleanup/SKILL.md) | Scan → five-tier risk classification → quarantine → verify. Covers the "deleted but space not freed" traps: Reserved Storage, WinSxS hardlinks, TrustedInstaller ownership |
| [`windows-admin-scripting`](skills/windows-admin-scripting/SKILL.md) | Three hard rules for handing an admin script to a normal user (UTF-8 BOM / never self-elevate from a `.bat` / never swallow Access Denied) |
| [`windows-link-safety`](skills/windows-link-safety/SKILL.md) | Always check for junctions and symlinks before deleting. Includes the full postmortem of deleting a user's WeChat |
| [`dsh-profile-recovery`](skills/dsh-profile-recovery/SKILL.md) | Recovering a DSH Desktop profile that got reset (memory tools returning `unknown tool`) from health snapshots |

## Documentation

| Document | Contents |
|---|---|
| [`docs/incident-report.md`](docs/incident-report.md) | **Full incident report** (Chinese): how "clean up my C drive" turned into deleting WeChat and breaking the dev environment, with root-cause analysis, fix steps and evidence |
| [`skills/windows-disk-cleanup/references/pitfalls.md`](skills/windows-disk-cleanup/references/pitfalls.md) | Nine traps where files are deleted but disk space never comes back |

## Where these skills come from

A single request — *"help me clean up my C drive"* — ended up as:

- **115 GB reclaimed** (C: 61.6 → 104.3 GB, D: 544.9 → 617.3 GB)
- Accidentally deleting the user's WeChat (junction mistaken for a stale copy), then diagnosing and repairing it
- Migrating the npm global directory, which broke 482 junctions, caused the DSH Desktop profile to be auto-reset, and made the memory plugin disappear
- Hitting 9 distinct "deleted but space not freed" traps
- Rewriting the admin cleanup script five times before the encoding and elevation problems were fully solved

Every pitfall in these skills includes **the actual observed numbers** (durations, sizes, error codes) so you can tell whether you are hitting the same problem.

## Repository layout

```
docs/
  incident-report.md          # full postmortem with evidence
skills/
  windows-disk-cleanup/
    SKILL.md
    scripts/scan.ps1          # single-pass, multi-metric disk scanner
    references/pitfalls.md    # nine traps in detail
  windows-admin-scripting/
    SKILL.md
  windows-link-safety/
    SKILL.md
  dsh-profile-recovery/
    SKILL.md
```

## Requirements

- Windows 10 / 11 (validated on Windows 11 build 26200)
- Compatible with both Windows PowerShell 5.1 and PowerShell 7
- Some operations require administrator privileges; each is marked in the SKILL

## Installation

These `SKILL.md` files follow the common skill format (YAML frontmatter + Markdown body), so they can be dropped into any skill directory that supports it:

```powershell
# Copy into a DSH skill library
Copy-Item -Recurse skills\* "$env:USERPROFILE\.agents\skills\"
```

## Notes on the environment

Some pitfalls are environment-specific and documented here because they were genuinely encountered:

- `github.com` resolving to an unreachable IP while `api.github.com` resolves correctly — this is why gh/git need an explicit `HTTPS_PROXY`
- Windows PowerShell 5.1 enumerating `C:\Windows\WinSxS\Temp` taking **92.7 seconds** for 588 files, which looks exactly like a hang
- A `.ps1` saved as UTF-8 without BOM being read as GBK by 5.1, garbling the Chinese and breaking string terminators

## License

MIT
