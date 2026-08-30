[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $repoRoot 'Codex-Switch-Tools.ps1'
$serverScript = Join-Path $PSScriptRoot 'mock_responses_server.py'
$python = Get-Command python -ErrorAction Stop | Select-Object -First 1
$codex = Get-Command codex -ErrorAction Stop | Select-Object -First 1
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempParent ('codex-switch-route-test-' + [guid]::NewGuid().ToString('N'))
$readyFile = Join-Path $testRoot 'ready.json'
$resultFile = Join-Path $testRoot 'result.json'
$configHome = Join-Path $testRoot '.codex'
$configPath = Join-Path $configHome 'config.toml'
$workspace = Join-Path $testRoot 'empty-workspace'
$serverProcess = $null
$oldCodexHome = $env:CODEX_HOME
$oldMockKey = $env:CST_MOCK_API_KEY

New-Item -ItemType Directory -Path $testRoot | Out-Null
New-Item -ItemType Directory -Path $workspace | Out-Null
try {
    $serverProcess = Start-Process -FilePath $python.Source -ArgumentList @($serverScript, '--ready', $readyFile, '--result', $resultFile) -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $readyFile -PathType Leaf); $i++) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $readyFile -PathType Leaf)) { throw 'Local mock server did not become ready.' }
    $ready = [IO.File]::ReadAllText($readyFile) | ConvertFrom-Json
    $baseUrl = 'http://127.0.0.1:' + $ready.port + '/v1'

    $enginePath = (Get-Process -Id $PID).Path
    $configureOutput = & $enginePath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool -Action ConfigureProvider -ConfigPath $configPath -ProviderId cst_mock -ProviderName 'CST Local Mock' -BaseUrl $baseUrl -EnvKey CST_MOCK_API_KEY -NoPause 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('Provider configuration failed: ' + (($configureOutput | Out-String).Trim())) }
    $switchOutput = & $enginePath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool -Action SetProvider -ConfigPath $configPath -ProviderId cst_mock -Model cst-mock-model -NoPause 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('Provider switch failed: ' + (($switchOutput | Out-String).Trim())) }

    $env:CODEX_HOME = $configHome
    $env:CST_MOCK_API_KEY = 'cst-test'
    $oldErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $codexOutput = & $codex.Source exec --ephemeral --skip-git-repo-check --ignore-rules -s read-only -C $workspace --color never 'Reply with OK. Do not call tools.' 2>&1
        $codexExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorAction
    }

    for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $resultFile -PathType Leaf); $i++) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
        $safe = [regex]::Replace((($codexOutput | Out-String).Trim()), '(?i)sk-[A-Za-z0-9._-]{8,}', '<REDACTED>')
        throw "Codex did not reach the local mock. Exit=$codexExit Output=$safe"
    }

    $result = [IO.File]::ReadAllText($resultFile) | ConvertFrom-Json
    if ($result.method -ne 'POST') { throw "Expected POST, got $($result.method)." }
    if ($result.path -ne '/v1/responses') { throw "Expected /v1/responses, got $($result.path)." }
    if ($result.model -ne 'cst-mock-model') { throw "Expected cst-mock-model, got $($result.model)." }
    if (-not $result.authorization_present) { throw 'Authorization header was not present.' }
    if (-not $result.authorization_matches_expected_dummy) { throw 'Authorization header did not contain the expected dummy bearer value.' }

    Write-Host '[PASS] Codex routed the generated provider config to local /v1/responses.' -ForegroundColor Green
    Write-Host '[PASS] Requested model was cst-mock-model.' -ForegroundColor Green
    Write-Host '[PASS] Authorization header matched the expected dummy bearer; its value was never recorded.' -ForegroundColor Green
    Write-Host ('Codex intentionally exited with code ' + $codexExit + ' after the mock returned HTTP 400.')

    $directReadyFile = Join-Path $testRoot 'direct-ready.json'
    $directResultFile = Join-Path $testRoot 'direct-result.json'
    $serverProcess = Start-Process -FilePath $python.Source -ArgumentList @($serverScript, '--ready', $directReadyFile, '--result', $directResultFile, '--success') -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $directReadyFile -PathType Leaf); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $directReadyFile -PathType Leaf)) { throw 'Success mock server did not become ready.' }
    $directReady = [IO.File]::ReadAllText($directReadyFile) | ConvertFrom-Json
    $directBaseUrl = 'http://127.0.0.1:' + $directReady.port + '/v1'
    $directConfigure = & $enginePath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool -Action ConfigureProvider -ConfigPath $configPath -ProviderId cst_mock -ProviderName 'CST Local Mock' -BaseUrl $directBaseUrl -EnvKey CST_MOCK_API_KEY -NoPause 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('Direct-probe provider update failed: ' + (($directConfigure | Out-String).Trim())) }
    . $tool -ConfigPath $configPath -NoPause
    $directProbeSucceeded = $true
    $directProbeOutput = ''
    try { $directProbeOutput = (& { Invoke-LiveProbe -Confirmed $true } *>&1 | Out-String) }
    catch { $directProbeSucceeded = $false; $directProbeOutput = ($_ | Out-String) }
    if (-not $directProbeSucceeded) { throw ('Direct Responses probe failed: ' + $directProbeOutput.Trim()) }
    if ($directProbeOutput -notmatch '\[OK\] Direct Responses API probe completed') { throw 'Direct probe did not report a validated Responses-shaped success.' }
    $directResult = [IO.File]::ReadAllText($directResultFile) | ConvertFrom-Json
    if ($directResult.path -ne '/v1/responses' -or $directResult.model -ne 'cst-mock-model' -or -not $directResult.authorization_matches_expected_dummy) {
        throw 'Direct probe request did not match expected route/model/dummy auth.'
    }
    Write-Host '[PASS] Safe direct probe validated a bounded Responses-shaped success without running agent tools.' -ForegroundColor Green
} finally {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue }
    if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue } else { $env:CODEX_HOME = $oldCodexHome }
    if ($null -eq $oldMockKey) { Remove-Item Env:CST_MOCK_API_KEY -ErrorAction SilentlyContinue } else { $env:CST_MOCK_API_KEY = $oldMockKey }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved).StartsWith('codex-switch-route-test-', [StringComparison]::Ordinal)) {
        if (Test-Path -LiteralPath $resolved -PathType Container) { [IO.Directory]::Delete($resolved, $true) }
    } else {
        throw "Refusing to clean unexpected test path: $resolved"
    }
}
