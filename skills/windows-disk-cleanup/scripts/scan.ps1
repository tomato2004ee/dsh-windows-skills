# 全盘扫描器：一次遍历，多项统计
#
# 用法：
#   .\scan.ps1 -Root 'C:\' -OutDir 'D:\scan-out'
#   .\scan.ps1 -Root 'D:\' -OutDir 'D:\scan-out' -MaxMinutes 25
#
# 产出：
#   level1.txt      一级目录占用（Top N）
#   level2.txt      二级目录占用
#   buckets.txt     分类桶（node_modules / Cache / Temp / WinSxS ...）
#   big.txt         大文件清单
#   dup.txt         同名同大小重复候选
#   empty.txt       空目录清单
#   links.txt       junction / symlink 清单（绝不能当垃圾删）
#
# 设计要点：
#   1. 用 DirectoryInfo.GetFiles/GetDirectories 手动栈遍历 —— Get-ChildItem -Recurse 在超长路径上会静默漏文件
#   2. 跳过 reparse point（junction 环会让遍历跑不完），但记录下来
#   3. 命中"桶"目录后直接算子树大小、不再下钻，避免重复计数
#   4. Root 必须带尾反斜杠 —— DirectoryInfo('D:') 表示"该盘当前目录"而非根目录

param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [int]$MaxMinutes = 25,
    [long]$BigFileBytes = 200MB,
    [long]$DupMinBytes = 20MB,
    [int]$TopN1 = 40,
    [int]$TopN2 = 50
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$deadline = (Get-Date).AddMinutes($MaxMinutes)

# 归一化根路径
if (-not $Root.EndsWith('\')) { $Root += '\' }
$rootLen = $Root.Length
# 根是盘符（'D:\'）时标签用 'D:'；否则用完整前缀，否则一级目录名会串位
$rootLabel = if ($Root -match '^[A-Za-z]:\\$') { $Root.Substring(0, 2) } else { $Root.TrimEnd('\') }
if (-not (Test-Path -LiteralPath $Root)) { throw "根路径不存在: $Root" }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$f1 = @{}; $f2 = @{}; $bucket = @{}
$big = New-Object System.Collections.Generic.List[object]
$dup = @{}
$empty = New-Object System.Collections.Generic.List[string]
$links = New-Object System.Collections.Generic.List[object]
$totalFiles = [long]0; $totalBytes = [long]0; $dirs = [long]0

# 目录名 -> 分类桶。命中即不下钻
$segMap = @{
    'node_modules' = '构建缓存: node_modules'; '__pycache__' = '构建缓存: __pycache__'
    '.pytest_cache' = '构建缓存: .pytest_cache'; '.gradle' = '构建缓存: .gradle'
    '.cargo' = '构建缓存: .cargo'; '.venv' = '虚拟环境: .venv'; 'venv' = '虚拟环境: venv'
    '.git' = 'Git 仓库: .git'; '.npm' = '包缓存: .npm'; '.nuget' = '包缓存: .nuget'
    '.m2' = '包缓存: .m2'; '.conda' = '包缓存: .conda'
    'cache' = '缓存: Cache'; 'caches' = '缓存: Caches'; 'gpucache' = '缓存: GPUCache'
    'code cache' = '缓存: Code Cache'; 'shadercache' = '缓存: ShaderCache'
    'd3dscache' = '缓存: D3DSCache'; 'crashpad' = '缓存: Crashpad'
    'temp' = '临时: Temp'; 'tmp' = '临时: tmp'
    'winsxs' = '系统: WinSxS'; 'softwaredistribution' = '系统: SoftwareDistribution'
    'deliveryoptimization' = '系统: 交付优化'; '$recycle.bin' = '系统: 回收站'
    'ms-playwright' = '自动化: ms-playwright'
}

function Add-Stat($dict, $key, $bytes, $count) {
    if ($null -eq $dict[$key]) { $dict[$key] = @{ B = [long]$bytes; C = [long]$count } }
    else { $dict[$key].B += [long]$bytes; $dict[$key].C += [long]$count }
}

$stack = New-Object System.Collections.Generic.Stack[object]
$stack.Push([pscustomobject]@{ P = $Root; B = $null })

while ($stack.Count -gt 0) {
    if ((Get-Date) -gt $deadline) { Write-Warning "达到时间上限，结果不完整"; break }

    $it  = $stack.Pop()
    $dir = $it.P
    $bkt = $it.B

    $di = New-Object System.IO.DirectoryInfo($dir)
    $files = $null; $subs = $null
    try { $files = $di.GetFiles() }       catch { $files = $null }
    if ($null -eq $files) { continue }     # 无权限目录整体跳过
    try { $subs  = $di.GetDirectories() } catch { $subs  = $null }
    $dirs++

    # 记录空目录
    if ($files.Count -eq 0 -and ($null -eq $subs -or $subs.Count -eq 0) -and $dir.Length -gt $rootLen) {
        $empty.Add($dir)
    }

    foreach ($d in $subs) {
        # reparse point：只记录，绝不进入
        if ((($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -ne 0) {
            $li = Get-Item -LiteralPath $d.FullName -Force
            $links.Add([pscustomobject]@{ Path = $d.FullName; Type = $li.LinkType; Target = ($li.Target -join ';') })
            continue
        }
        $cb = $bkt
        if ($null -eq $cb) {
            $nm = $d.Name.ToLowerInvariant()
            if ($segMap.ContainsKey($nm)) { $cb = $segMap[$nm] }
        }
        $stack.Push([pscustomobject]@{ P = $d.FullName; B = $cb })
    }

    foreach ($f in $files) {
        $len  = [long]$f.Length
        $full = $f.FullName
        $totalFiles++; $totalBytes += $len
        if ($null -ne $bkt) { Add-Stat $bucket $bkt $len 1 }

        # 一级 / 二级目录归属
        if ($full.Length -gt $rootLen) {
            $rel = $full.Substring($rootLen)
            $p1 = $rel.IndexOf('\')
            if ($p1 -gt 0) {
                $k1 = $rootLabel + '\' + $rel.Substring(0, $p1)
                if ($f1.ContainsKey($k1)) { $f1[$k1] += $len } else { $f1[$k1] = $len }
                $rest = $rel.Substring($p1 + 1)
                $p2 = $rest.IndexOf('\')
                if ($p2 -gt 0) {
                    $k2 = $k1 + '\' + $rest.Substring(0, $p2)
                    if ($f2.ContainsKey($k2)) { $f2[$k2] += $len } else { $f2[$k2] = $len }
                }
            }
        }

        if ($len -ge $BigFileBytes) {
            $big.Add([pscustomobject]@{ MB = [math]::Round($len / 1MB, 1); Path = $full })
        }

        if ($len -ge $DupMinBytes) {
            $key = $f.Name.ToLowerInvariant() + '|' + $len
            if ($null -eq $dup[$key]) {
                $lst = New-Object System.Collections.Generic.List[string]
                $lst.Add($full); $dup[$key] = $lst
            } elseif ($dup[$key].Count -lt 8) { $dup[$key].Add($full) }
        }
    }
}

# ---------- 输出 ----------
$drive = Get-PSDrive ([System.IO.Path]::GetPathRoot($Root).Substring(0,1))
Write-Host ""
Write-Host "================ SCAN SUMMARY ================"
Write-Host ("根路径   : {0}" -f $Root)
Write-Host ("文件     : {0:N0}" -f $totalFiles)
Write-Host ("目录     : {0:N0}" -f $dirs)
Write-Host ("扫描累加 : {0:N2} GB   ← 注意：硬链接会重复计算，不是真实占用" -f ($totalBytes/1GB))
if ($drive) { Write-Host ("磁盘已用 : {0:N2} GB / 可用 {1:N2} GB" -f ($drive.Used/1GB), ($drive.Free/1GB)) }
Write-Host ("空目录   : {0:N0} 个" -f $empty.Count)
Write-Host ("链接     : {0:N0} 个（junction/symlink，勿删）" -f $links.Count)

$l1 = @($f1.GetEnumerator() | Sort-Object { - $_.Value } | Select-Object -First $TopN1 |
        ForEach-Object { "{0,9:N2} GB  {1}" -f ($_.Value/1GB), $_.Key })
Set-Content (Join-Path $OutDir 'level1.txt') -Value $l1 -Encoding utf8
Write-Host ""
Write-Host "---- 一级目录 Top $TopN1 ----"
$l1 | ForEach-Object { Write-Host $_ }

$l2 = @($f2.GetEnumerator() | Sort-Object { - $_.Value } | Select-Object -First $TopN2 |
        ForEach-Object { "{0,9:N2} GB  {1}" -f ($_.Value/1GB), $_.Key })
Set-Content (Join-Path $OutDir 'level2.txt') -Value $l2 -Encoding utf8

$lb = @($bucket.GetEnumerator() | Sort-Object { - $_.Value.B } |
        ForEach-Object { "{0,9:N2} GB  {1,8:N0} 个  {2}" -f ($_.Value.B/1GB), $_.Value.C, $_.Key })
Set-Content (Join-Path $OutDir 'buckets.txt') -Value $lb -Encoding utf8
Write-Host ""
Write-Host "---- 分类桶 ----"
$lb | ForEach-Object { Write-Host $_ }

$bf = @($big | Sort-Object { - $_.MB })
Set-Content (Join-Path $OutDir 'big.txt') -Value @($bf | ForEach-Object { "{0}`t{1}" -f $_.MB, $_.Path }) -Encoding utf8
Write-Host ""
Write-Host ("---- 大文件 (>={0:N0} MB): {1} 个 ----" -f ($BigFileBytes/1MB), $bf.Count)
$bf | Select-Object -First 20 | ForEach-Object { Write-Host ("{0,9:N1} MB  {1}" -f $_.MB, $_.Path) }

$du = @($dup.GetEnumerator() | Where-Object { $_.Value.Count -ge 2 } | ForEach-Object {
    $parts = $_.Key.Split('|')
    [pscustomobject]@{
        Name = $parts[0]; MB = [math]::Round([long]$parts[1]/1MB,1); Count = $_.Value.Count
        Waste = [math]::Round((([long]$parts[1])*($_.Value.Count-1))/1MB,1)
        Paths = ($_.Value -join ' || ')
    }
} | Sort-Object { - $_.Waste })
Set-Content (Join-Path $OutDir 'dup.txt') -Value @($du | ForEach-Object {
    "WASTE {0,9:N1} MB  x{1}  {2}`r`n      {3}" -f $_.Waste, $_.Count, $_.Name, $_.Paths }) -Encoding utf8
Write-Host ""
Write-Host ("---- 重复候选: {0} 组 ----" -f $du.Count)
$du | Select-Object -First 15 | ForEach-Object { Write-Host ("浪费 {0,8:N1} MB  x{1}  {2}" -f $_.Waste, $_.Count, $_.Name) }

Set-Content (Join-Path $OutDir 'empty.txt') -Value $empty -Encoding utf8

Set-Content (Join-Path $OutDir 'links.txt') -Value @($links | ForEach-Object { "{0}`t{1}`t{2}" -f $_.Type, $_.Path, $_.Target }) -Encoding utf8
if ($links.Count -gt 0) {
    Write-Host ""
    Write-Host "---- 链接（删除前务必核对）----"
    $links | Select-Object -First 20 | ForEach-Object { Write-Host ("  [{0}] {1}  ->  {2}" -f $_.Type, $_.Path, $_.Target) }
    if ($links.Count -gt 20) { Write-Host ("  ... 其余 {0} 个见 links.txt" -f ($links.Count - 20)) }
}

Write-Host ""
Write-Host "输出目录: $OutDir"
Write-Host "================ DONE ================"
