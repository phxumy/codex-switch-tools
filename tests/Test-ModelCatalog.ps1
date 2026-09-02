[CmdletBinding()]
param([switch]$KeepTemp)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $repoRoot 'Codex-Switch-Tools.ps1'
$engine = (Get-Process -Id $PID).Path
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempParent ('codex-switch-model-tests-' + [guid]::NewGuid().ToString('N'))
$script:Passed = 0
$script:Failed = 0
$script:Failures = [Collections.Generic.List[string]]::new()
$serverProcess = $null
$testEnvName = 'CST_MODELS_TEST_' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
$dummyKey = 'cst-model-catalog-dummy'
$encoding = [Text.UTF8Encoding]::new($false)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:Passed++
        Write-Host ('[PASS] ' + $Message) -ForegroundColor Green
    } else {
        $script:Failed++
        [void]$script:Failures.Add($Message)
        Write-Host ('[FAIL] ' + $Message) -ForegroundColor Red
    }
}

function Invoke-Tool {
    param([string]$Path, [string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    try {
        # Native stderr should be captured as test evidence in both PS 5.1 and PS 7.
        $ErrorActionPreference = 'Continue'
        $output = & $engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tool -ConfigPath $Path -SkipCodexValidation -NoPause @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    $text = ($output | Out-String).Trim()
    Assert-True (-not $text.Contains($dummyKey)) 'Command output does not reveal the dummy API key'
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $text }
}

function Require-Success {
    param($Result, [string]$Message)
    Assert-True ($Result.ExitCode -eq 0) $Message
    if ($Result.ExitCode -ne 0) { throw ($Message + ': ' + $Result.Output) }
}

function Read-Text {
    param([string]$Path)
    return [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
}

function Read-RootString {
    param([string]$Path, [string]$Key)
    $match = [regex]::Match((Read-Text $Path), ('(?m)^' + [regex]::Escape($Key) + '\s*=\s*("(?:\\.|[^"\\])*")\s*(?:#.*)?$'))
    if (-not $match.Success) { return $null }
    return ($match.Groups[1].Value | ConvertFrom-Json)
}

function Get-Catalog {
    param([string]$Path)
    $catalogPath = Read-RootString $Path 'model_catalog_json'
    if ([string]::IsNullOrWhiteSpace($catalogPath)) { throw 'No model_catalog_json was written.' }
    if (-not [IO.Path]::IsPathRooted($catalogPath)) { $catalogPath = Join-Path (Split-Path -Parent $Path) $catalogPath }
    return [pscustomobject]@{ Path = $catalogPath; Content = ((Read-Text $catalogPath) | ConvertFrom-Json) }
}

function Configure-Fixture {
    param([string]$Path, [string]$Id, [string]$Url, [switch]$Anonymous)
    $arguments = @('-Action', 'ConfigureProvider', '-ProviderId', $Id, '-ProviderName', ('Fixture ' + $Id), '-BaseUrl', $Url)
    if ($Anonymous) { $arguments += '-NoAuth' } else { $arguments += @('-EnvKey', $testEnvName) }
    Require-Success (Invoke-Tool $Path $arguments) ('Configure isolated provider ' + $Id)
}

function Set-ServerMode {
    param([string]$Mode)
    [IO.File]::WriteAllText($controlFile, (@{ mode = $Mode } | ConvertTo-Json -Compress), $encoding)
}

function Read-Requests {
    if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) { return @() }
    $decoded = (Read-Text $resultFile) | ConvertFrom-Json
    return $decoded
}

New-Item -ItemType Directory -Path $testRoot | Out-Null
[Environment]::SetEnvironmentVariable($testEnvName, $dummyKey, 'Process')
try {
    Write-Host ('Engine: ' + $engine)
    Write-Host ('Version: ' + $PSVersionTable.PSVersion)
    Write-Host ('Temp: ' + $testRoot)
    $specialHome = Join-Path $testRoot ('catalog space & ' + [char]0x6d4b + [char]0x8bd5 + ' (fixture)')
    $config = Join-Path $specialHome 'config.toml'
    Configure-Fixture $config 'deepseek_official' 'https://api.deepseek.com/'
    Configure-Fixture $config 'iphy' 'https://chat.iphy.ac.cn/api/v1'

    $listResult = Invoke-Tool $config @('-Action', 'ListModels', '-ProviderId', 'deepseek_official', '-Json')
    Require-Success $listResult 'Offline ListModels supports official DeepSeek under an arbitrary Provider ID'
    $list = $listResult.Output | ConvertFrom-Json
    $known = @($list.Models)
    Assert-True ($list.ProviderId -eq 'deepseek_official' -and $known.Count -ge 3) 'Official metadata includes the current three DeepSeek models'
    $vision = @($known | Where-Object { $_.Id -eq 'deepseek-v4-flash-vision-exp' })
    Assert-True ($vision.Count -eq 1 -and $vision[0].Verified -and $vision[0].SupportsImages -and $vision[0].ContextWindow -eq 1048576) 'Vision metadata is explicitly image-capable with official 1M context'
    $pro = @($known | Where-Object { $_.Id -eq 'deepseek-v4-pro' })
    Assert-True ($pro.Count -eq 1 -and $pro[0].Verified -and -not $pro[0].SupportsImages) 'Text model is not silently declared image-capable'

    Require-Success (Invoke-Tool $config @('-Action', 'SetProvider', '-ProviderId', 'deepseek_official', '-Model', 'deepseek-v4-flash-vision-exp', '-ManageModelCatalog')) 'Managed vision-model selection succeeds'
    $officialCatalog = Get-Catalog $config
    $officialEntry = @($officialCatalog.Content.models | Where-Object { $_.slug -eq 'deepseek-v4-flash-vision-exp' })
    Assert-True ($officialEntry.Count -eq 1 -and $officialEntry[0].input_modalities -contains 'image') 'Written Codex catalog advertises image input for the vision model'
    Assert-True ($officialEntry.Count -eq 1 -and $officialEntry[0].context_window -eq 1048576) 'Written official catalog has the verified context window'
    Assert-True (@($officialCatalog.Content.models | Where-Object { $_.slug -like 'gpt-*' }).Count -eq 0) 'DeepSeek catalog never mixes in built-in GPT choices'
    Assert-True (@($officialCatalog.Content.models | Where-Object { $_.input_modalities -isnot [Array] }).Count -eq 0) 'Single text modalities remain JSON arrays for the native Codex schema'
    Assert-True (@($officialCatalog.Content.models | Where-Object { $_.experimental_supported_tools -isnot [Array] }).Count -eq 0) 'Required experimental_supported_tools is an array in every catalog entry'
    $officialBytes = Read-Text $officialCatalog.Path

    Require-Success (Invoke-Tool $config @('-Action', 'SetProvider', '-ProviderId', 'iphy', '-Model', 'deepseek-v4-pro', '-ManageModelCatalog')) 'Switching to IPHY creates its independent catalog'
    $iphyCatalog = Get-Catalog $config
    $iphyEntry = @($iphyCatalog.Content.models | Where-Object { $_.slug -eq 'deepseek-v4-pro' })
    Assert-True ($iphyCatalog.Path -ne $officialCatalog.Path) 'Same model names under different providers use separate catalog files'
    Assert-True ($iphyEntry.Count -eq 1 -and $iphyEntry[0].context_window -eq 262144) 'IPHY pro uses the verified 256K provider-specific context'
    Assert-True ((Read-Text $officialCatalog.Path) -ceq $officialBytes) 'Switching IPHY does not mutate the official DeepSeek catalog'

    $rememberedResult = Invoke-Tool $config @('-Action', 'ListModels', '-ProviderId', 'deepseek_official', '-Json')
    Require-Success $rememberedResult 'Official model choice remains available while IPHY is active'
    $remembered = $rememberedResult.Output | ConvertFrom-Json
    Assert-True ($remembered.LastModel -eq 'deepseek-v4-flash-vision-exp') 'Last selected model is remembered per Provider'

    $beforeGuard = Read-Text $config
    $wrongModel = Invoke-Tool $config @('-Action', 'SetProvider', '-ProviderId', 'deepseek_official', '-Model', 'gpt-5.6-sol', '-ManageModelCatalog', '-AllowUnverifiedModel')
    Assert-True ($wrongModel.ExitCode -ne 0 -and (Read-Text $config) -ceq $beforeGuard) 'Recognized DeepSeek rejects GPT-model mismatch even when unknown models are allowed'
    $unknown = Invoke-Tool $config @('-Action', 'SetProvider', '-ProviderId', 'iphy', '-Model', 'deepseek-new-unverified', '-ManageModelCatalog')
    Assert-True ($unknown.ExitCode -ne 0 -and (Read-Text $config) -ceq $beforeGuard) 'Unknown model requires explicit consent and leaves config unchanged on refusal'
    Require-Success (Invoke-Tool $config @('-Action', 'SetProvider', '-ProviderId', 'iphy', '-Model', 'deepseek-new-unverified', '-ManageModelCatalog', '-AllowUnverifiedModel')) 'Unknown future model can be selected with explicit consent'
    $unknownCatalog = Get-Catalog $config
    $unknownCatalogBytes = Read-Text $unknownCatalog.Path
    $unknownEntry = @($unknownCatalog.Content.models | Where-Object { $_.slug -eq 'deepseek-new-unverified' })
    Assert-True ($unknownEntry.Count -eq 1 -and $unknownEntry[0].context_window -eq 32768 -and $unknownEntry[0].input_modalities -notcontains 'image') 'Unknown models use conservative 32K text-only metadata'
    Assert-True ($unknownEntry[0].supported_reasoning_levels -is [Array] -and $unknownEntry[0].supported_reasoning_levels.Count -eq 0) 'Unknown-model reasoning levels remain an empty JSON array, not null'
    Require-Success (Invoke-Tool $config @('-Action', 'SetProvider', '-ProviderId', 'iphy', '-Model', 'deepseek-new-unverified', '-ManageModelCatalog', '-AllowUnverifiedModel', '-ContextWindow', '65536')) 'Unknown-model context can be set explicitly'
    $overrideCatalog = Get-Catalog $config
    $overrideEntry = @($overrideCatalog.Content.models | Where-Object { $_.slug -eq 'deepseek-new-unverified' })
    Assert-True ($overrideEntry.Count -eq 1 -and $overrideEntry[0].context_window -eq 65536) 'Explicit unknown-model context is written to the generated catalog'
    Assert-True ($overrideCatalog.Path -ne $unknownCatalog.Path -and (Read-Text $unknownCatalog.Path) -ceq $unknownCatalogBytes) 'Catalog revisions are immutable so old backups retain their original metadata'
    $backupList = Invoke-Tool $config @('-Action', 'ListBackups', '-Json')
    Require-Success $backupList 'Catalog-managed configurations participate in normal backup listing'
    $backups = [object[]]($backupList.Output | ConvertFrom-Json)
    Require-Success (Invoke-Tool $config @('-Action', 'RestoreBackup', '-BackupName', $backups[0].Name, '-ConfirmRestoreBackup')) 'Restoring the prior catalog-managed configuration succeeds'
    $backupCatalog = Get-Catalog $config
    Assert-True ($backupCatalog.Path -eq $unknownCatalog.Path -and (Read-Text $backupCatalog.Path) -ceq $unknownCatalogBytes) 'Backup restoration points to its intact historical catalog'

    Require-Success (Invoke-Tool $config @('-Action', 'UseOpenAI')) 'Returning to OpenAI removes a newly managed catalog'
    $resetText = Read-Text $config
    Assert-True ($resetText -notmatch '(?m)^model_catalog_json\s*=' -and $resetText -notmatch '(?m)^model_context_window\s*=' -and $resetText -notmatch '(?m)^model_auto_compact_token_limit\s*=') 'Absent original catalog/context/compact values are restored to absent'

    $existingDir = Join-Path $testRoot 'existing baseline'
    New-Item -ItemType Directory -Path $existingDir | Out-Null
    $existingCatalog = Join-Path $existingDir 'user-models.json'
    [IO.File]::WriteAllText($existingCatalog, '{"models":[]}', $encoding)
    $existingConfig = Join-Path $existingDir 'config.toml'
    $quotedPath = ($existingCatalog.Replace('\', '/') | ConvertTo-Json -Compress)
    [IO.File]::WriteAllText($existingConfig, ("model_catalog_json = $quotedPath`nmodel_context_window = 65536`nmodel_auto_compact_token_limit = 60000`n"), $encoding)
    Configure-Fixture $existingConfig 'official' 'https://api.deepseek.com/v1'
    Configure-Fixture $existingConfig 'iphy' 'https://chat.iphy.ac.cn/api/v1'
    $baseline = Read-Text $existingConfig
    $catalogRefused = Invoke-Tool $existingConfig @('-Action', 'SetProvider', '-ProviderId', 'official', '-Model', 'deepseek-v4-pro', '-ManageModelCatalog')
    Assert-True ($catalogRefused.ExitCode -ne 0 -and (Read-Text $existingConfig) -ceq $baseline) 'Existing unmanaged catalog is not replaced without explicit consent'
    Require-Success (Invoke-Tool $existingConfig @('-Action', 'SetProvider', '-ProviderId', 'official', '-Model', 'deepseek-v4-pro', '-ManageModelCatalog', '-ReplaceExistingCatalog')) 'Explicit replacement takes a restorable baseline'
    Require-Success (Invoke-Tool $existingConfig @('-Action', 'SetProvider', '-ProviderId', 'iphy', '-Model', 'deepseek-v4-pro', '-ManageModelCatalog')) 'Provider changes keep the first pre-management baseline'
    Require-Success (Invoke-Tool $existingConfig @('-Action', 'UseOpenAI')) 'OpenAI selection restores the pre-management baseline'
    $restored = Read-Text $existingConfig
    Assert-True ((Read-RootString $existingConfig 'model_catalog_json') -eq $existingCatalog.Replace('\', '/')) 'Original unmanaged catalog path is restored exactly'
    Assert-True ($restored -match '(?m)^model_context_window = 65536$' -and $restored -match '(?m)^model_auto_compact_token_limit = 60000$') 'Original context and compaction threshold are restored, not last provider values'
    Assert-True ((Read-Text $existingCatalog) -ceq '{"models":[]}') 'External user catalog contents are never overwritten'

    $python = Get-Command python -ErrorAction Stop | Select-Object -First 1
    $serverScript = Join-Path $PSScriptRoot 'mock_models_server.py'
    $readyFile = Join-Path $testRoot 'models-ready.json'
    $resultFile = Join-Path $testRoot 'models-results.json'
    $controlFile = Join-Path $testRoot 'models-control.json'
    Set-ServerMode 'success'
    $serverArguments = @(('"{0}"' -f $serverScript), '--ready', ('"{0}"' -f $readyFile), '--result', ('"{0}"' -f $resultFile), '--control', ('"{0}"' -f $controlFile))
    $serverProcess = Start-Process -FilePath $python.Source -ArgumentList $serverArguments -PassThru -WindowStyle Hidden
    for ($i = 0; $i -lt 100 -and -not (Test-Path -LiteralPath $readyFile -PathType Leaf); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $readyFile -PathType Leaf)) { throw 'Local /models fixture did not become ready.' }
    $ready = (Read-Text $readyFile) | ConvertFrom-Json
    $mockConfig = Join-Path (Join-Path $testRoot 'discovery') 'config.toml'
    $mockUrl = 'http://127.0.0.1:' + $ready.port + '/v1'
    Configure-Fixture $mockConfig 'mock' $mockUrl

    $offline = Invoke-Tool $mockConfig @('-Action', 'ListModels', '-ProviderId', 'mock', '-Json')
    Require-Success $offline 'Offline model listing works for a generic provider'
    Assert-True (@(Read-Requests).Count -eq 0) 'ListModels never contacts the provider implicitly'
    $unconfirmed = Invoke-Tool $mockConfig @('-Action', 'RefreshModels', '-ProviderId', 'mock', '-Json')
    Assert-True ($unconfirmed.ExitCode -ne 0 -and @(Read-Requests).Count -eq 0) 'Network model refresh requires explicit confirmation'
    $refresh = Invoke-Tool $mockConfig @('-Action', 'RefreshModels', '-ProviderId', 'mock', '-ConfirmModelRefresh', '-Json')
    Require-Success $refresh 'Explicit refresh fetches a valid /models response'
    $discovered = $refresh.Output | ConvertFrom-Json
    Assert-True (@($discovered.Models | Where-Object { $_.Id -eq 'fixture-future-v2' }).Count -eq 1) 'Newly released model IDs are discovered without hard-coded names'
    Assert-True (@($discovered.Models | Where-Object { $_.Verified -or $_.SupportsImages }).Count -eq 0) 'A model ID alone never becomes verified or image-capable'
    $requests = @(Read-Requests)
    Assert-True ($requests.Count -eq 1 -and $requests[0].method -eq 'GET' -and $requests[0].path -eq '/v1/models' -and $requests[0].authorization_matches_dummy) 'Discovery uses GET at the exact configured base URL with the intended dummy bearer'
    $cached = Invoke-Tool $mockConfig @('-Action', 'ListModels', '-ProviderId', 'mock', '-Json')
    Require-Success $cached 'Successful discovery is available offline'
    $cacheBefore = $cached.Output | ConvertFrom-Json

    foreach ($mode in @('missing-data', 'invalid-id', 'empty-data', 'malformed-json', 'server-error', 'too-many-models', 'oversized-response', 'redirect')) {
        Set-ServerMode $mode
        $countBefore = @(Read-Requests).Count
        $failedRefresh = Invoke-Tool $mockConfig @('-Action', 'RefreshModels', '-ProviderId', 'mock', '-ConfirmModelRefresh', '-Json')
        Assert-True ($failedRefresh.ExitCode -ne 0) ('Invalid model response is rejected: ' + $mode)
        $afterFailure = Invoke-Tool $mockConfig @('-Action', 'ListModels', '-ProviderId', 'mock', '-Json')
        Require-Success $afterFailure ('Cached models remain available after ' + $mode)
        $cacheAfter = $afterFailure.Output | ConvertFrom-Json
        Assert-True (($cacheAfter.Models | ConvertTo-Json -Depth 12 -Compress) -ceq ($cacheBefore.Models | ConvertTo-Json -Depth 12 -Compress)) ('Failed refresh keeps the last successful model cache: ' + $mode)
        Assert-True ($cacheAfter.RefreshedAt -ceq $cacheBefore.RefreshedAt) ('Failed refresh does not forge a successful refresh time: ' + $mode)
        if ($mode -eq 'redirect') {
            $afterRequests = @(Read-Requests)
            Assert-True ($afterRequests.Count -eq ($countBefore + 1) -and @($afterRequests | Where-Object { $_.path -eq '/redirect-target/models' }).Count -eq 0) 'Redirects are not followed and bearer auth cannot leak to a redirect target'
        }
    }

    Set-ServerMode 'success'
    Configure-Fixture $mockConfig 'anonymous' $mockUrl -Anonymous
    Require-Success (Invoke-Tool $mockConfig @('-Action', 'RefreshModels', '-ProviderId', 'anonymous', '-ConfirmModelRefresh', '-Json')) 'No-auth providers can explicitly refresh models'
    $requests = @(Read-Requests)
    Assert-True (-not $requests[$requests.Count - 1].authorization_present) 'No-auth refresh sends no Authorization header'

    $requestsBeforeSafety = @(Read-Requests).Count
    Configure-Fixture $mockConfig 'insecure' 'http://example.invalid/v1'
    $insecure = Invoke-Tool $mockConfig @('-Action', 'RefreshModels', '-ProviderId', 'insecure', '-ConfirmModelRefresh', '-Json')
    Assert-True ($insecure.ExitCode -ne 0) 'Plain HTTP model discovery is prohibited outside loopback'
    Configure-Fixture $mockConfig 'advanced' $mockUrl
    [IO.File]::AppendAllText($mockConfig, "`n[model_providers.advanced.http_headers]`nX-Fixture = `"fixture-value`"`n", $encoding)
    $advanced = Invoke-Tool $mockConfig @('-Action', 'RefreshModels', '-ProviderId', 'advanced', '-ConfirmModelRefresh', '-Json')
    Assert-True ($advanced.ExitCode -ne 0 -and @(Read-Requests).Count -eq $requestsBeforeSafety) 'Advanced-auth configuration is not silently sent through simple-auth discovery'

    Configure-Fixture $mockConfig 'mock' ($mockUrl + '/different-endpoint')
    $otherEndpointResult = Invoke-Tool $mockConfig @('-Action', 'ListModels', '-ProviderId', 'mock', '-Json')
    Require-Success $otherEndpointResult 'Changing a provider endpoint can still list models offline'
    $otherEndpoint = $otherEndpointResult.Output | ConvertFrom-Json
    Assert-True (@($otherEndpoint.Models | Where-Object { $_.Id -eq 'fixture-future-v2' }).Count -eq 0) 'Model cache from an old endpoint is not reused for a changed endpoint'
    Configure-Fixture $mockConfig 'mock' $mockUrl
    $originalEndpointResult = Invoke-Tool $mockConfig @('-Action', 'ListModels', '-ProviderId', 'mock', '-Json')
    Require-Success $originalEndpointResult 'Returning to the original endpoint finds its original model cache'
    $originalEndpoint = $originalEndpointResult.Output | ConvertFrom-Json
    Assert-True (@($originalEndpoint.Models | Where-Object { $_.Id -eq 'fixture-future-v2' }).Count -eq 1) 'Endpoint-specific caches remain independent and recoverable'

    $secretFound = $false
    foreach ($file in Get-ChildItem -LiteralPath $testRoot -Recurse -File) {
        if ((Read-Text $file.FullName).Contains($dummyKey)) { $secretFound = $true }
    }
    Assert-True (-not $secretFound) 'No config, catalog, cache, backup, or request fixture persists the API key'
} catch {
    Assert-True $false ('Unhandled test failure: ' + $_.Exception.Message)
} finally {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) { Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue }
    [Environment]::SetEnvironmentVariable($testEnvName, $null, 'Process')
    if (-not $KeepTemp) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolved).StartsWith('codex-switch-model-tests-', [StringComparison]::Ordinal)) { throw ('Refusing unexpected cleanup path: ' + $resolved) }
        if (Test-Path -LiteralPath $resolved -PathType Container) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
Write-Host ('Model catalog tests: ' + $script:Passed + ' passed; ' + $script:Failed + ' failed.')
if ($script:Failed -gt 0) {
    foreach ($failure in $script:Failures) { Write-Host (' - ' + $failure) -ForegroundColor Red }
    exit 1
}
exit 0
