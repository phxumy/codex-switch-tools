[CmdletBinding()]
param(
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $repoRoot 'Codex-Switch-Tools.ps1'
$engine = (Get-Process -Id $PID).Path
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempParent ('codex-switch-tools-tests-' + [guid]::NewGuid().ToString('N'))
$script:Passed = 0
$script:Failed = 0
$script:FailureMessages = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $script:Failed++
        [void]$script:FailureMessages.Add($Message)
        Write-Host ('[FAIL] ' + $Message) -ForegroundColor Red
        if ($env:GITHUB_ACTIONS -eq 'true') {
            $escaped = $Message.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
            Write-Output ('::error file=tests/Run-Tests.ps1,title=Compatibility test failed::' + $escaped)
        }
    } else {
        $script:Passed++
        Write-Host ('[PASS] ' + $Message) -ForegroundColor Green
    }
}

function Invoke-Tool {
    param([string[]]$Arguments, [switch]$ForceValidationFailure, [switch]$ForceValidationException, [string]$CodexHome)
    $oldFailureFlag = $env:CODEX_SWITCH_TEST_FAIL_VALIDATION
    $oldThrowFlag = $env:CODEX_SWITCH_TEST_THROW_VALIDATION
    $oldCodexHome = $env:CODEX_HOME
    try {
        if ($ForceValidationFailure) { $env:CODEX_SWITCH_TEST_FAIL_VALIDATION = '1' }
        else { Remove-Item Env:CODEX_SWITCH_TEST_FAIL_VALIDATION -ErrorAction SilentlyContinue }
        if ($ForceValidationException) { $env:CODEX_SWITCH_TEST_THROW_VALIDATION = '1' }
        else { Remove-Item Env:CODEX_SWITCH_TEST_THROW_VALIDATION -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrWhiteSpace($CodexHome)) { $env:CODEX_HOME = $CodexHome }
        $output = & $engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($output | Out-String).Trim()) }
    } finally {
        if ($null -eq $oldFailureFlag) { Remove-Item Env:CODEX_SWITCH_TEST_FAIL_VALIDATION -ErrorAction SilentlyContinue }
        else { $env:CODEX_SWITCH_TEST_FAIL_VALIDATION = $oldFailureFlag }
        if ($null -eq $oldThrowFlag) { Remove-Item Env:CODEX_SWITCH_TEST_THROW_VALIDATION -ErrorAction SilentlyContinue }
        else { $env:CODEX_SWITCH_TEST_THROW_VALIDATION = $oldThrowFlag }
        if ($null -eq $oldCodexHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $oldCodexHome }
    }
}

function Read-Utf8Text {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    Write-Host ('Engine: ' + $engine)
    Write-Host ('Version: ' + $PSVersionTable.PSVersion)
    Write-Host ('Temp  : ' + $testRoot)

    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($tool, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'Main script parses in the current PowerShell engine'

    $specialLeaf = 'config space & unicode-' + [char]0x6d4b + [char]0x8bd5 + ' (fixture)'
    $specialHome = Join-Path $testRoot $specialLeaf
    $freshConfig = Join-Path $specialHome 'config.toml'
    $configure = Invoke-Tool -Arguments @(
        '-Action', 'ConfigureProvider', '-ConfigPath', $freshConfig,
        '-ProviderId', 'cst_test', '-ProviderName', 'Fixture Provider',
        '-BaseUrl', 'http://127.0.0.1:56789/v1', '-EnvKey', 'CST_FIXTURE_API_KEY',
        '-SkipCodexValidation', '-NoPause'
    )
    Assert-True ($configure.ExitCode -eq 0) 'Fresh install can create config and a generic provider in a special-character path'
    Assert-True (Test-Path -LiteralPath $freshConfig -PathType Leaf) 'Fresh config.toml was created'
    $freshText = Read-Utf8Text $freshConfig
    Assert-True ($freshText -match '(?m)^\[model_providers\.cst_test\]$') 'Provider table was created'
    Assert-True ($freshText -match '(?m)^wire_api = "responses"$') 'Provider uses Responses API'
    Assert-True ($freshText -match '(?m)^env_key = "CST_FIXTURE_API_KEY"$') 'Provider references an environment variable'
    Assert-True ($freshText -notmatch '(?i)experimental_bearer_token') 'Fresh provider does not store an inline token'

    $codexHomeFixture = Join-Path $testRoot ('CODEX_HOME space ' + [char]0x8def + [char]0x5f84)
    $homeConfigure = Invoke-Tool -CodexHome $codexHomeFixture -Arguments @('-Action', 'ConfigureProvider', '-ProviderId', 'cst_home', '-ProviderName', 'Home Provider', '-BaseUrl', 'http://127.0.0.1:56789/v1', '-EnvKey', 'CST_HOME_TEST_KEY', '-SkipCodexValidation', '-NoPause')
    Assert-True ($homeConfigure.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $codexHomeFixture 'config.toml'))) 'CODEX_HOME resolution works with spaces and Unicode without -ConfigPath'

    $switch = Invoke-Tool -Arguments @(
        '-Action', 'SetProvider', '-ConfigPath', $freshConfig,
        '-ProviderId', 'cst_test', '-Model', 'fixture-model-v1', '-ReasoningEffort', 'high',
        '-SkipCodexValidation', '-NoPause'
    )
    Assert-True ($switch.ExitCode -eq 0) 'Custom provider/model switch succeeds'
    $freshText = Read-Utf8Text $freshConfig
    $rootPrefix = $freshText.Substring(0, $freshText.IndexOf('[model_providers.cst_test]'))
    Assert-True ($rootPrefix -match '(?m)^model_provider = "cst_test"$') 'model_provider is written at TOML root'
    Assert-True ($rootPrefix -match '(?m)^model = "fixture-model-v1"$') 'model is written at TOML root'
    Assert-True ($rootPrefix -match '(?m)^model_reasoning_effort = "high"$') 'reasoning effort is written at TOML root'

    $status = Invoke-Tool -Arguments @('-Action', 'Status', '-ConfigPath', $freshConfig, '-Json', '-SkipCodexValidation', '-NoPause')
    $statusObject = $status.Output | ConvertFrom-Json
    Assert-True ($status.ExitCode -eq 0 -and $statusObject.ExpectedProvider -eq 'cst_test') 'JSON diagnostics reports expected provider without a live request'
    Assert-True ($statusObject.RequestedModel -eq 'fixture-model-v1') 'JSON diagnostics reports requested model'

    $bat = Join-Path $repoRoot 'Codex-Switch-Tools.bat'
    $batOutput = & $bat -Action Status -ConfigPath $freshConfig -Json -SkipCodexValidation -NoPause 2>&1
    $batExit = $LASTEXITCODE
    $batStatus = (($batOutput | Out-String).Trim()) | ConvertFrom-Json
    Assert-True ($batExit -eq 0 -and $batStatus.ExpectedProvider -eq 'cst_test') 'BAT launcher forwards quoted paths and noninteractive arguments'

    if ($env:CST_RUN_CODEX_INTEGRATION -eq '1') {
        if ($null -eq (Get-Command codex -ErrorAction SilentlyContinue)) { throw 'CST_RUN_CODEX_INTEGRATION=1 but the codex command is not installed.' }
        $realValidation = Invoke-Tool -Arguments @('-Action', 'Validate', '-ConfigPath', $freshConfig, '-NoPause')
        Assert-True ($realValidation.ExitCode -eq 0) 'Installed Codex performs a real bounded offline parse of an isolated valid config'
        $malformedHome = Join-Path $testRoot 'malformed-config'
        New-Item -ItemType Directory -Path $malformedHome | Out-Null
        $malformedConfig = Join-Path $malformedHome 'config.toml'
        [IO.File]::WriteAllText($malformedConfig, 'broken = [', [Text.UTF8Encoding]::new($false))
        $malformedValidation = Invoke-Tool -Arguments @('-Action', 'Validate', '-ConfigPath', $malformedConfig, '-NoPause')
        Assert-True ($malformedValidation.ExitCode -ne 0) 'Installed Codex rejects an isolated malformed TOML config'
    } else {
        Write-Host '[SKIP] Real Codex parser checks require CST_RUN_CODEX_INTEGRATION=1; isolated unit tests continue.' -ForegroundColor Yellow
    }

    $setContext = Invoke-Tool -Arguments @(
        '-Action', 'SetContext', '-ConfigPath', $freshConfig,
        '-ContextWindow', '872000', '-AutoCompactLimit', '800000',
        '-SkipCodexValidation', '-NoPause'
    )
    Assert-True ($setContext.ExitCode -eq 0) 'Managed long context can be enabled'
    $freshText = Read-Utf8Text $freshConfig
    Assert-True ($freshText -match '(?m)^# CST_CONTEXT_V1 ') 'Context baseline marker was added'
    Assert-True ($freshText -match '(?m)^model_context_window = 872000$') 'Context window override was written'
    Assert-True ($freshText -match '(?m)^model_auto_compact_token_limit = 800000$') 'Auto-compact override was written'

    $resetContext = Invoke-Tool -Arguments @('-Action', 'ResetContext', '-ConfigPath', $freshConfig, '-SkipCodexValidation', '-NoPause')
    Assert-True ($resetContext.ExitCode -eq 0) 'Managed context can be reset'
    $freshText = Read-Utf8Text $freshConfig
    Assert-True ($freshText -notmatch 'CST_CONTEXT_V1|model_context_window|model_auto_compact_token_limit') 'Reset removed overrides that were absent before enable'

    $openAI = Invoke-Tool -Arguments @('-Action', 'UseOpenAI', '-ConfigPath', $freshConfig, '-SkipCodexValidation', '-NoPause')
    Assert-True ($openAI.ExitCode -eq 0) 'Switch back to official OpenAI succeeds'
    $freshText = Read-Utf8Text $freshConfig
    Assert-True ($freshText -match '(?m)^model_provider = "openai"$') 'Official provider is selected'
    Assert-True ($freshText -notmatch '(?m)^model\s*=|^model_reasoning_effort\s*=') 'Official switch removes custom model and effort overrides'
    Assert-True ($freshText -match '(?m)^\[model_providers\.cst_test\]$') 'Official switch preserves custom provider definitions'
    $switchBack = Invoke-Tool -Arguments @('-Action', 'SetProvider', '-ConfigPath', $freshConfig, '-ProviderId', 'cst_test', '-Model', 'fixture-model-v1', '-SkipCodexValidation', '-NoPause')
    $switchBackText = Read-Utf8Text $freshConfig
    Assert-True ($switchBack.ExitCode -eq 0 -and $switchBackText -match '(?m)^model_provider = "cst_test"$') 'Provider to OpenAI to provider round trip succeeds'

    $richHome = Join-Path $testRoot 'rich-fixture'
    New-Item -ItemType Directory -Path $richHome | Out-Null
    $richConfig = Join-Path $richHome 'config.toml'
    $richText = @(
        '# preserve this header',
        'model_context_window = 200_000 # keep-window-comment',
        'model_auto_compact_token_limit = 180_000 # keep-compact-comment',
        'items = [',
        '  "[not.a.table]",',
        ']',
        'message = """',
        '[also.not.a.table]',
        '# CST_CONTEXT_V1 previous_window=123 previous_compact=100',
        '"""',
        '',
        '[features]',
        'web_search = true',
        ''
    ) -join "`r`n"
    [IO.File]::WriteAllText($richConfig, $richText, [Text.UTF8Encoding]::new($true))
    $richOriginalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $richConfig).Hash
    $richEnable = Invoke-Tool -Arguments @('-Action', 'SetContext', '-ConfigPath', $richConfig, '-ContextWindow', '872000', '-AutoCompactLimit', '800000', '-SkipCodexValidation', '-NoPause')
    Assert-True ($richEnable.ExitCode -eq 0) 'Lexical editor handles arrays and multiline strings containing bracket-like lines'
    $richReset = Invoke-Tool -Arguments @('-Action', 'ResetContext', '-ConfigPath', $richConfig, '-SkipCodexValidation', '-NoPause')
    $richFinalHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $richConfig).Hash
    Assert-True ($richReset.ExitCode -eq 0 -and $richFinalHash -eq $richOriginalHash) 'Context enable/reset round trip is byte-identical, including BOM, CRLF and comments'
    $unmanagedReset = Invoke-Tool -Arguments @('-Action', 'ResetContext', '-ConfigPath', $richConfig, '-SkipCodexValidation', '-NoPause')
    $richAfterUnmanagedReset = (Get-FileHash -Algorithm SHA256 -LiteralPath $richConfig).Hash
    Assert-True ($unmanagedReset.ExitCode -ne 0 -and $richAfterUnmanagedReset -eq $richOriginalHash) 'ResetContext refuses to delete unmanaged context overrides'

    $beforeInvalid = (Get-FileHash -Algorithm SHA256 -LiteralPath $freshConfig).Hash
    $reserved = Invoke-Tool -Arguments @('-Action', 'ConfigureProvider', '-ConfigPath', $freshConfig, '-ProviderId', 'openai', '-ProviderName', 'Bad', '-BaseUrl', 'https://example.invalid/v1', '-EnvKey', 'BAD_KEY', '-SkipCodexValidation', '-NoPause')
    $afterReserved = (Get-FileHash -Algorithm SHA256 -LiteralPath $freshConfig).Hash
    Assert-True ($reserved.ExitCode -ne 0 -and $beforeInvalid -eq $afterReserved) 'Reserved provider id is rejected without changing config'
    $credentialUrl = Invoke-Tool -Arguments @('-Action', 'ConfigureProvider', '-ConfigPath', $freshConfig, '-ProviderId', 'cst_bad_url', '-ProviderName', 'Bad URL', '-BaseUrl', 'https://user:password@example.invalid/v1', '-EnvKey', 'BAD_URL_KEY', '-SkipCodexValidation', '-NoPause')
    $afterCredentialUrl = (Get-FileHash -Algorithm SHA256 -LiteralPath $freshConfig).Hash
    Assert-True ($credentialUrl.ExitCode -ne 0 -and $beforeInvalid -eq $afterCredentialUrl) 'Base URL credentials are rejected without changing config'
    $protectedEnv = Invoke-Tool -Arguments @('-Action', 'ConfigureProvider', '-ConfigPath', $freshConfig, '-ProviderId', 'cst_bad_env', '-ProviderName', 'Bad Env', '-BaseUrl', 'https://example.invalid/v1', '-EnvKey', 'PATH', '-SkipCodexValidation', '-NoPause')
    $afterProtectedEnv = (Get-FileHash -Algorithm SHA256 -LiteralPath $freshConfig).Hash
    Assert-True ($protectedEnv.ExitCode -ne 0 -and $beforeInvalid -eq $afterProtectedEnv) 'Protected system environment-variable names are rejected'
    $badContext = Invoke-Tool -Arguments @('-Action', 'SetContext', '-ConfigPath', $freshConfig, '-ContextWindow', '1000', '-AutoCompactLimit', '1000', '-SkipCodexValidation', '-NoPause')
    $afterBadContext = (Get-FileHash -Algorithm SHA256 -LiteralPath $freshConfig).Hash
    Assert-True ($badContext.ExitCode -ne 0 -and $beforeInvalid -eq $afterBadContext) 'Invalid context values are rejected without changing config'

    $multilineHome = Join-Path $testRoot 'managed-multiline-fixture'
    New-Item -ItemType Directory -Path $multilineHome | Out-Null
    $multilineConfig = Join-Path $multilineHome 'config.toml'
    $multilineText = @('model = """', 'unexpected', '"""', '[model_providers.cst_multi]', 'name = "Multi"', 'base_url = "http://127.0.0.1:56789/v1"', 'wire_api = "responses"', 'env_key = "CST_MULTI_KEY"', '') -join "`n"
    [IO.File]::WriteAllText($multilineConfig, $multilineText, [Text.UTF8Encoding]::new($false))
    $multilineHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $multilineConfig).Hash
    $multilineEdit = Invoke-Tool -Arguments @('-Action', 'SetProvider', '-ConfigPath', $multilineConfig, '-ProviderId', 'cst_multi', '-Model', 'safe-model', '-SkipCodexValidation', '-NoPause')
    Assert-True ($multilineEdit.ExitCode -ne 0 -and (Get-FileHash -Algorithm SHA256 -LiteralPath $multilineConfig).Hash -eq $multilineHash) 'Managed multiline TOML values are refused instead of partially edited'

    $quotedHome = Join-Path $testRoot 'quoted-root-fixture'
    New-Item -ItemType Directory -Path $quotedHome | Out-Null
    $quotedConfig = Join-Path $quotedHome 'config.toml'
    $quotedText = @('"model_provider" = "openai"', '[model_providers.cst_quoted]', 'name = "Quoted"', 'base_url = "http://127.0.0.1:56789/v1"', 'wire_api = "responses"', 'env_key = "CST_QUOTED_KEY"', '') -join "`n"
    [IO.File]::WriteAllText($quotedConfig, $quotedText, [Text.UTF8Encoding]::new($false))
    $quotedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $quotedConfig).Hash
    $quotedEdit = Invoke-Tool -Arguments @('-Action', 'SetProvider', '-ConfigPath', $quotedConfig, '-ProviderId', 'cst_quoted', '-Model', 'safe-model', '-SkipCodexValidation', '-NoPause')
    Assert-True ($quotedEdit.ExitCode -ne 0 -and (Get-FileHash -Algorithm SHA256 -LiteralPath $quotedConfig).Hash -eq $quotedHash) 'Quoted logical root keys are refused to prevent duplicate TOML keys'

    $rollbackBefore = (Get-FileHash -Algorithm SHA256 -LiteralPath $freshConfig).Hash
    $rollback = Invoke-Tool -ForceValidationFailure -Arguments @('-Action', 'SetContext', '-ConfigPath', $freshConfig, '-ContextWindow', '400000', '-AutoCompactLimit', '350000', '-NoPause')
    $rollbackAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $freshConfig).Hash
    Assert-True ($rollback.ExitCode -ne 0 -and $rollbackBefore -eq $rollbackAfter) 'Forced validation failure automatically restores the original config'
    $rollbackThrow = Invoke-Tool -ForceValidationException -Arguments @('-Action', 'SetContext', '-ConfigPath', $freshConfig, '-ContextWindow', '400000', '-AutoCompactLimit', '350000', '-NoPause')
    $rollbackThrowAfter = (Get-FileHash -Algorithm SHA256 -LiteralPath $freshConfig).Hash
    Assert-True ($rollbackThrow.ExitCode -ne 0 -and $rollbackBefore -eq $rollbackThrowAfter) 'Validation exception also restores the original config'

    $restoreBaselineHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $freshConfig).Hash
    $changeForRestore = Invoke-Tool -Arguments @('-Action', 'SetContext', '-ConfigPath', $freshConfig, '-ContextWindow', '300000', '-AutoCompactLimit', '250000', '-SkipCodexValidation', '-NoPause')
    . $tool -ConfigPath $freshConfig -SkipCodexValidation -NoPause
    $latestBackup = @(Get-BackupRecords | Select-Object -First 1)
    $restoreSucceeded = $true
    try { Restore-BackupRecord -Record $latestBackup[0] } catch { $restoreSucceeded = $false }
    $restoredHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $freshConfig).Hash
    Assert-True ($changeForRestore.ExitCode -eq 0 -and $restoreSucceeded -and $restoredHash -eq $restoreBaselineHash) 'Backup restore returns the exact pre-change config and creates a safety backup'

    $legacyHome = Join-Path $testRoot 'legacy-secret-fixture'
    New-Item -ItemType Directory -Path $legacyHome | Out-Null
    $legacyConfig = Join-Path $legacyHome 'config.toml'
    $sentinel = 'CST_FAKE_SECRET_SENTINEL_1234567890'
    $legacyText = @(
        '[model_providers.legacy]',
        'name = "Legacy"',
        'base_url = "http://127.0.0.1:56789/v1"',
        'wire_api = "responses"',
        ('experimental_bearer_token = "' + $sentinel + '"'),
        ''
    ) -join "`n"
    [IO.File]::WriteAllText($legacyConfig, $legacyText, [Text.UTF8Encoding]::new($false))
    $legacyBeforeUpdate = (Get-FileHash -Algorithm SHA256 -LiteralPath $legacyConfig).Hash
    $unsafeUpdate = Invoke-Tool -Arguments @('-Action', 'ConfigureProvider', '-ConfigPath', $legacyConfig, '-ProviderId', 'legacy', '-ProviderName', 'Legacy Updated', '-BaseUrl', 'http://127.0.0.1:56789/v1', '-EnvKey', 'CST_LEGACY_TEST_KEY', '-SkipCodexValidation', '-NoPause')
    $legacyAfterUpdate = (Get-FileHash -Algorithm SHA256 -LiteralPath $legacyConfig).Hash
    Assert-True ($unsafeUpdate.ExitCode -ne 0 -and $legacyBeforeUpdate -eq $legacyAfterUpdate) 'Generic provider update never deletes a legacy inline token implicitly'
    $legacyEnvName = 'CST_LEGACY_TEST_KEY'
    $previousProcessSecret = [Environment]::GetEnvironmentVariable($legacyEnvName, 'Process')
    . $tool -ConfigPath $legacyConfig -SkipCodexValidation -NoPause
    $redactedProbe = Protect-OutputText -Text ('provider echoed ' + $sentinel)
    $migrationSucceeded = $true
    $migrationOutput = ''
    try {
        $migrationOutput = (& { Invoke-MigrateLegacySecretOperation -Id 'legacy' -EnvironmentKey $legacyEnvName -Target 'Process' } *>&1 | Out-String)
    } catch {
        $migrationSucceeded = $false
        $migrationOutput = ($_ | Out-String)
    }
    $processSecretMatched = [Environment]::GetEnvironmentVariable($legacyEnvName, 'Process') -ceq $sentinel
    [Environment]::SetEnvironmentVariable($legacyEnvName, $previousProcessSecret, 'Process')
    $legacyFinal = Read-Utf8Text $legacyConfig
    $escapedSentinel = [regex]::Escape($sentinel)
    Assert-True $migrationSucceeded 'Legacy inline token migration succeeds in the same isolated Process scope'
    Assert-True $processSecretMatched 'Process-scope migration keeps the key available in the process that will use it'
    Assert-True ($migrationOutput -notmatch $escapedSentinel) 'Migration never prints the token'
    Assert-True ($redactedProbe -notmatch $escapedSentinel) 'Runtime output redaction removes arbitrary-format known provider secrets'
    Assert-True (($legacyFinal -notmatch $escapedSentinel) -and ($legacyFinal -notmatch 'experimental_bearer_token')) 'Migration removes inline token from live config'
    Assert-True ($legacyFinal -match '(?m)^env_key = "CST_LEGACY_TEST_KEY"$') 'Migration replaces inline token with env_key metadata'

    Write-Host ''
    Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Passed, $script:Failed)
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        $summary = @('# Codex Switch Tools test result', '', ("- Passed: {0}" -f $script:Passed), ("- Failed: {0}" -f $script:Failed))
        if ($script:FailureMessages.Count -gt 0) {
            $summary += ''
            $summary += '## Failed assertions'
            foreach ($failure in $script:FailureMessages) { $summary += ('- ' + $failure) }
        }
        [IO.File]::AppendAllLines($env:GITHUB_STEP_SUMMARY, $summary, [Text.UTF8Encoding]::new($false))
    }
    if ($script:Failed -gt 0) { exit 1 }
} finally {
    if ($KeepTemp) {
        Write-Host ('Kept test directory: ' + $testRoot)
    } else {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolved).StartsWith('codex-switch-tools-tests-', [StringComparison]::Ordinal)) {
            throw "Refusing to clean unexpected test path: $resolved"
        }
        if (Test-Path -LiteralPath $resolved -PathType Container) { [IO.Directory]::Delete($resolved, $true) }
    }
}
