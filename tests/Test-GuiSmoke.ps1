[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $repoRoot 'build-gui.ps1'
$sourcePath = Join-Path $repoRoot 'src\CodexSwitchTools.Gui.cs'
$corePath = Join-Path $repoRoot 'Codex-Switch-Tools.ps1'
$iconPath = Join-Path $repoRoot 'assets\CodexSwitchTools.ico'
$committedExe = Join-Path $repoRoot 'dist\CodexSwitchTools.exe'
$checksumPath = Join-Path $repoRoot 'SHA256SUMS.txt'
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempParent ('codex-switch-gui-tests-' + [guid]::NewGuid().ToString('N'))
$specialDirectory = Join-Path $testRoot ('GUI 空格 & 括号 (' + [char]0x6d4b + [char]0x8bd5 + ')')
$outputPath = Join-Path $specialDirectory 'CodexSwitchTools.exe'
$configDirectory = Join-Path $specialDirectory '.codex'
$configPath = Join-Path $configDirectory 'config.toml'

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexSwitchToolsNativeIconTest
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern uint PrivateExtractIcons(string fileName, int iconIndex, int width, int height, IntPtr[] iconHandles, uint[] iconIds, uint iconCount, uint flags);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr iconHandle);
}
'@

function Test-Utf8Bom {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    return $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
}

function Invoke-SelfTest {
    param([string]$ExePath, [string]$FixturePath, [string]$SourceHash, [string]$CoreHash, [switch]$ForceWindowsPowerShell)
    $oldPath = $env:PATH
    $oldForce = $env:CST_GUI_FORCE_WINDOWS_POWERSHELL
    try {
        if ($ForceWindowsPowerShell) {
            $env:PATH = Join-Path $env:SystemRoot 'System32'
            $env:CST_GUI_FORCE_WINDOWS_POWERSHELL = '1'
        }
        $quotedFixture = '"' + $FixturePath.Replace('"', '\"') + '"'
        $process = Start-Process -FilePath $ExePath -ArgumentList @('--self-test', $quotedFixture, $SourceHash, $CoreHash) -PassThru -WindowStyle Hidden
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill() } catch { }
            try { $process.WaitForExit(5000) } catch { }
            throw 'GUI self-test timed out after 30 seconds.'
        }
        return $process.ExitCode
    } finally {
        $env:PATH = $oldPath
        if ($null -eq $oldForce) { Remove-Item Env:CST_GUI_FORCE_WINDOWS_POWERSHELL -ErrorAction SilentlyContinue }
        else { $env:CST_GUI_FORCE_WINDOWS_POWERSHELL = $oldForce }
    }
}

function Assert-ExecutableIcon {
    param([string]$ExePath, [string]$ExpectedIconPath)
    [IntPtr[]]$handles = @([IntPtr]::Zero)
    [uint32[]]$iconIds = @(0)
    $count = [CodexSwitchToolsNativeIconTest]::PrivateExtractIcons($ExePath, 0, 32, 32, $handles, $iconIds, 1, 0)
    if ($count -ne 1 -or $handles[0] -eq [IntPtr]::Zero) { throw "Executable icon is missing: $ExePath" }
    $actualIcon = $null
    $expectedIcon = $null
    $actualBitmap = $null
    $expectedBitmap = $null
    try {
        $view = [Drawing.Icon]::FromHandle($handles[0])
        $actualIcon = [Drawing.Icon]$view.Clone()
        $expectedIcon = [Drawing.Icon]::new($ExpectedIconPath, 32, 32)
        $actualBitmap = $actualIcon.ToBitmap()
        $expectedBitmap = $expectedIcon.ToBitmap()
        $differentPixels = 0
        for ($y = 0; $y -lt 32; $y++) {
            for ($x = 0; $x -lt 32; $x++) {
                if ($actualBitmap.GetPixel($x, $y).ToArgb() -ne $expectedBitmap.GetPixel($x, $y).ToArgb()) { $differentPixels++ }
            }
        }
        if ($differentPixels -ne 0) { throw "Executable does not contain the expected custom icon ($differentPixels pixels differ): $ExePath" }
    } finally {
        if ($null -ne $actualBitmap) { $actualBitmap.Dispose() }
        if ($null -ne $expectedBitmap) { $expectedBitmap.Dispose() }
        if ($null -ne $actualIcon) { $actualIcon.Dispose() }
        if ($null -ne $expectedIcon) { $expectedIcon.Dispose() }
        [void][CodexSwitchToolsNativeIconTest]::DestroyIcon($handles[0])
    }
}

New-Item -ItemType Directory -Path $specialDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
try {
    if (-not (Test-Utf8Bom -Path $sourcePath)) { throw 'GUI C# source must be UTF-8 BOM so the .NET Framework compiler reads Chinese reliably.' }
    if (-not (Test-Utf8Bom -Path $buildScript)) { throw 'Chinese build-gui.ps1 must be UTF-8 BOM for Windows PowerShell 5.1.' }
    if (-not (Test-Utf8Bom -Path $corePath)) { throw 'Core PowerShell script contains Chinese shortcut text and must be UTF-8 BOM.' }
    if (-not (Test-Path -LiteralPath $iconPath -PathType Leaf)) { throw 'Application icon is missing.' }
    $iconHeader = [IO.File]::ReadAllBytes($iconPath)
    if ($iconHeader.Length -lt 6 -or $iconHeader[0] -ne 0 -or $iconHeader[1] -ne 0 -or $iconHeader[2] -ne 1 -or $iconHeader[3] -ne 0) { throw 'Application icon is not a valid ICO file.' }

    $fixture = @(
        'model = "gpt-5.6-sol"',
        'model_provider = "openai"',
        '',
        '[features]',
        'web_search = true',
        ''
    ) -join "`r`n"
    [IO.File]::WriteAllText($configPath, $fixture, [Text.UTF8Encoding]::new($false))
    $beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash
    $coreHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $corePath).Hash

    if (-not (Test-Path -LiteralPath $committedExe -PathType Leaf)) { throw 'Committed GUI executable is missing.' }
    $expectedHash = ([IO.File]::ReadAllText($checksumPath).Trim() -split '\s+')[0]
    $committedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $committedExe).Hash
    if ($expectedHash -ne $committedHash) { throw 'SHA256SUMS.txt does not match the committed GUI executable.' }
    Assert-ExecutableIcon -ExePath $committedExe -ExpectedIconPath $iconPath
    $committedExit = Invoke-SelfTest -ExePath $committedExe -FixturePath $configPath -SourceHash $sourceHash -CoreHash $coreHash
    if ($committedExit -ne 0) { throw "Committed GUI executable self-test failed. Exit=$committedExit" }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $buildScript -OutputPath $outputPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw 'GUI build failed.' }
    Assert-ExecutableIcon -ExePath $outputPath -ExpectedIconPath $iconPath

    $normalExit = Invoke-SelfTest -ExePath $outputPath -FixturePath $configPath -SourceHash $sourceHash -CoreHash $coreHash
    if ($normalExit -ne 0) { throw "GUI self-test failed with preferred PowerShell engine. Exit=$normalExit" }

    $ps5Exit = Invoke-SelfTest -ExePath $outputPath -FixturePath $configPath -SourceHash $sourceHash -CoreHash $coreHash -ForceWindowsPowerShell
    if ($ps5Exit -ne 0) { throw "GUI self-test failed with Windows PowerShell fallback. Exit=$ps5Exit" }

    $afterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $configPath).Hash
    if ($beforeHash -ne $afterHash) { throw 'GUI self-test changed its isolated config.' }

    $version = (Get-Item -LiteralPath $outputPath).VersionInfo.FileVersion
    if ($version -notmatch '^1\.1\.1\.0') { throw "Unexpected GUI file version: $version" }

    Write-Host '[PASS] GUI compiled and created four Chinese tabs without showing a window.' -ForegroundColor Green
    Write-Host '[PASS] Committed GUI executable matched SHA256SUMS and its embedded core self-test passed.' -ForegroundColor Green
    Write-Host '[PASS] Embedded core worked through preferred PowerShell and Windows PowerShell 5.1 fallback.' -ForegroundColor Green
    Write-Host '[PASS] Four expected Chinese tab captions and stale Process-key synchronization were self-tested.' -ForegroundColor Green
    Write-Host '[PASS] The custom icon is embedded in both the executable and the WinForms window.' -ForegroundColor Green
    Write-Host '[PASS] GUI self-test cleaned its random extracted-core directory.' -ForegroundColor Green
    Write-Host '[PASS] GUI self-test preserved the isolated config byte-for-byte.' -ForegroundColor Green
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $parent = [IO.Path]::GetFullPath($tempParent).TrimEnd([char[]]@('\', '/'))
    $resolvedParent = [IO.Path]::GetFullPath((Split-Path -Parent $resolved)).TrimEnd([char[]]@('\', '/'))
    if ($resolvedParent -ne $parent -or -not (Split-Path -Leaf $resolved).StartsWith('codex-switch-gui-tests-', [StringComparison]::Ordinal)) {
        throw "Refusing to clean unexpected GUI test path: $resolved"
    }
    if (Test-Path -LiteralPath $resolved -PathType Container) { [IO.Directory]::Delete($resolved, $true) }
}
