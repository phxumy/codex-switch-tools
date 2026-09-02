[CmdletBinding()]
param(
    [string]$CodexPath,
    [string]$ExpectedCodexVersion,
    [switch]$RequireCodex,
    [switch]$OmitInstructions,
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Optional, read-only Codex protocol integration. This never sends thread/start,
# turn/start, or any other agent/model inference request.
function Resolve-CodexExecutable {
    if ($CodexPath) {
        $resolved = [IO.Path]::GetFullPath($CodexPath)
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw 'Specified Codex executable does not exist.' }
        if ([IO.Path]::GetExtension($resolved) -ine '.exe') { throw 'CodexPath must name the native codex.exe, not a shell wrapper.' }
        return $resolved
    }
    $commands = @(Get-Command codex -All -ErrorAction SilentlyContinue)
    # npm installs expose wrappers on PATH; resolve only inside that installation.
    foreach ($command in $commands) {
        if ([IO.Path]::GetExtension($command.Source) -ieq '.exe') { return $command.Source }
        $packageRoot = Join-Path (Split-Path -Parent $command.Source) 'node_modules\@openai'
        $architecture = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
        $platformPackage = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'codex-win32-arm64' } else { 'codex-win32-x64' }
        # npm may nest optional dependencies or hoist them beside @openai/codex.
        foreach ($package in @((Join-Path $packageRoot 'codex'), (Join-Path $packageRoot $platformPackage))) {
            if (-not (Test-Path -LiteralPath $package -PathType Container)) { continue }
            $candidates = @(Get-ChildItem -LiteralPath $package -Filter codex.exe -File -Recurse)
            $match = @($candidates | Where-Object { $_.FullName.Contains($architecture) } | Select-Object -First 1)
            if ($match.Count -eq 1) { return $match[0].FullName }
        }
    }
    return $null
}

$executable = Resolve-CodexExecutable
if (-not $executable) {
    if ($RequireCodex) { throw 'Required native codex.exe is not installed/resolvable.' }
    Write-Host '[SKIP] Optional catalog integration: native codex.exe is not installed/resolvable. No real API was contacted.'
    return
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $repoRoot 'Codex-Switch-Tools.ps1'
$engine = (Get-Process -Id $PID).Path
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempParent ('codex-switch-catalog-integration-' + [guid]::NewGuid().ToString('N'))
$configHome = Join-Path $testRoot 'isolated-codex'
$configPath = Join-Path $configHome 'config.toml'
$workspace = Join-Path $testRoot 'empty-workspace'
$dummyEnvName = 'CST_CATALOG_INTEGRATION_KEY'
$dummyKey = 'catalog-integration-dummy'
$process = $null
$stdinWriter = $null
$stderrTask = $null
$encoding = [Text.UTF8Encoding]::new($false)

function Invoke-IsolatedTool {
    param([string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool -ConfigPath $configPath -SkipCodexValidation -NoPause @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($exitCode -ne 0) { throw ('Fixture generation failed: ' + ($output | Out-String).Trim()) }
}

function Write-Rpc {
    param($Message)
    $allowedMethods = @('initialize', 'initialized', 'model/list')
    if ($Message.method -notin $allowedMethods) { throw 'Inference and thread RPC methods are prohibited in this test.' }
    $stdinWriter.WriteLine(($Message | ConvertTo-Json -Compress -Depth 12))
    $stdinWriter.Flush()
}

function Read-RpcResponse {
    param([int]$Id)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 20) {
        $read = $process.StandardOutput.ReadLineAsync()
        $remaining = [Math]::Max(1, [int](20000 - $timer.ElapsedMilliseconds))
        if (-not $read.Wait($remaining)) { throw ('Timed out waiting for app-server response ' + $Id) }
        $line = $read.Result
        if ($null -eq $line) { throw ('app-server exited before response ' + $Id) }
        if (-not $line.Trim()) { continue }
        try { $message = $line | ConvertFrom-Json } catch { continue }
        if ($null -ne $message.PSObject.Properties['id'] -and $message.id -eq $Id) {
            if ($null -ne $message.PSObject.Properties['error']) {
                throw ('app-server RPC error: ' + ($message.error | ConvertTo-Json -Compress -Depth 8))
            }
            return $message.result
        }
    }
    throw ('Timed out waiting for app-server response ' + $Id)
}

New-Item -ItemType Directory -Path $configHome, $workspace | Out-Null
try {
    $version = ((& $executable --version | Out-String).Trim())
    if ($ExpectedCodexVersion -and $version -cne ('codex-cli ' + $ExpectedCodexVersion)) {
        throw ('Expected codex-cli ' + $ExpectedCodexVersion + '; resolved ' + $version)
    }
    Write-Host ('Testing catalog protocol with ' + $version)
    # Offline generation uses the official endpoint only to select bundled metadata.
    # SkipCodexValidation prevents launching Codex until the URL is made loopback.
    Invoke-IsolatedTool @('-Action', 'ConfigureProvider', '-ProviderId', 'cst_catalog_fixture', '-ProviderName', 'Catalog fixture', '-BaseUrl', 'https://api.deepseek.com', '-EnvKey', $dummyEnvName)
    Invoke-IsolatedTool @('-Action', 'SetProvider', '-ProviderId', 'cst_catalog_fixture', '-Model', 'deepseek-v4-pro', '-ManageModelCatalog')
    Invoke-IsolatedTool @('-Action', 'ConfigureProvider', '-ProviderId', 'cst_catalog_fixture', '-ProviderName', 'Catalog fixture', '-BaseUrl', 'http://127.0.0.1:9/v1', '-EnvKey', $dummyEnvName)
    $configText = [IO.File]::ReadAllText($configPath)
    if ($configText -match 'https://api\.deepseek\.com') { throw 'Remote provider endpoint still present in the app-server fixture.' }
    if ($configText -notmatch 'http://127\.0\.0\.1:9/v1') { throw 'Loopback provider route is missing.' }
    if ($OmitInstructions) {
        $catalogMatch = [regex]::Match($configText, '(?m)^model_catalog_json\s*=\s*("(?:\\.|[^"\\])*")\s*$')
        if (-not $catalogMatch.Success) { throw 'Generated fixture has no catalog path.' }
        $catalogPath = $catalogMatch.Groups[1].Value | ConvertFrom-Json
        $catalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
        foreach ($entry in @($catalog.models)) {
            $entry.PSObject.Properties.Remove('base_instructions')
            $entry.PSObject.Properties.Remove('model_messages')
        }
        # Deliberately change only a disposable generated fixture to test omission.
        [IO.File]::WriteAllText($catalogPath, ($catalog | ConvertTo-Json -Depth 15), $encoding)
        Write-Host 'Checking whether catalog instructions may be omitted.'
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $executable
    $startInfo.Arguments = 'app-server --stdio -c features.plugins=false -c features.apps=false'
    $startInfo.WorkingDirectory = $workspace
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $encoding
    $startInfo.StandardErrorEncoding = $encoding
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $configHome
    $startInfo.EnvironmentVariables[$dummyEnvName] = $dummyKey
    $startInfo.EnvironmentVariables.Remove('OPENAI_API_KEY')
    $startInfo.EnvironmentVariables['OPENAI_BASE_URL'] = 'http://127.0.0.1:9/v1'
    # Isolate incidental plugin/catalog startup traffic as well as model routing.
    foreach ($proxyName in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
        $startInfo.EnvironmentVariables[$proxyName] = 'http://127.0.0.1:9'
    }
    $startInfo.EnvironmentVariables['NO_PROXY'] = '127.0.0.1,localhost'
    $startInfo.EnvironmentVariables['no_proxy'] = '127.0.0.1,localhost'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    # .NET Framework chooses redirected stdin encoding from Console.InputEncoding.
    # Set it only while starting this child; no system-wide encoding is changed.
    $previousInputEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = $encoding
        [void]$process.Start()
    } finally { [Console]::InputEncoding = $previousInputEncoding }
    # .NET Framework ProcessStartInfo has no StandardInputEncoding property.
    # A separate UTF-8 writer avoids the default BOM invalidating the first RPC.
    $stdinWriter = [IO.StreamWriter]::new($process.StandardInput.BaseStream, $encoding, 1024, $true)
    $stderrTask = $process.StandardError.ReadToEndAsync()

    Write-Rpc @{ id = 1; method = 'initialize'; params = @{ clientInfo = @{ name = 'cst_catalog_integration'; title = 'Catalog integration'; version = '1.2.0' }; capabilities = @{ experimentalApi = $true } } }
    $null = Read-RpcResponse 1
    Write-Rpc @{ method = 'initialized'; params = @{} }
    Write-Rpc @{ id = 2; method = 'model/list'; params = @{ limit = 100; includeHidden = $false } }
    $result = Read-RpcResponse 2
    $models = @($result.data)
    $expected = @('deepseek-v4-pro', 'deepseek-v4-flash', 'deepseek-v4-flash-vision-exp')
    $ids = @($models | ForEach-Object { $_.id })
    foreach ($id in $expected) {
        if ($ids -cnotcontains $id) { throw ('Native model/list missing ' + $id + '; returned: ' + ($ids -join ', ')) }
    }
    if ($models.Count -ne 3) { throw ('Expected only three provider models; returned: ' + ($ids -join ', ')) }
    if (@($ids | Where-Object { $_ -match '^(gpt-|codex-|o[134](?:-|$))' }).Count -gt 0) { throw 'Native model/list mixed OpenAI models into the provider catalog.' }
    foreach ($model in $models) {
        if ($null -eq $model.PSObject.Properties['inputModalities']) { throw ('Native model/list lacks inputModalities for ' + $model.id) }
        $modalities = @($model.inputModalities)
        $shouldHaveImages = $model.id -ceq 'deepseek-v4-flash-vision-exp'
        if (($modalities -ccontains 'image') -ne $shouldHaveImages) { throw ('Incorrect native image modality: ' + $model.id) }
        if ($modalities -cnotcontains 'text') { throw ('Native model lacks text modality: ' + $model.id) }
        Write-Host ('[PASS] Native model/list: ' + $model.id + '; inputModalities=' + ($modalities -join ',')) -ForegroundColor Green
    }
    if ($null -ne $result.nextCursor) { throw 'Unexpected native pagination: this three-model fixture should fit on one page.' }
    Write-Host '[PASS] Generated catalog parsed by Codex app-server; no GPT entries; only initialize/initialized/model/list were sent.' -ForegroundColor Green
} catch {
    if ($null -ne $process -and -not $process.HasExited) { $process.Kill(); $null = $process.WaitForExit(3000) }
    if ($null -ne $stderrTask -and $stderrTask.Wait(3000)) {
        $safeError = $stderrTask.Result.Replace($dummyKey, '<REDACTED>')
        if ($safeError.Trim()) { Write-Host ('app-server stderr: ' + $safeError.Trim()) }
    }
    throw
} finally {
    if ($null -ne $process) {
        if ($null -ne $stdinWriter) { $stdinWriter.Dispose() }
        if (-not $process.HasExited) {
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(3000)) { $process.Kill(); $null = $process.WaitForExit(3000) }
        }
        $process.Dispose()
    }
    if ($KeepTemp) {
        Write-Host ('Kept isolated fixture: ' + $testRoot)
    } else {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if ($resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved).StartsWith('codex-switch-catalog-integration-', [StringComparison]::Ordinal)) {
            if (Test-Path -LiteralPath $resolved -PathType Container) { [IO.Directory]::Delete($resolved, $true) }
        } else { throw ('Refusing cleanup outside isolated test directory: ' + $resolved) }
    }
}
