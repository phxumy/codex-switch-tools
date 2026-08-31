[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourcePath = Join-Path $repositoryRoot 'src\CodexSwitchTools.Gui.cs'
$manifestPath = Join-Path $repositoryRoot 'src\CodexSwitchTools.Gui.manifest'
$corePath = Join-Path $repositoryRoot 'Codex-Switch-Tools.ps1'

$writeRepositoryChecksum = [string]::IsNullOrWhiteSpace($OutputPath)
if ($writeRepositoryChecksum) {
    $OutputPath = Join-Path $repositoryRoot 'dist\CodexSwitchTools.exe'
}

$compilerCandidates = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$compilerPath = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compilerPath) { throw '没有找到 .NET Framework C# 编译器 csc.exe。' }

foreach ($required in @($sourcePath, $manifestPath, $corePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "缺少构建文件：$required" }
}

$outputDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
if (-not (Test-Path -LiteralPath $outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }

$sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash
$coreHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $corePath).Hash
$fingerprintPath = Join-Path $outputDirectory ('.cst-build-fingerprint-' + [guid]::NewGuid().ToString('N') + '.txt')
try {
    [IO.File]::WriteAllText($fingerprintPath, ($sourceHash + [Environment]::NewLine + $coreHash), [Text.UTF8Encoding]::new($false))
    & $compilerPath `
        /nologo `
        /optimize+ `
        /platform:anycpu `
        /target:winexe `
        "/win32manifest:$manifestPath" `
        "/resource:$corePath,CodexSwitchTools.Core.ps1" `
        "/resource:$fingerprintPath,CodexSwitchTools.BuildFingerprint.txt" `
        "/out:$OutputPath" `
        /reference:System.dll `
        /reference:System.Core.dll `
        /reference:System.Drawing.dll `
        /reference:System.Security.dll `
        /reference:System.Web.Extensions.dll `
        /reference:System.Windows.Forms.dll `
        $sourcePath

    if ($LASTEXITCODE -ne 0) { throw "编译失败，csc.exe 退出代码：$LASTEXITCODE" }
} finally {
    if (Test-Path -LiteralPath $fingerprintPath -PathType Leaf) { [IO.File]::Delete($fingerprintPath) }
}

$hash = Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256
if ($writeRepositoryChecksum) {
    $sumPath = Join-Path $repositoryRoot 'SHA256SUMS.txt'
    $line = $hash.Hash + '  dist/CodexSwitchTools.exe' + [Environment]::NewLine
    [IO.File]::WriteAllText($sumPath, $line, [Text.UTF8Encoding]::new($false))
}
Write-Host "Built: $OutputPath"
Write-Host "SHA256: $($hash.Hash)"
