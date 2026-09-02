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
$enginePath = (Get-Process -Id $PID).Path
$mockEnvName = 'CST_ROUTE_API_KEY_' + [guid]::NewGuid().ToString('N').ToUpperInvariant()

function ConvertTo-NativeArgument {
    param([string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Start-IsolatedProcess {
    param([string]$FilePath, [string[]]$Arguments)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = ($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $startInfo.WorkingDirectory = $workspace
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # Nothing in this test may inherit a real API credential or desktop session.
    foreach ($name in @($startInfo.EnvironmentVariables.Keys)) {
        if ($name -match '(?i)API[_]?KEY|_KEY(?:_|$)|TOKEN|SECRET|PASSWORD|CREDENTIAL|^CODEX_|^(HTTP|HTTPS|ALL)_PROXY$') {
            $startInfo.EnvironmentVariables.Remove($name)
        }
    }
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $configHome
    $startInfo.EnvironmentVariables[$mockEnvName] = 'cst-test'
    $startInfo.EnvironmentVariables['NO_PROXY'] = 'localhost,127.0.0.1,::1'
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    return $process
}

function Stop-OwnedProcess {
    param($Process)
    if ($null -eq $Process) { return }
    if (-not $Process.HasExited) {
        # Kill only the process tree created by this test, including npm/node wrappers.
        & "$env:SystemRoot\System32\taskkill.exe" /PID $Process.Id /T /F 2>$null | Out-Null
        [void]$Process.WaitForExit(5000)
    }
    $Process.Dispose()
}

function Invoke-IsolatedCommand {
    param([string]$Command, [string[]]$Arguments, [int]$TimeoutSeconds = 60)
    # A PowerShell child can invoke either an exe or the npm codex.ps1/codex.cmd shim.
    $commandJson = ConvertTo-Json -InputObject $Command -Compress
    $argumentsJson = ConvertTo-Json -InputObject @($Arguments) -Compress
    $payload = @'
$ErrorActionPreference = 'Continue'
$command = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__COMMAND__')) | ConvertFrom-Json
$commandArguments = [string[]]([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ARGUMENTS__')) | ConvertFrom-Json)
& $command @commandArguments
exit $LASTEXITCODE
'@
    $payload = $payload.Replace('__COMMAND__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($commandJson))).Replace('__ARGUMENTS__', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($argumentsJson)))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
    $process = Start-IsolatedProcess $enginePath @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { throw ('Isolated command exceeded ' + $TimeoutSeconds + ' seconds; its child process tree will be stopped.') }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.Replace('cst-test', '<DUMMY_KEY>') }
    } finally { Stop-OwnedProcess $process }
}

function Invoke-FixtureTool {
    param([string[]]$Arguments)
    return Invoke-IsolatedCommand $enginePath (@('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tool, '-ConfigPath', $configPath, '-NoPause') + $Arguments)
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
New-Item -ItemType Directory -Path $workspace | Out-Null
New-Item -ItemType Directory -Path $configHome | Out-Null
try {
    # The empty home contains no user plugins, MCP servers, auth.json, or project rules.
    # Explicitly disable external facilities in every Codex child, including parse checks.
    $fixtureConfig = @(
        'web_search = "disabled"',
        '[analytics]', 'enabled = false',
        '[feedback]', 'enabled = false',
        '[features]',
        'plugins = false', 'apps = false', 'remote_plugin = false',
        'browser_use = false', 'browser_use_external = false',
        'computer_use = false', 'image_generation = false',
        'workspace_dependencies = false', 'hooks = false', 'shell_snapshot = false',
        ''
    ) -join "`n"
    [IO.File]::WriteAllText($configPath, $fixtureConfig, [Text.UTF8Encoding]::new($false))
    $serverProcess = Start-IsolatedProcess $python.Source @($serverScript, '--ready', $readyFile, '--result', $resultFile)
    for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $readyFile -PathType Leaf); $i++) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $readyFile -PathType Leaf)) { throw 'Local mock server did not become ready.' }
    $ready = [IO.File]::ReadAllText($readyFile) | ConvertFrom-Json
    $baseUrl = 'http://127.0.0.1:' + $ready.port + '/v1'

    $configureResult = Invoke-FixtureTool @('-Action', 'ConfigureProvider', '-ProviderId', 'cst_mock', '-ProviderName', 'CST Local Mock', '-BaseUrl', $baseUrl, '-EnvKey', $mockEnvName)
    if ($configureResult.ExitCode -ne 0) { throw ('Provider configuration failed: ' + $configureResult.Output.Trim()) }
    $switchResult = Invoke-FixtureTool @('-Action', 'SetProvider', '-ProviderId', 'cst_mock', '-Model', 'cst-mock-model', '-ManageModelCatalog', '-AllowUnverifiedModel')
    if ($switchResult.ExitCode -ne 0) { throw ('Provider switch failed: ' + $switchResult.Output.Trim()) }
    $catalogMatch = [regex]::Match([IO.File]::ReadAllText($configPath), '(?m)^model_catalog_json\s*=\s*("(?:\\.|[^"\\])*")\s*$')
    if (-not $catalogMatch.Success) { throw 'Managed model_catalog_json was not written.' }
    $catalogPath = $catalogMatch.Groups[1].Value | ConvertFrom-Json
    $catalog = [IO.File]::ReadAllText($catalogPath) | ConvertFrom-Json
    if (@($catalog.models | Where-Object { $_.slug -eq 'cst-mock-model' }).Count -ne 1) { throw 'Managed catalog does not contain the fixture model.' }

    $codexResult = Invoke-IsolatedCommand $codex.Source @('exec', '--ephemeral', '--skip-git-repo-check', '--ignore-rules', '-s', 'read-only', '-C', $workspace, '--color', 'never', 'Reply with OK. Do not call tools.')
    $codexExit = $codexResult.ExitCode

    for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $resultFile -PathType Leaf); $i++) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) {
        $safe = [regex]::Replace($codexResult.Output.Trim(), '(?i)sk-[A-Za-z0-9._-]{8,}', '<REDACTED>')
        throw "Codex did not reach the local mock. Exit=$codexExit Output=$safe"
    }

    $result = [IO.File]::ReadAllText($resultFile) | ConvertFrom-Json
    if ($result.method -ne 'POST') { throw "Expected POST, got $($result.method)." }
    if ($result.path -ne '/v1/responses') { throw "Expected /v1/responses, got $($result.path)." }
    if ($result.model -ne 'cst-mock-model') { throw "Expected cst-mock-model, got $($result.model)." }
    if (-not $result.authorization_present) { throw 'Authorization header was not present.' }
    if (-not $result.authorization_matches_expected_dummy) { throw 'Authorization header did not contain the expected dummy bearer value.' }

    Write-Host '[PASS] Codex loaded the generated model catalog and routed the provider to local /v1/responses.' -ForegroundColor Green
    Write-Host '[PASS] Requested model was cst-mock-model.' -ForegroundColor Green
    Write-Host '[PASS] Authorization header matched the expected dummy bearer; its value was never recorded.' -ForegroundColor Green
    Write-Host ('Codex intentionally exited with code ' + $codexExit + ' after the mock returned HTTP 400.')
    if ($codexExit -eq 0) { throw 'Codex unexpectedly reported success after the intentional HTTP 400.' }
    Stop-OwnedProcess $serverProcess
    $serverProcess = $null

    $directReadyFile = Join-Path $testRoot 'direct-ready.json'
    $directResultFile = Join-Path $testRoot 'direct-result.json'
    $serverProcess = Start-IsolatedProcess $python.Source @($serverScript, '--ready', $directReadyFile, '--result', $directResultFile, '--success')
    for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $directReadyFile -PathType Leaf); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $directReadyFile -PathType Leaf)) { throw 'Success mock server did not become ready.' }
    $directReady = [IO.File]::ReadAllText($directReadyFile) | ConvertFrom-Json
    $directBaseUrl = 'http://127.0.0.1:' + $directReady.port + '/v1'
    $directConfigure = Invoke-FixtureTool @('-Action', 'ConfigureProvider', '-ProviderId', 'cst_mock', '-ProviderName', 'CST Local Mock', '-BaseUrl', $directBaseUrl, '-EnvKey', $mockEnvName)
    if ($directConfigure.ExitCode -ne 0) { throw ('Direct-probe provider update failed: ' + $directConfigure.Output.Trim()) }
    $directSwitch = Invoke-FixtureTool @('-Action', 'SetProvider', '-ProviderId', 'cst_mock', '-Model', 'cst-mock-model', '-ManageModelCatalog', '-AllowUnverifiedModel')
    if ($directSwitch.ExitCode -ne 0) { throw ('Direct-probe catalog update failed: ' + $directSwitch.Output.Trim()) }
    $directProbe = Invoke-FixtureTool @('-Action', 'DirectProbe', '-ConfirmDirectProbe')
    $directProbeExit = $directProbe.ExitCode
    $directProbeOutput = $directProbe.Output
    if ($directProbeExit -ne 0) { throw ('Direct Responses probe failed: ' + $directProbeOutput.Trim()) }
    if ($directProbeOutput -notmatch '\[OK\] Direct Responses API probe completed') { throw 'Direct probe did not report a validated Responses-shaped success.' }
    $directResult = [IO.File]::ReadAllText($directResultFile) | ConvertFrom-Json
    if ($directResult.path -ne '/v1/responses' -or $directResult.model -ne 'cst-mock-model' -or -not $directResult.authorization_matches_expected_dummy) {
        throw 'Direct probe request did not match expected route/model/dummy auth.'
    }
    Write-Host '[PASS] Safe direct probe validated a bounded Responses-shaped success without running agent tools.' -ForegroundColor Green
    Write-Host '[PASS] All child processes used an isolated CODEX_HOME, dummy-only credentials, disabled plugins, and bounded execution.' -ForegroundColor Green
} finally {
    Stop-OwnedProcess $serverProcess
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved).StartsWith('codex-switch-route-test-', [StringComparison]::Ordinal)) {
        if (Test-Path -LiteralPath $resolved -PathType Container) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    } else {
        throw "Refusing to clean unexpected test path: $resolved"
    }
}
