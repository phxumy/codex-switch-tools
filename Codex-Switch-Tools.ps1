[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Status', 'UseOpenAI', 'ConfigureProvider', 'SetProvider', 'SetContext', 'ResetContext', 'ToggleLongContext', 'MigrateLegacySecret', 'Validate')]
    [string]$Action = 'Menu',
    [string]$ConfigPath,
    [string]$ProviderId,
    [string]$ProviderName,
    [string]$BaseUrl,
    [string]$EnvKey,
    [string]$Model,
    [string]$ReasoningEffort,
    [Nullable[long]]$ContextWindow,
    [Nullable[long]]$AutoCompactLimit,
    [ValidateSet('User')]
    [string]$EnvironmentTarget = 'User',
    [switch]$NoAuth,
    [switch]$ForceRemoveUnmanagedContext,
    [switch]$ForceOverwriteEnvironmentVariable,
    [switch]$NoPause,
    [switch]$SkipCodexValidation,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolVersion = '1.0.0'
$script:EntryExitCode = 0
$script:ContextMarkerPattern = '^\s*#\s*CST_CONTEXT_V1\s+previous_window=(absent|[0-9_]+)\s+previous_compact=(absent|[0-9_]+)\s*$'
$script:ReservedProviderIds = @('openai', 'ollama', 'lmstudio')

function Resolve-ConfigPath {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        return [IO.Path]::GetFullPath($RequestedPath)
    }

    $codexHome = $env:CODEX_HOME
    if ([string]::IsNullOrWhiteSpace($codexHome)) {
        $userProfile = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($userProfile)) {
            $userProfile = [Environment]::GetFolderPath('UserProfile')
        }
        if ([string]::IsNullOrWhiteSpace($userProfile)) {
            throw 'Cannot resolve USERPROFILE or CODEX_HOME.'
        }
        $codexHome = Join-Path $userProfile '.codex'
    }

    return [IO.Path]::GetFullPath((Join-Path $codexHome 'config.toml'))
}

$script:ConfigPath = Resolve-ConfigPath -RequestedPath $ConfigPath
$script:CodexDir = Split-Path -Parent $script:ConfigPath
$script:ToolDataDir = Join-Path $script:CodexDir 'switch-tools'
$script:BackupRoot = Join-Path $script:ToolDataDir 'backups'

function Write-Heading {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor DarkCyan
}

function Pause-Here {
    if (-not $NoPause) {
        Write-Host ''
        [void](Read-Host 'Press Enter to continue')
    }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

function New-StringList {
    return [System.Collections.Generic.List[string]]::new()
}

function Read-ConfigDocument {
    param([string]$Path = $script:ConfigPath)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
    $bytes = [byte[]]::new(0)
    if ($exists) { $bytes = [IO.File]::ReadAllBytes($fullPath) }
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = if ($hasBom) { 3 } else { 0 }
    $count = $bytes.Length - $offset
    $decoder = [Text.UTF8Encoding]::new($false, $true)

    try {
        $text = if ($count -gt 0) { $decoder.GetString($bytes, $offset, $count) } else { '' }
    } catch {
        throw "Config is not valid UTF-8: $fullPath"
    }

    $newLine = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $hadFinalNewLine = $text -match '(?:\r\n|\n)\z'
    $parts = @()
    if ($text.Length -gt 0) { $parts = @([regex]::Split($text, '\r\n|\n')) }
    if ($hadFinalNewLine -and $parts.Count -gt 0 -and $parts[$parts.Count - 1] -eq '') {
        $parts = @($parts[0..($parts.Count - 2)])
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $parts) { [void]$lines.Add([string]$part) }

    return [pscustomobject]@{
        Path = $fullPath
        Exists = $exists
        OriginalBytes = $bytes
        OriginalHash = Get-Sha256Hex -Bytes $bytes
        OriginalText = $text
        HasUtf8Bom = $hasBom
        NewLine = $newLine
        HadFinalNewLine = $hadFinalNewLine
        Lines = $lines
    }
}

function Get-DocumentText {
    param($Document)
    if ($Document.Lines.Count -eq 0) { return '' }
    $text = [string]::Join($Document.NewLine, $Document.Lines.ToArray())
    if ($Document.HadFinalNewLine -or -not $Document.Exists) {
        $text += $Document.NewLine
    }
    return $text
}

function Get-TomlLineStates {
    param([System.Collections.Generic.List[string]]$Lines)

    $states = [System.Collections.Generic.List[object]]::new()
    $mode = 'normal'
    $squareDepth = 0
    $curlyDepth = 0

    for ($lineIndex = 0; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line = $Lines[$lineIndex]
        $neutralAtStart = $mode -eq 'normal' -and $squareDepth -eq 0 -and $curlyDepth -eq 0
        $trimmed = $line.Trim()
        $isHeader = $neutralAtStart -and $trimmed -match '^\[\[?.+\]\]?\s*(?:#.*)?$'
        [void]$states.Add([pscustomobject]@{
            Index = $lineIndex
            NeutralAtStart = $neutralAtStart
            IsHeader = $isHeader
            Text = $line
        })

        $inBasic = $false
        $inLiteral = $false
        $escaped = $false
        $i = 0
        while ($i -lt $line.Length) {
            if ($mode -eq 'multi_basic') {
                if ($i + 2 -lt $line.Length -and $line.Substring($i, 3) -eq '"""') {
                    $mode = 'normal'
                    $i += 3
                } else {
                    $i++
                }
                continue
            }
            if ($mode -eq 'multi_literal') {
                if ($i + 2 -lt $line.Length -and $line.Substring($i, 3) -eq "'''") {
                    $mode = 'normal'
                    $i += 3
                } else {
                    $i++
                }
                continue
            }

            $ch = $line[$i]
            if ($inBasic) {
                if ($escaped) {
                    $escaped = $false
                } elseif ($ch -eq '\') {
                    $escaped = $true
                } elseif ($ch -eq '"') {
                    $inBasic = $false
                }
                $i++
                continue
            }
            if ($inLiteral) {
                if ($ch -eq "'") { $inLiteral = $false }
                $i++
                continue
            }

            if ($ch -eq '#') { break }
            if ($i + 2 -lt $line.Length -and $line.Substring($i, 3) -eq '"""') {
                $mode = 'multi_basic'
                $i += 3
                continue
            }
            if ($i + 2 -lt $line.Length -and $line.Substring($i, 3) -eq "'''") {
                $mode = 'multi_literal'
                $i += 3
                continue
            }
            if ($ch -eq '"') { $inBasic = $true; $i++; continue }
            if ($ch -eq "'") { $inLiteral = $true; $i++; continue }
            if ($ch -eq '[') { $squareDepth++ }
            elseif ($ch -eq ']') { if ($squareDepth -gt 0) { $squareDepth-- } }
            elseif ($ch -eq '{') { $curlyDepth++ }
            elseif ($ch -eq '}') { if ($curlyDepth -gt 0) { $curlyDepth-- } }
            $i++
        }
    }

    return $states
}

function Get-FirstTableIndex {
    param($Document)
    $states = Get-TomlLineStates -Lines $Document.Lines
    foreach ($state in $states) {
        if ($state.IsHeader) { return [int]$state.Index }
    }
    return $Document.Lines.Count
}

function ConvertTo-TomlString {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped.Replace("`b", '\b').Replace("`t", '\t').Replace("`n", '\n').Replace("`f", '\f').Replace("`r", '\r')
    return '"' + $escaped + '"'
}

function ConvertFrom-SimpleTomlString {
    param([string]$RawValue)
    if ($null -eq $RawValue) { return $null }
    $value = $RawValue.Trim()
    if ($value.Length -ge 2 -and $value[0] -eq '"' -and $value[$value.Length - 1] -eq '"') {
        $value = $value.Substring(1, $value.Length - 2)
        $value = $value.Replace('\"', '"').Replace('\\', '\')
        return $value
    }
    if ($value.Length -ge 2 -and $value[0] -eq "'" -and $value[$value.Length - 1] -eq "'") {
        return $value.Substring(1, $value.Length - 2)
    }
    return $value
}

function Split-TomlAssignmentLine {
    param([string]$Line, [string]$ExpectedKey)
    $prefixMatch = [regex]::Match($Line, '^\s*' + [regex]::Escape($ExpectedKey) + '\s*=\s*')
    if (-not $prefixMatch.Success) { return $null }
    $valueStart = $prefixMatch.Length
    $inBasic = $false
    $inLiteral = $false
    $escaped = $false
    $commentStart = -1
    for ($i = $valueStart; $i -lt $Line.Length; $i++) {
        $ch = $Line[$i]
        if ($inBasic) {
            if ($escaped) { $escaped = $false }
            elseif ($ch -eq '\') { $escaped = $true }
            elseif ($ch -eq '"') { $inBasic = $false }
            continue
        }
        if ($inLiteral) {
            if ($ch -eq "'") { $inLiteral = $false }
            continue
        }
        if ($ch -eq '"') { $inBasic = $true; continue }
        if ($ch -eq "'") { $inLiteral = $true; continue }
        if ($ch -eq '#') { $commentStart = $i; break }
    }
    if ($commentStart -lt 0) { $commentStart = $Line.Length }
    $valueAndSpacing = $Line.Substring($valueStart, $commentStart - $valueStart)
    $rawValue = $valueAndSpacing.Trim()
    $leadingLength = $valueAndSpacing.Length - $valueAndSpacing.TrimStart().Length
    $trailingLength = $valueAndSpacing.Length - $valueAndSpacing.TrimEnd().Length
    $prefix = $Line.Substring(0, $valueStart) + $valueAndSpacing.Substring(0, $leadingLength)
    $suffixStart = $commentStart - $trailingLength
    if ($suffixStart -lt $valueStart) { $suffixStart = $valueStart }
    $suffix = $Line.Substring($suffixStart)
    return [pscustomobject]@{ Prefix = $prefix; RawValue = $rawValue; Suffix = $suffix }
}

function Assert-SingleLineManagedValue {
    param($Assignment, [string]$Key)
    if ($null -eq $Assignment) { return }
    $raw = $Assignment.RawValue.TrimStart()
    if ($raw.StartsWith('"""') -or $raw.StartsWith("'''") -or $raw.StartsWith('[') -or $raw.StartsWith('{')) {
        throw "Managed key '$Key' uses a multiline/compound TOML value. Refusing a partial line edit; simplify it manually first."
    }
}

function Assert-NoQuotedRootEquivalent {
    param($Document, [string]$Key)
    $states = Get-TomlLineStates -Lines $Document.Lines
    $pattern = '^\s*(?:"' + [regex]::Escape($Key) + '"|''' + [regex]::Escape($Key) + ''')\s*='
    foreach ($state in $states) {
        if ($state.IsHeader) { break }
        if ($state.NeutralAtStart -and $state.Text -match $pattern) {
            throw "Root key '$Key' is written with quoted-key syntax. Refusing to add a logically duplicate key; normalize it manually first."
        }
    }
}

function Assert-NoQuotedTableEquivalent {
    param($Document, $Block, [string]$Key)
    $states = Get-TomlLineStates -Lines $Document.Lines
    $pattern = '^\s*(?:"' + [regex]::Escape($Key) + '"|''' + [regex]::Escape($Key) + ''')\s*='
    for ($i = $Block.Start + 1; $i -lt $Block.End; $i++) {
        if ($states[$i].NeutralAtStart -and $states[$i].Text -match $pattern) {
            throw "Provider key '$Key' is written with quoted-key syntax. Refusing to add a logically duplicate key; normalize it manually first."
        }
    }
}

function Get-RootEntry {
    param($Document, [string]$Key)
    $states = Get-TomlLineStates -Lines $Document.Lines
    foreach ($state in $states) {
        if ($state.IsHeader) { break }
        if ($state.NeutralAtStart) {
            $assignment = Split-TomlAssignmentLine -Line $state.Text -ExpectedKey $Key
            if ($null -ne $assignment) {
                return [pscustomobject]@{ Index = [int]$state.Index; RawValue = $assignment.RawValue; Line = $state.Text; Assignment = $assignment }
            }
        }
    }
    return $null
}

function Get-RootValue {
    param($Document, [string]$Key)
    $entry = Get-RootEntry -Document $Document -Key $Key
    if ($null -eq $entry) { return $null }
    return ConvertFrom-SimpleTomlString -RawValue $entry.RawValue
}

function Set-RootRawValue {
    param($Document, [string]$Key, [string]$RawValue)
    Assert-NoQuotedRootEquivalent -Document $Document -Key $Key
    $states = Get-TomlLineStates -Lines $Document.Lines
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $indexes = [System.Collections.Generic.List[int]]::new()
    foreach ($state in $states) {
        if ($state.IsHeader) { break }
        if ($state.NeutralAtStart -and $state.Text -match $pattern) { [void]$indexes.Add([int]$state.Index) }
    }

    $newLine = $Key + ' = ' + $RawValue
    if ($indexes.Count -gt 0) {
        $assignment = Split-TomlAssignmentLine -Line $Document.Lines[$indexes[0]] -ExpectedKey $Key
        Assert-SingleLineManagedValue -Assignment $assignment -Key $Key
        for ($i = 1; $i -lt $indexes.Count; $i++) {
            $duplicateAssignment = Split-TomlAssignmentLine -Line $Document.Lines[$indexes[$i]] -ExpectedKey $Key
            Assert-SingleLineManagedValue -Assignment $duplicateAssignment -Key $Key
        }
        if ($null -ne $assignment) { $Document.Lines[$indexes[0]] = $assignment.Prefix + $RawValue + $assignment.Suffix }
        else { $Document.Lines[$indexes[0]] = $newLine }
        for ($i = $indexes.Count - 1; $i -ge 1; $i--) { $Document.Lines.RemoveAt($indexes[$i]) }
    } else {
        $insertAt = Get-FirstTableIndex -Document $Document
        $Document.Lines.Insert($insertAt, $newLine)
    }
}

function Set-RootString {
    param($Document, [string]$Key, [string]$Value)
    Set-RootRawValue -Document $Document -Key $Key -RawValue (ConvertTo-TomlString -Value $Value)
}

function Set-RootNumber {
    param($Document, [string]$Key, [long]$Value)
    if ($Value -le 0) { throw "$Key must be greater than zero." }
    Set-RootRawValue -Document $Document -Key $Key -RawValue ([string]$Value)
}

function Remove-RootKey {
    param($Document, [string]$Key)
    Assert-NoQuotedRootEquivalent -Document $Document -Key $Key
    $states = Get-TomlLineStates -Lines $Document.Lines
    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $indexes = [System.Collections.Generic.List[int]]::new()
    foreach ($state in $states) {
        if ($state.IsHeader) { break }
        if ($state.NeutralAtStart -and $state.Text -match $pattern) {
            $assignment = Split-TomlAssignmentLine -Line $state.Text -ExpectedKey $Key
            Assert-SingleLineManagedValue -Assignment $assignment -Key $Key
            [void]$indexes.Add([int]$state.Index)
        }
    }
    for ($i = $indexes.Count - 1; $i -ge 0; $i--) { $Document.Lines.RemoveAt($indexes[$i]) }
}

function Assert-ProviderId {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id) -or $Id -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$') {
        throw 'Provider id must start with a letter and contain only ASCII letters, digits, _ or - (max 64 chars).'
    }
    if ($script:ReservedProviderIds -contains $Id.ToLowerInvariant()) {
        throw "Provider id '$Id' is reserved by Codex."
    }
}

function Assert-EnvironmentName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw 'Environment variable name must contain only ASCII letters, digits and underscores, and cannot start with a digit.'
    }
    $protectedNames = @('PATH', 'PATHEXT', 'COMSPEC', 'SYSTEMROOT', 'WINDIR', 'TEMP', 'TMP', 'USERPROFILE', 'HOME', 'CODEX_HOME', 'APPDATA', 'LOCALAPPDATA', 'PROGRAMFILES', 'USERNAME', 'COMPUTERNAME')
    if ($protectedNames -contains $Name.ToUpperInvariant()) {
        throw "Environment variable '$Name' is a protected system/tool name. Choose a dedicated API-key variable such as CODEX_PROVIDER_API_KEY."
    }
}

function Assert-BaseUrl {
    param([string]$Url)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https')) {
        throw 'Base URL must be an absolute http:// or https:// URL.'
    }
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or -not [string]::IsNullOrWhiteSpace($uri.Query) -or -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
        throw 'Base URL cannot contain credentials, query parameters or a fragment. Configure those separately in Codex.'
    }
    if ($uri.Scheme -eq 'http' -and $uri.Host -notin @('127.0.0.1', 'localhost', '::1')) {
        Write-Warning 'This provider uses unencrypted HTTP. Use HTTPS unless this is a trusted local endpoint.'
    }
}

function Get-ProviderIdFromHeader {
    param([string]$Line)
    $trimmed = $Line.Trim()
    if ($trimmed -match '^\[\s*model_providers\.(?:"([^"]+)"|''([^'']+)''|([A-Za-z][A-Za-z0-9_-]{0,63}))\s*\]\s*(?:#.*)?$') {
        foreach ($index in 1..3) {
            if (-not [string]::IsNullOrWhiteSpace($matches[$index])) { return $matches[$index] }
        }
    }
    return $null
}

function Get-ProviderBlocks {
    param($Document)
    $states = Get-TomlLineStates -Lines $Document.Lines
    $headers = @($states | Where-Object { $_.IsHeader })
    $blocks = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $id = Get-ProviderIdFromHeader -Line $headers[$i].Text
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $end = if ($i + 1 -lt $headers.Count) { [int]$headers[$i + 1].Index } else { $Document.Lines.Count }
        [void]$blocks.Add([pscustomobject]@{ Id = $id; Start = [int]$headers[$i].Index; End = $end })
    }
    return $blocks
}

function Get-ProviderBlock {
    param($Document, [string]$Id)
    foreach ($block in @(Get-ProviderBlocks -Document $Document)) {
        if ($block.Id -ieq $Id) { return $block }
    }
    return $null
}

function Get-TableEntry {
    param($Document, $Block, [string]$Key)
    $states = Get-TomlLineStates -Lines $Document.Lines
    for ($i = $Block.Start + 1; $i -lt $Block.End; $i++) {
        $state = $states[$i]
        if ($state.NeutralAtStart) {
            $assignment = Split-TomlAssignmentLine -Line $state.Text -ExpectedKey $Key
            if ($null -ne $assignment) {
                return [pscustomobject]@{ Index = $i; RawValue = $assignment.RawValue; Line = $state.Text; Assignment = $assignment }
            }
        }
    }
    return $null
}

function Set-ProviderRawValue {
    param($Document, [string]$Id, [string]$Key, [string]$RawValue)
    $block = Get-ProviderBlock -Document $Document -Id $Id
    if ($null -eq $block) { throw "Provider block not found: $Id" }
    Assert-NoQuotedTableEquivalent -Document $Document -Block $block -Key $Key
    $states = Get-TomlLineStates -Lines $Document.Lines
    $entries = [System.Collections.Generic.List[object]]::new()
    for ($i = $block.Start + 1; $i -lt $block.End; $i++) {
        if ($states[$i].NeutralAtStart) {
            $assignment = Split-TomlAssignmentLine -Line $states[$i].Text -ExpectedKey $Key
            if ($null -ne $assignment) {
                Assert-SingleLineManagedValue -Assignment $assignment -Key $Key
                [void]$entries.Add([pscustomobject]@{ Index = $i; Assignment = $assignment })
            }
        }
    }
    $line = $Key + ' = ' + $RawValue
    if ($entries.Count -gt 0) {
        $Document.Lines[$entries[0].Index] = $entries[0].Assignment.Prefix + $RawValue + $entries[0].Assignment.Suffix
        for ($i = $entries.Count - 1; $i -ge 1; $i--) { $Document.Lines.RemoveAt($entries[$i].Index) }
    } else {
        $Document.Lines.Insert($block.End, $line)
    }
}

function Remove-ProviderKey {
    param($Document, [string]$Id, [string]$Key)
    $block = Get-ProviderBlock -Document $Document -Id $Id
    if ($null -eq $block) { return }
    Assert-NoQuotedTableEquivalent -Document $Document -Block $block -Key $Key
    $states = Get-TomlLineStates -Lines $Document.Lines
    $indexes = [System.Collections.Generic.List[int]]::new()
    for ($i = $block.Start + 1; $i -lt $block.End; $i++) {
        if ($states[$i].NeutralAtStart) {
            $assignment = Split-TomlAssignmentLine -Line $states[$i].Text -ExpectedKey $Key
            if ($null -ne $assignment) {
                Assert-SingleLineManagedValue -Assignment $assignment -Key $Key
                [void]$indexes.Add($i)
            }
        }
    }
    for ($i = $indexes.Count - 1; $i -ge 0; $i--) { $Document.Lines.RemoveAt($indexes[$i]) }
}

function Test-ProviderHasCommandAuth {
    param($Document, [string]$Id)
    $escaped = [regex]::Escape($Id)
    foreach ($state in @(Get-TomlLineStates -Lines $Document.Lines)) {
        if ($state.IsHeader -and $state.Text.Trim() -match ('^\[\s*model_providers\.(?:"' + $escaped + '"|''' + $escaped + '''|' + $escaped + ')\.auth\s*\]')) {
            return $true
        }
    }
    return $false
}

function Test-ProviderHasAdvancedRequestConfig {
    param($Document, [string]$Id)
    $block = Get-ProviderBlock -Document $Document -Id $Id
    if ($null -eq $block) { return $false }
    foreach ($key in @('http_headers', 'env_http_headers', 'query_params')) {
        if ($null -ne (Get-TableEntry -Document $Document -Block $block -Key $key)) { return $true }
    }
    $escaped = [regex]::Escape($Id)
    foreach ($state in @(Get-TomlLineStates -Lines $Document.Lines)) {
        if ($state.IsHeader -and $state.Text.Trim() -match ('^\[\s*model_providers\.(?:"' + $escaped + '"|''' + $escaped + '''|' + $escaped + ')\.(?:http_headers|env_http_headers|query_params)\s*\]')) {
            return $true
        }
    }
    return $false
}

function Ensure-ProviderDefinition {
    param(
        $Document,
        [string]$Id,
        [string]$Name,
        [string]$Url,
        [string]$EnvironmentKey,
        [bool]$ProviderHasNoAuth
    )

    Assert-ProviderId -Id $Id
    Assert-BaseUrl -Url $Url
    if (-not $ProviderHasNoAuth) { Assert-EnvironmentName -Name $EnvironmentKey }
    if (Test-ProviderHasCommandAuth -Document $Document -Id $Id) {
        throw "Provider '$Id' uses command-backed auth. This tool will not overwrite that advanced auth configuration."
    }

    $block = Get-ProviderBlock -Document $Document -Id $Id
    if ($null -ne $block) {
        $legacyToken = Get-TableEntry -Document $Document -Block $block -Key 'experimental_bearer_token'
        if ($null -ne $legacyToken) {
            throw "Provider '$Id' contains a legacy inline token. Use API-key and legacy-secret tools to migrate it before updating this provider."
        }
    }
    if ($null -eq $block) {
        if ($Document.Lines.Count -gt 0 -and $Document.Lines[$Document.Lines.Count - 1].Trim().Length -gt 0) {
            [void]$Document.Lines.Add('')
        }
        [void]$Document.Lines.Add('[model_providers.' + $Id + ']')
    }

    Set-ProviderRawValue -Document $Document -Id $Id -Key 'name' -RawValue (ConvertTo-TomlString -Value $Name)
    Set-ProviderRawValue -Document $Document -Id $Id -Key 'base_url' -RawValue (ConvertTo-TomlString -Value $Url)
    Set-ProviderRawValue -Document $Document -Id $Id -Key 'wire_api' -RawValue '"responses"'
    Set-ProviderRawValue -Document $Document -Id $Id -Key 'requires_openai_auth' -RawValue 'false'
    if ($ProviderHasNoAuth) {
        Remove-ProviderKey -Document $Document -Id $Id -Key 'env_key'
    } else {
        Set-ProviderRawValue -Document $Document -Id $Id -Key 'env_key' -RawValue (ConvertTo-TomlString -Value $EnvironmentKey)
    }
}

function Protect-OutputText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $safe = $Text
    foreach ($secret in @(Get-KnownSecretValues)) {
        if (-not [string]::IsNullOrWhiteSpace($secret) -and $secret.Length -ge 4) {
            $safe = $safe.Replace($secret, '<REDACTED_SECRET>')
        }
    }
    $safe = [regex]::Replace($safe, '(?im)(experimental_bearer_token\s*=\s*)(?:"(?:\\.|[^"\\])*"|''[^'']*''|[^\s#]+)', '$1"<REDACTED>"')
    $safe = [regex]::Replace($safe, '(?i)sk-[A-Za-z0-9._-]{8,}', '<REDACTED_API_KEY>')
    $safe = [regex]::Replace($safe, '(?i)(Authorization\s*[:=]\s*Bearer\s+)[^\s"'']+', '$1<REDACTED>')
    $safe = [regex]::Replace($safe, '(?i)(https?://)[^/@\s]+@', '$1<REDACTED>@')
    $safe = [regex]::Replace($safe, '(?i)([?&](?:key|api_key|token|secret)=)[^&\s]+', '$1<REDACTED>')
    return $safe
}

function Get-KnownSecretValues {
    $values = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
        $document = Read-ConfigDocument
        foreach ($definition in @(Get-AllProviderDefinitions -Document $document)) {
            if (-not [string]::IsNullOrWhiteSpace($definition.EnvKey)) {
                foreach ($scope in @('Process', 'User', 'Machine')) {
                    $value = [Environment]::GetEnvironmentVariable($definition.EnvKey, $scope)
                    if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$values.Add($value) }
                }
            }
            if ($definition.HasInlineSecret) {
                $block = Get-ProviderBlock -Document $document -Id $definition.Id
                $entry = if ($null -ne $block) { Get-TableEntry -Document $document -Block $block -Key 'experimental_bearer_token' } else { $null }
                if ($null -ne $entry) {
                    $raw = $entry.RawValue.Trim()
                    if ($raw -match '^(?:"(?:\\.|[^"\\])*"|''[^'']*'')$') {
                        $value = ConvertFrom-SimpleTomlString -RawValue $raw
                        if (-not [string]::IsNullOrWhiteSpace($value)) { [void]$values.Add($value) }
                    }
                }
            }
        }
    } catch {
        # Redaction must remain best-effort even when the config itself is broken.
    }
    return @($values)
}

function Get-SafeUrlForDisplay {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $Url }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return '<invalid URL hidden>' }
    if ([string]::IsNullOrWhiteSpace($uri.UserInfo) -and [string]::IsNullOrWhiteSpace($uri.Query) -and [string]::IsNullOrWhiteSpace($uri.Fragment)) { return $Url }
    $builder = [UriBuilder]::new($uri)
    $builder.UserName = ''
    $builder.Password = ''
    $builder.Query = if ([string]::IsNullOrWhiteSpace($uri.Query)) { '' } else { 'REDACTED' }
    $builder.Fragment = if ([string]::IsNullOrWhiteSpace($uri.Fragment)) { '' } else { 'REDACTED' }
    return $builder.Uri.AbsoluteUri
}

function Get-CodexCommand {
    return Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Invoke-CodexWithTimeout {
    param($Command, [string[]]$Arguments, [int]$TimeoutSeconds = 30)
    $argumentJson = ConvertTo-Json -InputObject @($Arguments) -Compress
    $job = Start-Job -ScriptBlock {
        param($Source, $ArgumentsJson, $CodexHome)
        $env:CODEX_HOME = $CodexHome
        $invokeArguments = [string[]]($ArgumentsJson | ConvertFrom-Json)
        $output = & $Source @invokeArguments 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($output | Out-String).Trim()) }
    } -ArgumentList $Command.Source, $argumentJson, $script:CodexDir
    try {
        $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if ($null -eq $completed) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            throw "Codex command timed out after $TimeoutSeconds seconds."
        }
        $result = Receive-Job -Job $job -ErrorAction Stop
        return $result
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Test-CodexConfigParse {
    if ($env:CODEX_SWITCH_TEST_THROW_VALIDATION -eq '1') {
        throw 'Forced validation exception for tests.'
    }
    if ($env:CODEX_SWITCH_TEST_FAIL_VALIDATION -eq '1') {
        return [pscustomobject]@{ Success = $false; Skipped = $false; Message = 'Forced validation failure for tests.' }
    }
    if ($SkipCodexValidation) {
        return [pscustomobject]@{ Success = $true; Skipped = $true; Message = 'Codex validation skipped by request.' }
    }
    if ((Split-Path -Leaf $script:ConfigPath) -ne 'config.toml') {
        return [pscustomobject]@{ Success = $true; Skipped = $true; Message = 'Validation skipped because the file is not named config.toml.' }
    }

    $command = Get-CodexCommand
    if ($null -eq $command) {
        return [pscustomobject]@{ Success = $true; Skipped = $true; Message = 'Codex command not found; install/update Codex before using the config.' }
    }

    $helpResult = Invoke-CodexWithTimeout -Command $command -Arguments @('features', 'list', '--help') -TimeoutSeconds 15
    if ($helpResult.ExitCode -ne 0) {
        return [pscustomobject]@{ Success = $true; Skipped = $true; Message = 'Installed Codex does not support bounded offline config parsing via features list; basic safe edits were written but Codex validation was skipped.' }
    }

    $validationResult = Invoke-CodexWithTimeout -Command $command -Arguments @('features', 'list') -TimeoutSeconds 30
    if ($validationResult.ExitCode -ne 0) {
        $details = Protect-OutputText -Text $validationResult.Output
        if ($details.Length -gt 1500) { $details = $details.Substring(0, 1500) }
        return [pscustomobject]@{ Success = $false; Skipped = $false; Message = $details }
    }
    return [pscustomobject]@{ Success = $true; Skipped = $false; Message = 'Codex parsed the candidate config successfully.' }
}

function New-BackupDirectory {
    param([string]$Operation)
    if (-not (Test-Path -LiteralPath $script:BackupRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $directory = Join-Path $script:BackupRoot ($stamp + '-' + $suffix)
    New-Item -ItemType Directory -Path $directory | Out-Null
    [IO.File]::WriteAllText((Join-Path $directory 'operation.txt'), $Operation, [Text.UTF8Encoding]::new($false))
    return $directory
}

function Assert-ConfigUnchangedSinceRead {
    param($Document)
    $existsNow = Test-Path -LiteralPath $Document.Path -PathType Leaf
    if ($Document.Exists -ne $existsNow) {
        throw 'config.toml changed after it was read. No changes were written; run the operation again.'
    }
    if ($existsNow) {
        $currentHash = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($Document.Path))
        if ($currentHash -ne $Document.OriginalHash) {
            throw 'config.toml changed after it was read. No changes were written; run the operation again.'
        }
    }
}

function Save-ConfigDocument {
    param($Document, [string]$Operation)

    $newText = Get-DocumentText -Document $Document
    if ($newText -ceq $Document.OriginalText) {
        return [pscustomobject]@{ Changed = $false; BackupDirectory = $null; Validation = 'No changes required.' }
    }

    Assert-ConfigUnchangedSinceRead -Document $Document
    $configDirectory = Split-Path -Parent $Document.Path
    if (-not (Test-Path -LiteralPath $configDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    }

    $backupDirectory = New-BackupDirectory -Operation $Operation
    $backupConfig = Join-Path $backupDirectory 'config.toml'
    $tempPath = Join-Path $configDirectory ('.config.toml.cst-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $encoding = [Text.UTF8Encoding]::new([bool]$Document.HasUtf8Bom)
    $swapCompleted = $false
    $rolledBack = $false

    try {
        [IO.File]::WriteAllText($tempPath, $newText, $encoding)
        if (-not $Document.Exists) {
            [IO.File]::WriteAllText((Join-Path $backupDirectory 'config.did-not-exist.txt'), 'The config file did not exist before this operation.', [Text.UTF8Encoding]::new($false))
        }
        Assert-ConfigUnchangedSinceRead -Document $Document
        if ($Document.Exists) {
            [IO.File]::Replace($tempPath, $Document.Path, $backupConfig, $true)
        } else {
            [IO.File]::Move($tempPath, $Document.Path)
        }
        $swapCompleted = $true

        if ($Document.Exists) {
            $replacedHash = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($backupConfig))
            if ($replacedHash -ne $Document.OriginalHash) {
                [IO.File]::Copy($backupConfig, $Document.Path, $true)
                $rolledBack = $true
                throw 'config.toml changed during the final swap. The concurrent version was restored; run the operation again.'
            }
        }

        $validation = Test-CodexConfigParse
        if (-not $validation.Success) {
            throw "Candidate config failed validation. $($validation.Message)"
        }

        return [pscustomobject]@{
            Changed = $true
            BackupDirectory = $backupDirectory
            Validation = $validation.Message
        }
    } catch {
        $originalError = $_
        $rollbackError = $null
        if ($swapCompleted -and -not $rolledBack) {
            try {
                if ($Document.Exists -and (Test-Path -LiteralPath $backupConfig -PathType Leaf)) {
                    [IO.File]::Copy($backupConfig, $Document.Path, $true)
                } elseif (-not $Document.Exists -and (Test-Path -LiteralPath $Document.Path -PathType Leaf)) {
                    [IO.File]::Delete($Document.Path)
                }
                $rolledBack = $true
            } catch {
                $rollbackError = $_.Exception.Message
            }
        }
        if ($null -ne $rollbackError) {
            throw "Operation failed and rollback also failed. Original error: $($originalError.Exception.Message) Rollback error: $rollbackError"
        }
        if ($swapCompleted) { throw "Operation failed; the original config was restored. $($originalError.Exception.Message)" }
        throw $originalError
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            [IO.File]::Delete($tempPath)
        }
    }
}

function Get-ProviderDefinition {
    param($Document, [string]$Id)
    $block = Get-ProviderBlock -Document $Document -Id $Id
    if ($null -eq $block) { return $null }

    $values = [ordered]@{}
    foreach ($key in @('name', 'base_url', 'wire_api', 'env_key', 'requires_openai_auth', 'experimental_bearer_token')) {
        $entry = Get-TableEntry -Document $Document -Block $block -Key $key
        $values[$key] = if ($null -ne $entry) { ConvertFrom-SimpleTomlString -RawValue $entry.RawValue } else { $null }
    }
    return [pscustomobject]@{
        Id = $Id
        Name = $values.name
        BaseUrl = $values.base_url
        WireApi = $values.wire_api
        EnvKey = $values.env_key
        RequiresOpenAIAuth = $values.requires_openai_auth
        HasInlineSecret = -not [string]::IsNullOrWhiteSpace($values.experimental_bearer_token)
        HasCommandAuth = Test-ProviderHasCommandAuth -Document $Document -Id $Id
        HasAdvancedRequestConfig = Test-ProviderHasAdvancedRequestConfig -Document $Document -Id $Id
    }
}

function Get-AllProviderDefinitions {
    param($Document)
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($block in @(Get-ProviderBlocks -Document $Document)) {
        $definition = Get-ProviderDefinition -Document $Document -Id $block.Id
        if ($null -ne $definition) { [void]$result.Add($definition) }
    }
    return $result
}

function Get-EnvironmentStatus {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return [pscustomobject]@{ Name = $null; Process = $false; User = $false; Machine = $false; Any = $false }
    }
    $processPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name, 'Process'))
    $userPresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name, 'User'))
    $machinePresent = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name, 'Machine'))
    return [pscustomobject]@{ Name = $Name; Process = $processPresent; User = $userPresent; Machine = $machinePresent; Any = ($processPresent -or $userPresent -or $machinePresent) }
}

function Get-ContextMarker {
    param($Document)
    $firstTable = Get-FirstTableIndex -Document $Document
    $states = Get-TomlLineStates -Lines $Document.Lines
    for ($i = 0; $i -lt $firstTable; $i++) {
        if ($states[$i].NeutralAtStart -and $Document.Lines[$i] -match $script:ContextMarkerPattern) {
            return [pscustomobject]@{ Index = $i; PreviousWindow = $matches[1]; PreviousCompact = $matches[2] }
        }
    }
    return $null
}

function Remove-ContextMarkers {
    param($Document)
    $firstTable = Get-FirstTableIndex -Document $Document
    $states = Get-TomlLineStates -Lines $Document.Lines
    $indexes = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $firstTable; $i++) {
        if ($states[$i].NeutralAtStart -and $Document.Lines[$i] -match $script:ContextMarkerPattern) { [void]$indexes.Add($i) }
    }
    for ($i = $indexes.Count - 1; $i -ge 0; $i--) { $Document.Lines.RemoveAt($indexes[$i]) }
}

function Enable-ManagedContext {
    param($Document, [long]$Window, [long]$Compact)
    if ($Window -le 0 -or $Compact -le 0 -or $Compact -ge $Window) {
        throw 'Context window must be positive, and auto-compact limit must be positive and smaller than the context window.'
    }

    $marker = Get-ContextMarker -Document $Document
    if ($null -eq $marker) {
        $windowEntry = Get-RootEntry -Document $Document -Key 'model_context_window'
        $compactEntry = Get-RootEntry -Document $Document -Key 'model_auto_compact_token_limit'
        $previousWindow = if ($null -eq $windowEntry) { 'absent' } else { $windowEntry.RawValue.Trim() }
        $previousCompact = if ($null -eq $compactEntry) { 'absent' } else { $compactEntry.RawValue.Trim() }
        if ($previousWindow -ne 'absent' -and $previousWindow.Replace('_', '') -notmatch '^\d+$') { throw 'Existing model_context_window is not a simple number; refusing to overwrite it.' }
        if ($previousCompact -ne 'absent' -and $previousCompact.Replace('_', '') -notmatch '^\d+$') { throw 'Existing model_auto_compact_token_limit is not a simple number; refusing to overwrite it.' }
        $markerLine = '# CST_CONTEXT_V1 previous_window=' + $previousWindow + ' previous_compact=' + $previousCompact
        $Document.Lines.Insert((Get-FirstTableIndex -Document $Document), $markerLine)
    }

    Set-RootNumber -Document $Document -Key 'model_context_window' -Value $Window
    Set-RootNumber -Document $Document -Key 'model_auto_compact_token_limit' -Value $Compact
}

function Reset-ManagedContext {
    param($Document, [bool]$AllowUnmanagedRemoval = $false)
    $marker = Get-ContextMarker -Document $Document
    if ($null -ne $marker) {
        if ($marker.PreviousWindow -eq 'absent') { Remove-RootKey -Document $Document -Key 'model_context_window' }
        else { Set-RootRawValue -Document $Document -Key 'model_context_window' -RawValue $marker.PreviousWindow }
        if ($marker.PreviousCompact -eq 'absent') { Remove-RootKey -Document $Document -Key 'model_auto_compact_token_limit' }
        else { Set-RootRawValue -Document $Document -Key 'model_auto_compact_token_limit' -RawValue $marker.PreviousCompact }
        Remove-ContextMarkers -Document $Document
    } else {
        $hasWindow = $null -ne (Get-RootEntry -Document $Document -Key 'model_context_window')
        $hasCompact = $null -ne (Get-RootEntry -Document $Document -Key 'model_auto_compact_token_limit')
        if (-not $hasWindow -and -not $hasCompact) { return }
        if (-not $AllowUnmanagedRemoval) {
            throw 'Context overrides are not owned by Codex Switch Tools. Refusing to remove them without explicit confirmation/ForceRemoveUnmanagedContext.'
        }
        Remove-RootKey -Document $Document -Key 'model_context_window'
        Remove-RootKey -Document $Document -Key 'model_auto_compact_token_limit'
    }
}

function Get-CodexCatalogEntry {
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return $null }
    $command = Get-CodexCommand
    if ($null -eq $command) { return $null }
    try {
        $result = Invoke-CodexWithTimeout -Command $command -Arguments @('debug', 'models', '--bundled') -TimeoutSeconds 30
        $raw = $result.Output
        if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
        $catalog = $raw | ConvertFrom-Json
        $items = if ($catalog -is [Array]) { @($catalog) } elseif ($null -ne $catalog.models) { @($catalog.models) } else { @($catalog) }
        return @($items | Where-Object { $_.slug -eq $ModelId -or $_.id -eq $ModelId -or $_.model -eq $ModelId } | Select-Object -First 1)
    } catch {
        return $null
    }
}

function Get-RecommendedLongContext {
    param($Document)
    if (-not [string]::IsNullOrWhiteSpace((Get-RootValue -Document $Document -Key 'model_catalog_json'))) {
        return $null
    }
    $providerId = Get-RootValue -Document $Document -Key 'model_provider'
    if (-not [string]::IsNullOrWhiteSpace($providerId) -and $providerId -ne 'openai') {
        return $null
    }
    $modelId = Get-RootValue -Document $Document -Key 'model'
    $entryArray = @(Get-CodexCatalogEntry -ModelId $modelId)
    if ($entryArray.Count -eq 0 -or $null -eq $entryArray[0].max_context_window) { return $null }
    $maximum = [long]$entryArray[0].max_context_window
    $catalogDefault = if ($null -ne $entryArray[0].context_window) { [long]$entryArray[0].context_window } else { 0L }
    if ($maximum -le 0 -or $maximum -le $catalogDefault) { return $null }
    $compact = if ($maximum -eq 872000) { 800000 } else { [long]([Math]::Floor(($maximum * 0.90) / 1000) * 1000) }
    if ($compact -le 0 -or $compact -ge $maximum) { return $null }
    return [pscustomobject]@{ Model = $modelId; Window = $maximum; Compact = $compact; CatalogDefault = $catalogDefault }
}

function Get-StatusObject {
    $document = Read-ConfigDocument
    $provider = Get-RootValue -Document $document -Key 'model_provider'
    if ([string]::IsNullOrWhiteSpace($provider)) { $provider = 'openai' }
    $modelId = Get-RootValue -Document $document -Key 'model'
    $effort = Get-RootValue -Document $document -Key 'model_reasoning_effort'
    $context = Get-RootValue -Document $document -Key 'model_context_window'
    $compact = Get-RootValue -Document $document -Key 'model_auto_compact_token_limit'
    $catalogPath = Get-RootValue -Document $document -Key 'model_catalog_json'
    $forcedLogin = Get-RootValue -Document $document -Key 'forced_login_method'
    $preferredAuth = Get-RootValue -Document $document -Key 'preferred_auth_method'
    $marker = Get-ContextMarker -Document $document

    $providerItems = [System.Collections.Generic.List[object]]::new()
    foreach ($definition in @(Get-AllProviderDefinitions -Document $document)) {
        $envStatus = Get-EnvironmentStatus -Name $definition.EnvKey
        [void]$providerItems.Add([pscustomobject]@{
            Id = $definition.Id
            Name = $definition.Name
            BaseUrl = Get-SafeUrlForDisplay -Url $definition.BaseUrl
            WireApi = $definition.WireApi
            EnvKey = $definition.EnvKey
            EnvKeyPresent = $envStatus.Any
            HasInlineSecret = $definition.HasInlineSecret
            HasCommandAuth = $definition.HasCommandAuth
            HasAdvancedRequestConfig = $definition.HasAdvancedRequestConfig
        })
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $activeDefinition = if ($provider -eq 'openai') { $null } else { Get-ProviderDefinition -Document $document -Id $provider }
    if ($provider -ne 'openai' -and $null -eq $activeDefinition) {
        [void]$warnings.Add("Active provider '$provider' has no matching [model_providers.$provider] block.")
    }
    if ($null -ne $activeDefinition) {
        if ($activeDefinition.WireApi -ne 'responses') { [void]$warnings.Add('The active custom provider is not explicitly configured for the Responses API.') }
        if ($activeDefinition.HasInlineSecret) { [void]$warnings.Add('The active provider stores a legacy inline bearer token in config.toml. Use the migration tool.') }
        if ($activeDefinition.HasAdvancedRequestConfig) { [void]$warnings.Add('The active provider uses advanced headers/query parameters. The direct probe intentionally does not emulate them.') }
        if (-not [string]::IsNullOrWhiteSpace($activeDefinition.EnvKey)) {
            $envStatus = Get-EnvironmentStatus -Name $activeDefinition.EnvKey
            if (-not $envStatus.Any) { [void]$warnings.Add("API-key environment variable '$($activeDefinition.EnvKey)' is missing.") }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($catalogPath)) {
        [void]$warnings.Add('model_catalog_json is set. It may override the native model catalog; this tool leaves it untouched.')
    }

    $codexCommand = Get-CodexCommand
    $codexVersion = $null
    $codexPath = $null
    if ($null -ne $codexCommand) {
        $codexPath = $codexCommand.Source
        try { $codexVersion = ((& $codexCommand.Source --version 2>$null | Out-String).Trim()) } catch { $codexVersion = 'unknown' }
    }

    return [pscustomobject]@{
        ToolVersion = $script:ToolVersion
        ConfigPath = $script:ConfigPath
        ConfigExists = $document.Exists
        CodexCommand = $codexPath
        CodexVersion = $codexVersion
        ExpectedProvider = $provider
        RequestedModel = if ([string]::IsNullOrWhiteSpace($modelId)) { $null } else { $modelId }
        ReasoningEffort = if ([string]::IsNullOrWhiteSpace($effort)) { $null } else { $effort }
        ContextWindow = if ([string]::IsNullOrWhiteSpace($context)) { $null } else { $context }
        AutoCompactLimit = if ([string]::IsNullOrWhiteSpace($compact)) { $null } else { $compact }
        ContextManagedByTool = $null -ne $marker
        ForcedLoginMethod = $forcedLogin
        PreferredAuthMethod = $preferredAuth
        Providers = $providerItems
        Warnings = $warnings
        ScopeNote = 'These are persistent user settings expected on the next Codex start. Project config, CLI flags, UI choices, or a backend model alias may still override them.'
    }
}

function Show-Status {
    $status = Get-StatusObject
    if ($Json) {
        Write-Output ($status | ConvertTo-Json -Depth 7)
        return
    }

    Write-Heading 'Codex persistent expected-settings diagnostics'
    Write-Host ('Config path       : ' + $status.ConfigPath)
    Write-Host ('Config exists     : ' + $status.ConfigExists)
    Write-Host ('Codex command     : ' + $(if ($status.CodexCommand) { $status.CodexCommand } else { '<not found>' }))
    Write-Host ('Codex version     : ' + $(if ($status.CodexVersion) { $status.CodexVersion } else { '<not found>' }))
    Write-Host ('Expected provider : ' + $status.ExpectedProvider) -ForegroundColor Green
    Write-Host ('Requested model   : ' + $(if ($status.RequestedModel) { $status.RequestedModel } else { '<UI/native default>' })) -ForegroundColor Green
    Write-Host ('Reasoning effort  : ' + $(if ($status.ReasoningEffort) { $status.ReasoningEffort } else { '<model default>' }))
    Write-Host ('Context window    : ' + $(if ($status.ContextWindow) { $status.ContextWindow } else { '<model default>' }))
    Write-Host ('Auto compact      : ' + $(if ($status.AutoCompactLimit) { $status.AutoCompactLimit } else { '<model default>' }))
    Write-Host ('Managed context   : ' + $status.ContextManagedByTool)
    Write-Host ('Forced login      : ' + $(if ($status.ForcedLoginMethod) { $status.ForcedLoginMethod } else { '<not forced>' }))
    Write-Host ('Preferred auth    : ' + $(if ($status.PreferredAuthMethod) { $status.PreferredAuthMethod } else { '<Codex default>' }))
    Write-Host ''
    Write-Host 'Custom providers:' -ForegroundColor Cyan
    if ($status.Providers.Count -eq 0) {
        Write-Host '  <none>'
    } else {
        foreach ($item in $status.Providers) {
            $keyState = if ([string]::IsNullOrWhiteSpace($item.EnvKey)) { 'no env key' } elseif ($item.EnvKeyPresent) { $item.EnvKey + ' present' } else { $item.EnvKey + ' MISSING' }
            Write-Host ("  {0} | {1} | {2} | {3}" -f $item.Id, $item.BaseUrl, $item.WireApi, $keyState)
            if ($item.HasInlineSecret) { Write-Host '    WARNING: legacy inline bearer token detected (value hidden).' -ForegroundColor Yellow }
        }
    }
    if ($status.Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host 'Warnings:' -ForegroundColor Yellow
        foreach ($warning in $status.Warnings) { Write-Host ('  - ' + $warning) -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host $status.ScopeNote -ForegroundColor DarkYellow
}

function Assert-ReasoningEffort {
    param([string]$Effort)
    if ([string]::IsNullOrWhiteSpace($Effort)) { return }
    $allowed = @('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')
    if ($allowed -notcontains $Effort.ToLowerInvariant()) {
        throw ('Unsupported reasoning-effort value. Choose one of: ' + ($allowed -join ', ') + ', or leave it blank.')
    }
}

function Assert-ModelId {
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { throw 'A model id is required for a custom provider.' }
    if ($ModelId.Length -gt 256 -or $ModelId -match '[\x00-\x1F\x7F]') {
        throw 'Model id must be 256 characters or fewer and cannot contain control characters.'
    }
}

function Show-SaveResult {
    param($Result)
    if ($Result.Changed) {
        Write-Host '[OK] Configuration updated.' -ForegroundColor Green
        Write-Host ('Backup    : ' + $Result.BackupDirectory)
        Write-Host ('Validation: ' + $Result.Validation)
        Write-Host 'Fully quit and reopen Codex / VS Code before testing the new settings.' -ForegroundColor Yellow
    } else {
        Write-Host '[OK] No configuration changes were required.' -ForegroundColor Green
    }
}

function Invoke-ConfigureProviderOperation {
    param([string]$Id, [string]$Name, [string]$Url, [string]$EnvironmentKey, [bool]$ProviderHasNoAuth)
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $Id }
    $document = Read-ConfigDocument
    Ensure-ProviderDefinition -Document $document -Id $Id -Name $Name -Url $Url -EnvironmentKey $EnvironmentKey -ProviderHasNoAuth $ProviderHasNoAuth
    $result = Save-ConfigDocument -Document $document -Operation ('Configure provider ' + $Id)
    Show-SaveResult -Result $result
}

function Invoke-SetProviderOperation {
    param([string]$Id, [string]$ModelId, [string]$Effort)
    Assert-ProviderId -Id $Id
    Assert-ModelId -ModelId $ModelId
    Assert-ReasoningEffort -Effort $Effort
    $document = Read-ConfigDocument
    $definition = Get-ProviderDefinition -Document $document -Id $Id
    if ($null -eq $definition) { throw "Provider '$Id' is not configured. Add/update it first." }

    Set-RootString -Document $document -Key 'model_provider' -Value $Id
    Set-RootString -Document $document -Key 'model' -Value $ModelId
    if ([string]::IsNullOrWhiteSpace($Effort)) { Remove-RootKey -Document $document -Key 'model_reasoning_effort' }
    else { Set-RootString -Document $document -Key 'model_reasoning_effort' -Value $Effort.ToLowerInvariant() }

    $result = Save-ConfigDocument -Document $document -Operation ('Switch provider to ' + $Id + ' model ' + $ModelId)
    Show-SaveResult -Result $result
    if (-not [string]::IsNullOrWhiteSpace($definition.EnvKey) -and -not (Get-EnvironmentStatus -Name $definition.EnvKey).Any) {
        Write-Warning "Provider API-key variable '$($definition.EnvKey)' is missing. Use the API-key menu before launching Codex."
    }
    $contextOverride = Get-RootValue -Document $document -Key 'model_context_window'
    if (-not [string]::IsNullOrWhiteSpace($contextOverride)) {
        Write-Warning "Context override $contextOverride was preserved. Verify that provider '$Id' supports it, or use the context menu to restore/default it."
    }
}

function Invoke-UseOpenAIOperation {
    $document = Read-ConfigDocument
    Set-RootString -Document $document -Key 'model_provider' -Value 'openai'
    Remove-RootKey -Document $document -Key 'model'
    Remove-RootKey -Document $document -Key 'model_reasoning_effort'
    $result = Save-ConfigDocument -Document $document -Operation 'Switch to built-in OpenAI provider'
    Show-SaveResult -Result $result
    Write-Host 'Custom provider blocks, context settings, login/auth preferences and API-key variables were preserved.' -ForegroundColor Cyan
    Write-Host 'This selects the built-in OpenAI provider; it does not change whether your existing auth method is ChatGPT login or an API key.' -ForegroundColor Yellow
}

function Invoke-SetContextOperation {
    param([long]$Window, [long]$Compact)
    $document = Read-ConfigDocument
    Enable-ManagedContext -Document $document -Window $Window -Compact $Compact
    $result = Save-ConfigDocument -Document $document -Operation ("Set managed context window=$Window compact=$Compact")
    Show-SaveResult -Result $result
}

function Invoke-ResetContextOperation {
    param([bool]$AllowUnmanagedRemoval = $false)
    $document = Read-ConfigDocument
    Reset-ManagedContext -Document $document -AllowUnmanagedRemoval $AllowUnmanagedRemoval
    $result = Save-ConfigDocument -Document $document -Operation 'Restore previous/model-default context settings'
    Show-SaveResult -Result $result
}

function Invoke-ToggleLongContextOperation {
    $document = Read-ConfigDocument
    $marker = Get-ContextMarker -Document $document
    if ($null -ne $marker) {
        Reset-ManagedContext -Document $document
        $result = Save-ConfigDocument -Document $document -Operation 'Disable managed long context and restore prior values'
        Show-SaveResult -Result $result
        return
    }

    $currentWindow = Get-RootValue -Document $document -Key 'model_context_window'
    $currentCompact = Get-RootValue -Document $document -Key 'model_auto_compact_token_limit'
    if ($currentWindow -eq '872000' -and $currentCompact -eq '800000') {
        if (-not $ForceRemoveUnmanagedContext) {
            throw 'The 872K/800K override has no tool ownership marker. Use -ForceRemoveUnmanagedContext or the interactive context menu to remove it explicitly.'
        }
        Remove-RootKey -Document $document -Key 'model_context_window'
        Remove-RootKey -Document $document -Key 'model_auto_compact_token_limit'
        $result = Save-ConfigDocument -Document $document -Operation 'Disable legacy 872K/800K context override'
        Show-SaveResult -Result $result
        return
    }

    $recommendation = Get-RecommendedLongContext -Document $document
    if ($null -eq $recommendation) {
        throw 'A safe long-context maximum could not be detected for this provider/model. Use SetContext or the interactive legacy/custom options explicitly.'
    }
    $window = [long]$recommendation.Window
    $compact = [long]$recommendation.Compact
    Enable-ManagedContext -Document $document -Window $window -Compact $compact
    $result = Save-ConfigDocument -Document $document -Operation ("Enable long context window=$window compact=$compact")
    Show-SaveResult -Result $result
}

function Read-SecretValue {
    param([string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ([string]::IsNullOrWhiteSpace($plain)) { throw 'API key cannot be empty.' }
        return $plain
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Save-ApiKeyInteractive {
    param([string]$Name, [string]$Target = 'User')
    Assert-EnvironmentName -Name $Name
    Write-Host 'The key is hidden while typing. User-scope environment variables are stored by Windows for this account.' -ForegroundColor Yellow
    $plain = Read-SecretValue -Prompt ('Paste API key for ' + $Name)
    $previousTarget = [Environment]::GetEnvironmentVariable($Name, $Target)
    $previousProcess = [Environment]::GetEnvironmentVariable($Name, 'Process')
    try {
        [Environment]::SetEnvironmentVariable($Name, $plain, $Target)
        [Environment]::SetEnvironmentVariable($Name, $plain, 'Process')
    } catch {
        [Environment]::SetEnvironmentVariable($Name, $previousTarget, $Target)
        [Environment]::SetEnvironmentVariable($Name, $previousProcess, 'Process')
        throw
    } finally {
        Remove-Variable plain -ErrorAction SilentlyContinue
        Remove-Variable previousTarget -ErrorAction SilentlyContinue
        Remove-Variable previousProcess -ErrorAction SilentlyContinue
    }
    Write-Host ('[OK] Saved ' + $Name + ' at ' + $Target + ' scope (value hidden).') -ForegroundColor Green
    Write-Host 'Restart Codex / VS Code so the new process inherits it.' -ForegroundColor Yellow
}

function Invoke-MigrateLegacySecretOperation {
    param([string]$Id, [string]$EnvironmentKey, [string]$Target, [bool]$AllowEnvironmentOverwrite = $false)
    Assert-ProviderId -Id $Id
    if ([string]::IsNullOrWhiteSpace($EnvironmentKey)) {
        $EnvironmentKey = ('CODEX_' + ($Id.ToUpperInvariant() -replace '[^A-Z0-9_]', '_') + '_API_KEY')
    }
    Assert-EnvironmentName -Name $EnvironmentKey
    $document = Read-ConfigDocument
    if (Test-ProviderHasCommandAuth -Document $document -Id $Id) { throw 'Cannot migrate a provider that also has command-backed auth.' }
    $block = Get-ProviderBlock -Document $document -Id $Id
    if ($null -eq $block) { throw "Provider '$Id' is not configured." }
    $entry = Get-TableEntry -Document $document -Block $block -Key 'experimental_bearer_token'
    if ($null -eq $entry) { throw "Provider '$Id' has no inline experimental_bearer_token to migrate." }
    $rawToken = $entry.RawValue.Trim()
    if ($rawToken -notmatch '^(?:"(?:\\.|[^"\\])*"|''[^'']*'')$') {
        throw 'The inline token is not a supported single-line TOML string; refusing to migrate a malformed value.'
    }
    if ($rawToken.StartsWith('"')) {
        $innerToken = $rawToken.Substring(1, $rawToken.Length - 2)
        if ($innerToken -match '\\(?!["\\])') {
            throw 'The inline token uses TOML escape sequences other than \\ or \". Refusing a potentially lossy migration.'
        }
    }
    $plain = ConvertFrom-SimpleTomlString -RawValue $entry.RawValue
    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'The inline token is empty or unsupported.' }

    $previous = [Environment]::GetEnvironmentVariable($EnvironmentKey, $Target)
    $previousProcess = [Environment]::GetEnvironmentVariable($EnvironmentKey, 'Process')
    if (-not [string]::IsNullOrWhiteSpace($previous) -and $previous -cne $plain -and -not $AllowEnvironmentOverwrite) {
        Remove-Variable plain -ErrorAction SilentlyContinue
        throw "Environment variable '$EnvironmentKey' already contains a different value. Refusing to overwrite it without explicit confirmation."
    }
    try {
        [Environment]::SetEnvironmentVariable($EnvironmentKey, $plain, $Target)
        [Environment]::SetEnvironmentVariable($EnvironmentKey, $plain, 'Process')
        Set-ProviderRawValue -Document $document -Id $Id -Key 'env_key' -RawValue (ConvertTo-TomlString -Value $EnvironmentKey)
        Remove-ProviderKey -Document $document -Id $Id -Key 'experimental_bearer_token'
        $result = Save-ConfigDocument -Document $document -Operation ('Migrate inline token for provider ' + $Id + ' to environment variable ' + $EnvironmentKey)
        Show-SaveResult -Result $result
    } catch {
        [Environment]::SetEnvironmentVariable($EnvironmentKey, $previous, $Target)
        [Environment]::SetEnvironmentVariable($EnvironmentKey, $previousProcess, 'Process')
        throw
    } finally {
        Remove-Variable plain -ErrorAction SilentlyContinue
        Remove-Variable previous -ErrorAction SilentlyContinue
        Remove-Variable previousProcess -ErrorAction SilentlyContinue
    }
    Write-Host ('[OK] Inline token removed from live config and stored as ' + $EnvironmentKey + ' (value hidden).') -ForegroundColor Green
    Write-Host 'Note: the safety backup is an exact copy of the old config and can still contain the legacy inline token.' -ForegroundColor Yellow
}

function Get-BackupRecords {
    $records = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $script:BackupRoot -PathType Container)) { return $records }
    foreach ($directory in @(Get-ChildItem -LiteralPath $script:BackupRoot -Directory | Sort-Object Name -Descending)) {
        $configFile = Join-Path $directory.FullName 'config.toml'
        if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { continue }
        $operationFile = Join-Path $directory.FullName 'operation.txt'
        $operation = if (Test-Path -LiteralPath $operationFile -PathType Leaf) { [IO.File]::ReadAllText($operationFile).Trim() } else { '<unknown operation>' }
        $backupText = [IO.File]::ReadAllText($configFile, [Text.UTF8Encoding]::new($false, $true))
        $containsInlineSecret = $backupText -match '(?m)^\s*experimental_bearer_token\s*='
        [void]$records.Add([pscustomobject]@{
            Name = $directory.Name
            Directory = $directory.FullName
            ConfigFile = $configFile
            Operation = $operation
            ContainsLegacyInlineSecret = $containsInlineSecret
        })
    }
    return $records
}

function Restore-BackupRecord {
    param($Record)
    if ($null -eq $Record -or -not (Test-Path -LiteralPath $Record.ConfigFile -PathType Leaf)) { throw 'Selected backup is missing.' }
    $document = Read-ConfigDocument
    Assert-ConfigUnchangedSinceRead -Document $document
    $backupBytes = [IO.File]::ReadAllBytes($Record.ConfigFile)
    $decoder = [Text.UTF8Encoding]::new($false, $true)
    $offset = if ($backupBytes.Length -ge 3 -and $backupBytes[0] -eq 0xEF -and $backupBytes[1] -eq 0xBB -and $backupBytes[2] -eq 0xBF) { 3 } else { 0 }
    try { if ($backupBytes.Length -gt $offset) { [void]$decoder.GetString($backupBytes, $offset, $backupBytes.Length - $offset) } } catch { throw 'Selected backup is not valid UTF-8.' }

    $configDirectory = Split-Path -Parent $document.Path
    if (-not (Test-Path -LiteralPath $configDirectory -PathType Container)) { New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null }
    $safetyDirectory = New-BackupDirectory -Operation ('Before restoring backup ' + $Record.Name)
    $safetyConfig = Join-Path $safetyDirectory 'config.toml'
    $tempPath = Join-Path $configDirectory ('.config.toml.cst-restore-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $swapCompleted = $false
    $rolledBack = $false
    try {
        [IO.File]::WriteAllBytes($tempPath, $backupBytes)
        if (-not $document.Exists) {
            [IO.File]::WriteAllText((Join-Path $safetyDirectory 'config.did-not-exist.txt'), 'The config file did not exist before this restore.', [Text.UTF8Encoding]::new($false))
        }
        Assert-ConfigUnchangedSinceRead -Document $document
        if ($document.Exists) { [IO.File]::Replace($tempPath, $document.Path, $safetyConfig, $true) }
        else { [IO.File]::Move($tempPath, $document.Path) }
        $swapCompleted = $true

        if ($document.Exists) {
            $replacedHash = Get-Sha256Hex -Bytes ([IO.File]::ReadAllBytes($safetyConfig))
            if ($replacedHash -ne $document.OriginalHash) {
                [IO.File]::Copy($safetyConfig, $document.Path, $true)
                $rolledBack = $true
                throw 'config.toml changed during the final restore swap. The concurrent version was restored.'
            }
        }

        $validation = Test-CodexConfigParse
        if (-not $validation.Success) {
            throw "Restored config failed validation. $($validation.Message)"
        }
        Write-Host ('[OK] Restored backup: ' + $Record.Directory) -ForegroundColor Green
        Write-Host ('Safety backup of previous live config: ' + $safetyDirectory)
        Write-Host 'Fully quit and reopen Codex / VS Code.' -ForegroundColor Yellow
    } catch {
        $originalError = $_
        $rollbackError = $null
        if ($swapCompleted -and -not $rolledBack) {
            try {
                if ($document.Exists -and (Test-Path -LiteralPath $safetyConfig -PathType Leaf)) { [IO.File]::Copy($safetyConfig, $document.Path, $true) }
                elseif (-not $document.Exists -and (Test-Path -LiteralPath $document.Path -PathType Leaf)) { [IO.File]::Delete($document.Path) }
                $rolledBack = $true
            } catch {
                $rollbackError = $_.Exception.Message
            }
        }
        if ($null -ne $rollbackError) {
            throw "Restore failed and rollback also failed. Original error: $($originalError.Exception.Message) Rollback error: $rollbackError"
        }
        if ($swapCompleted) { throw "Restore failed; the pre-restore config was put back. $($originalError.Exception.Message)" }
        throw $originalError
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) { [IO.File]::Delete($tempPath) }
    }
}

function Install-DesktopShortcut {
    $batPath = Join-Path $PSScriptRoot 'Codex-Switch-Tools.bat'
    if (-not (Test-Path -LiteralPath $batPath -PathType Leaf)) { throw "Launcher not found: $batPath" }
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop -PathType Container)) { throw 'Cannot resolve the desktop directory.' }
    $shortcutPath = Join-Path $desktop 'Codex Switch Tools.lnk'
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $batPath
        $shortcut.WorkingDirectory = $PSScriptRoot
        $shortcut.Description = 'Switch Codex provider, model and context settings'
        $shortcut.IconLocation = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') + ',0'
        $shortcut.WindowStyle = 1
        $shortcut.Save()
    } finally {
        if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    }
    Write-Host ('[OK] Desktop shortcut created/updated: ' + $shortcutPath) -ForegroundColor Green
}

function Invoke-LiveProbe {
    param([bool]$Confirmed = $false)
    $status = Get-StatusObject
    Write-Heading 'Optional direct Responses API connectivity probe'
    Write-Host ('Expected provider: ' + $status.ExpectedProvider)
    Write-Host ('Requested model  : ' + $(if ($status.RequestedModel) { $status.RequestedModel } else { '<UI/native default>' }))
    Write-Host 'This sends one tiny direct Responses API request. It may be billable.' -ForegroundColor Yellow
    Write-Host 'It sends tools=[] and never runs Codex agent tools, MCP servers, hooks or project instructions.' -ForegroundColor Yellow
    Write-Host 'Success confirms endpoint/key/model compatibility, but cannot prove that the provider did not remap a model alias.' -ForegroundColor Yellow
    if (-not $Confirmed) {
        $confirm = Read-Host 'Type PROBE to continue'
        if ($confirm -cne 'PROBE') { Write-Host 'Cancelled.'; return }
    }

    if ($status.ExpectedProvider -eq 'openai') {
        throw 'Direct probe is only available for custom env_key/no-auth providers. Official ChatGPT login uses Codex-managed authentication.'
    }
    if ([string]::IsNullOrWhiteSpace($status.RequestedModel)) { throw 'A requested model id is required before probing a custom provider.' }
    $document = Read-ConfigDocument
    $definition = Get-ProviderDefinition -Document $document -Id $status.ExpectedProvider
    if ($null -eq $definition) { throw 'The active custom provider definition is missing.' }
    if (-not [string]::IsNullOrWhiteSpace($definition.WireApi) -and $definition.WireApi -ne 'responses') { throw 'Direct probe only supports Responses API providers.' }
    if ($definition.HasInlineSecret) { throw 'Migrate the legacy inline token before probing.' }
    if ($definition.HasCommandAuth -or $definition.RequiresOpenAIAuth -eq 'true') { throw 'Direct probe does not support command-backed or OpenAI-managed authentication.' }
    if ($definition.HasAdvancedRequestConfig) { throw 'Direct probe does not emulate custom http_headers, env_http_headers or query_params. Test this advanced provider through its own documented client.' }
    Assert-BaseUrl -Url $definition.BaseUrl

    $apiKey = $null
    if (-not [string]::IsNullOrWhiteSpace($definition.EnvKey)) {
        foreach ($scope in @('Process', 'User', 'Machine')) {
            $apiKey = [Environment]::GetEnvironmentVariable($definition.EnvKey, $scope)
            if (-not [string]::IsNullOrWhiteSpace($apiKey)) { break }
        }
        if ([string]::IsNullOrWhiteSpace($apiKey)) { throw "API-key environment variable '$($definition.EnvKey)' is missing." }
    }

    $endpoint = $definition.BaseUrl.TrimEnd('/')
    if (-not $endpoint.EndsWith('/responses', [StringComparison]::OrdinalIgnoreCase)) { $endpoint += '/responses' }
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    $request = $null
    $response = $null
    $cancellation = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
    try {
        $payload = [ordered]@{
            model = $status.RequestedModel
            input = 'Reply with exactly CODEX_SWITCH_OK.'
            max_output_tokens = 16
            stream = $false
            tools = @()
        } | ConvertTo-Json -Depth 4 -Compress
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $endpoint)
        $request.Content = [Net.Http.StringContent]::new($payload, [Text.Encoding]::UTF8, 'application/json')
        if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
            $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $apiKey)
        }
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $memory = [IO.MemoryStream]::new()
        $buffer = [byte[]]::new(4096)
        $limit = 65536
        $truncated = $false
        try {
            while ($memory.Length -lt $limit) {
                $remaining = [int][Math]::Min($buffer.Length, $limit - $memory.Length)
                $read = $stream.ReadAsync($buffer, 0, $remaining, $cancellation.Token).GetAwaiter().GetResult()
                if ($read -le 0) { break }
                $memory.Write($buffer, 0, $read)
            }
            if ($memory.Length -ge $limit) { $truncated = $true }
            $body = [Text.Encoding]::UTF8.GetString($memory.ToArray())
        } finally {
            $memory.Dispose()
            $stream.Dispose()
        }
        $safeBody = Protect-OutputText -Text $body
        $safeBody = [regex]::Replace($safeBody, '\x1B\[[0-?]*[ -/]*[@-~]', '')
        $safeBody = [regex]::Replace($safeBody, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '?')
        if ($safeBody.Length -gt 5000) { $safeBody = $safeBody.Substring(0, 5000) }
        Write-Host ('HTTP status code: ' + [int]$response.StatusCode)
        if ($truncated) { Write-Host 'Response body exceeded 64 KiB and was truncated before display.' -ForegroundColor Yellow }
        if (-not [string]::IsNullOrWhiteSpace($safeBody)) { Write-Host $safeBody }
        $responseShapeValid = $false
        if ($response.IsSuccessStatusCode -and -not $truncated) {
            try {
                $responseJson = $body | ConvertFrom-Json
                $responseShapeValid = $null -ne $responseJson.id -or $responseJson.object -eq 'response' -or $null -ne $responseJson.output
            } catch {
                $responseShapeValid = $false
            }
        }
        if ($response.IsSuccessStatusCode -and $responseShapeValid) {
            Write-Host '[OK] Direct Responses API probe completed with a response-shaped JSON body.' -ForegroundColor Green
        } elseif ($response.IsSuccessStatusCode) {
            throw 'HTTP succeeded, but the body was not recognized as a non-streaming Responses object.'
        } else {
            throw ('The provider returned non-success HTTP status ' + [int]$response.StatusCode + '.')
        }
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        $cancellation.Dispose()
        $client.Dispose()
        $handler.Dispose()
        Remove-Variable apiKey -ErrorAction SilentlyContinue
    }
}

function Read-ProviderSelection {
    param($Document)
    $providers = @(Get-AllProviderDefinitions -Document $Document)
    if ($providers.Count -eq 0) { Write-Host 'No custom providers are configured.' -ForegroundColor Yellow; return $null }
    for ($i = 0; $i -lt $providers.Count; $i++) {
        Write-Host (" {0}. {1} | {2} | {3}" -f ($i + 1), $providers[$i].Id, $providers[$i].Name, (Get-SafeUrlForDisplay -Url $providers[$i].BaseUrl))
    }
    $choice = Read-Host ('Select provider [1-' + $providers.Count + ', blank=cancel]')
    if ([string]::IsNullOrWhiteSpace($choice)) { return $null }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $providers.Count) { throw 'Invalid provider selection.' }
    return $providers[$number - 1]
}

function Invoke-SwitchProviderMenu {
    Write-Heading 'Switch expected provider and requested model'
    $document = Read-ConfigDocument
    Write-Host ' 0. Built-in OpenAI provider (keeps current login/auth method)'
    $providers = @(Get-AllProviderDefinitions -Document $document)
    for ($i = 0; $i -lt $providers.Count; $i++) {
        Write-Host (" {0}. {1} | {2}" -f ($i + 1), $providers[$i].Id, (Get-SafeUrlForDisplay -Url $providers[$i].BaseUrl))
    }
    $choice = Read-Host ('Select [0-' + $providers.Count + ', blank=cancel]')
    if ([string]::IsNullOrWhiteSpace($choice)) { return }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 0 -or $number -gt $providers.Count) { throw 'Invalid selection.' }
    if ($number -eq 0) { Invoke-UseOpenAIOperation; return }
    $selected = $providers[$number - 1]
    $currentModel = if ((Get-RootValue -Document $document -Key 'model_provider') -eq $selected.Id) { Get-RootValue -Document $document -Key 'model' } else { '' }
    $modelPrompt = if ($currentModel) { 'Model id [' + $currentModel + ']' } else { 'Model id (required)' }
    $modelValue = Read-Host $modelPrompt
    if ([string]::IsNullOrWhiteSpace($modelValue)) { $modelValue = $currentModel }
    if ([string]::IsNullOrWhiteSpace($modelValue)) { throw 'Model id is required.' }
    $effortValue = Read-Host 'Reasoning effort [blank=model default; none/minimal/low/medium/high/xhigh/max/ultra]'
    Invoke-SetProviderOperation -Id $selected.Id -ModelId $modelValue -Effort $effortValue
}

function Invoke-ConfigureProviderMenu {
    Write-Heading 'Add or update a generic Responses API provider'
    Write-Host 'Current Codex supports the Responses API protocol for custom providers.' -ForegroundColor Yellow
    $id = Read-Host 'Provider id [cst_provider]'
    if ([string]::IsNullOrWhiteSpace($id)) { $id = 'cst_provider' }
    Assert-ProviderId -Id $id
    $name = Read-Host ('Display name [' + $id + ']')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $id }
    $url = Read-Host 'Base URL (example: https://example.com/v1)'
    Assert-BaseUrl -Url $url
    $authAnswer = Read-Host 'Does it use a bearer API key? [Y/n]'
    $hasNoAuth = $authAnswer -match '^(?i:n|no)$'
    $environmentKey = ''
    if (-not $hasNoAuth) {
        $defaultKey = 'CODEX_' + ($id.ToUpperInvariant() -replace '[^A-Z0-9_]', '_') + '_API_KEY'
        $environmentKey = Read-Host ('Environment variable [' + $defaultKey + ']')
        if ([string]::IsNullOrWhiteSpace($environmentKey)) { $environmentKey = $defaultKey }
        Assert-EnvironmentName -Name $environmentKey
    }
    Invoke-ConfigureProviderOperation -Id $id -Name $name -Url $url -EnvironmentKey $environmentKey -ProviderHasNoAuth $hasNoAuth

    if (-not $hasNoAuth) {
        $saveKey = Read-Host 'Save/update this API key for the current Windows user now? [y/N]'
        if ($saveKey -match '^(?i:y|yes)$') { Save-ApiKeyInteractive -Name $environmentKey -Target 'User' }
    }
    $switchNow = Read-Host 'Switch Codex to this provider now? [y/N]'
    if ($switchNow -match '^(?i:y|yes)$') {
        $modelValue = Read-Host 'Model id (required)'
        $effortValue = Read-Host 'Reasoning effort [blank=model default]'
        Invoke-SetProviderOperation -Id $id -ModelId $modelValue -Effort $effortValue
    }
}

function Invoke-ContextMenu {
    Write-Heading 'Context-window tools (independent from provider switching)'
    $document = Read-ConfigDocument
    $currentWindow = Get-RootValue -Document $document -Key 'model_context_window'
    $currentCompact = Get-RootValue -Document $document -Key 'model_auto_compact_token_limit'
    $marker = Get-ContextMarker -Document $document
    $recommendation = Get-RecommendedLongContext -Document $document
    Write-Host ('Current window : ' + $(if ($currentWindow) { $currentWindow } else { '<model default>' }))
    Write-Host ('Current compact: ' + $(if ($currentCompact) { $currentCompact } else { '<model default>' }))
    Write-Host ('Managed by tool: ' + ($null -ne $marker))
    if ($null -ne $recommendation) {
        Write-Host ("Detected catalog maximum for {0}: window={1}, tool compact heuristic={2} (not an official recommendation)" -f $recommendation.Model, $recommendation.Window, $recommendation.Compact) -ForegroundColor Cyan
    } else {
        Write-Host 'No trusted bundled-catalog maximum was found for the requested model.' -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host ' 1. Enable detected catalog maximum (when available)'
    Write-Host ' 2. Enable legacy GPT-5.6 preset (872000 / 800000)'
    Write-Host ' 3. Set custom window and auto-compact values'
    Write-Host ' 4. Restore the pre-tool values, or remove unmanaged overrides'
    Write-Host ' 0. Back'
    $choice = Read-Host 'Select [0-4]'
    switch ($choice) {
        '1' {
            if ($null -eq $recommendation) { throw 'No catalog maximum is available. Use custom values only if your provider documents them.' }
            Invoke-SetContextOperation -Window ([long]$recommendation.Window) -Compact ([long]$recommendation.Compact)
        }
        '2' { Invoke-SetContextOperation -Window 872000 -Compact 800000 }
        '3' {
            $windowText = Read-Host 'Context window tokens'
            $compactText = Read-Host 'Auto-compact token limit'
            $windowValue = 0L; $compactValue = 0L
            if (-not [long]::TryParse($windowText.Replace('_', ''), [ref]$windowValue) -or -not [long]::TryParse($compactText.Replace('_', ''), [ref]$compactValue)) {
                throw 'Context values must be whole numbers.'
            }
            Invoke-SetContextOperation -Window $windowValue -Compact $compactValue
        }
        '4' {
            if ($null -eq $marker -and ($currentWindow -or $currentCompact)) {
                Write-Host 'These context values are not marked as tool-owned. Removing them may delete a manual setting.' -ForegroundColor Yellow
                $confirm = Read-Host 'Type REMOVE to delete the unmanaged overrides'
                if ($confirm -cne 'REMOVE') { Write-Host 'Cancelled.'; return }
                Invoke-ResetContextOperation -AllowUnmanagedRemoval $true
            } else {
                Invoke-ResetContextOperation
            }
        }
        '0' { return }
        default { throw 'Invalid selection.' }
    }
}

function Invoke-ApiKeyMenu {
    Write-Heading 'API-key and legacy-secret tools'
    $document = Read-ConfigDocument
    $selected = Read-ProviderSelection -Document $document
    if ($null -eq $selected) { return }
    $definition = Get-ProviderDefinition -Document $document -Id $selected.Id
    Write-Host ''
    Write-Host ('Provider     : ' + $definition.Id)
    Write-Host ('Environment  : ' + $(if ($definition.EnvKey) { $definition.EnvKey } else { '<not configured>' }))
    Write-Host ('Inline token : ' + $(if ($definition.HasInlineSecret) { 'DETECTED (value hidden)' } else { 'not present' }))
    Write-Host ''
    Write-Host ' 1. Save/update the configured API-key environment variable'
    Write-Host ' 2. Migrate legacy inline experimental_bearer_token to an environment variable'
    Write-Host ' 3. Remove the configured User-scope API-key environment variable'
    Write-Host ' 0. Back'
    $choice = Read-Host 'Select [0-3]'
    switch ($choice) {
        '1' {
            if ([string]::IsNullOrWhiteSpace($definition.EnvKey)) { throw 'This provider has no env_key. Update the provider first or migrate its legacy inline token.' }
            Save-ApiKeyInteractive -Name $definition.EnvKey -Target 'User'
        }
        '2' {
            if (-not $definition.HasInlineSecret) { throw 'This provider has no inline token to migrate.' }
            $defaultKey = if ($definition.EnvKey) { $definition.EnvKey } else { 'CODEX_' + ($definition.Id.ToUpperInvariant() -replace '[^A-Z0-9_]', '_') + '_API_KEY' }
            $keyName = Read-Host ('Environment variable [' + $defaultKey + ']')
            if ([string]::IsNullOrWhiteSpace($keyName)) { $keyName = $defaultKey }
            Write-Host 'The exact safety backup will still contain the old inline token.' -ForegroundColor Yellow
            $references = @((Get-AllProviderDefinitions -Document $document) | Where-Object { $_.EnvKey -ieq $keyName } | Select-Object -ExpandProperty Id)
            if ($references.Count -gt 0) {
                Write-Host ('This environment variable is referenced by: ' + ($references -join ', ')) -ForegroundColor Yellow
            }
            $existingValue = [Environment]::GetEnvironmentVariable($keyName, 'User')
            $allowOverwrite = $false
            if (-not [string]::IsNullOrWhiteSpace($existingValue)) {
                Write-Host 'The User-scope variable already has a value. It may be shared with another provider or program.' -ForegroundColor Yellow
                $overwriteConfirm = Read-Host ('Type the variable name ' + $keyName + ' to allow overwrite if its value differs')
                if ($overwriteConfirm -cne $keyName) { Write-Host 'Cancelled.'; return }
                $allowOverwrite = $true
            }
            $confirm = Read-Host 'Type MIGRATE to continue'
            if ($confirm -cne 'MIGRATE') { Write-Host 'Cancelled.'; return }
            Invoke-MigrateLegacySecretOperation -Id $definition.Id -EnvironmentKey $keyName -Target 'User' -AllowEnvironmentOverwrite $allowOverwrite
        }
        '3' {
            if ([string]::IsNullOrWhiteSpace($definition.EnvKey)) { throw 'This provider has no env_key.' }
            $references = @((Get-AllProviderDefinitions -Document $document) | Where-Object { $_.EnvKey -ieq $definition.EnvKey } | Select-Object -ExpandProperty Id)
            if ($references.Count -gt 1) {
                Write-Host ('WARNING: shared by providers: ' + ($references -join ', ')) -ForegroundColor Red
            }
            Write-Host 'Environment variables are not included in config backups.' -ForegroundColor Yellow
            $confirm = Read-Host ('Type the exact variable name to remove it: ' + $definition.EnvKey)
            if ($confirm -cne $definition.EnvKey) { Write-Host 'Cancelled.'; return }
            [Environment]::SetEnvironmentVariable($definition.EnvKey, $null, 'User')
            [Environment]::SetEnvironmentVariable($definition.EnvKey, $null, 'Process')
            Write-Host ('[OK] Removed User-scope variable ' + $definition.EnvKey + '.') -ForegroundColor Green
        }
        '0' { return }
        default { throw 'Invalid selection.' }
    }
}

function Invoke-BackupMenu {
    Write-Heading 'Backups and restore'
    $records = @(Get-BackupRecords)
    if ($records.Count -eq 0) { Write-Host 'No restorable config backups were found.'; return }
    $shown = [Math]::Min(10, $records.Count)
    for ($i = 0; $i -lt $shown; $i++) {
        $secretLabel = if ($records[$i].ContainsLegacyInlineSecret) { ' | WARNING: contains legacy inline token' } else { '' }
        Write-Host (" {0}. {1} | {2}{3}" -f ($i + 1), $records[$i].Name, $records[$i].Operation, $secretLabel)
    }
    Write-Host ' 0. Back'
    $choice = Read-Host ('Select backup [0-' + $shown + ']')
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $shown) { throw 'Invalid backup selection.' }
    $selected = $records[$number - 1]
    Write-Host ('Will restore: ' + $selected.Directory) -ForegroundColor Yellow
    $confirm = Read-Host 'Type RESTORE to continue'
    if ($confirm -cne 'RESTORE') { Write-Host 'Cancelled.'; return }
    Restore-BackupRecord -Record $selected
}

function Invoke-MainMenu {
    while ($true) {
        Clear-Host
        Write-Host '================================================================'
        Write-Host (' Codex Switch Tools v' + $script:ToolVersion)
        Write-Host ' Provider / model / context / diagnostics'
        Write-Host '================================================================'
        Write-Host ''
        Write-Host ' 1. Show expected settings and diagnostics'
        Write-Host ' 2. Switch provider and requested model'
        Write-Host ' 3. Add or update a generic Responses API provider'
        Write-Host ' 4. Context-window tools'
        Write-Host ' 5. API-key and legacy-secret tools'
        Write-Host ' 6. Backups and restore'
        Write-Host ' 7. Optional direct Responses API probe (may be billable)'
        Write-Host ' 8. Create/update desktop shortcut'
        Write-Host ' 0. Exit'
        Write-Host ''
        $choice = Read-Host 'Select [0-8]'
        try {
            switch ($choice) {
                '1' { Show-Status; Pause-Here }
                '2' { Invoke-SwitchProviderMenu; Pause-Here }
                '3' { Invoke-ConfigureProviderMenu; Pause-Here }
                '4' { Invoke-ContextMenu; Pause-Here }
                '5' { Invoke-ApiKeyMenu; Pause-Here }
                '6' { Invoke-BackupMenu; Pause-Here }
                '7' { Invoke-LiveProbe; Pause-Here }
                '8' { Install-DesktopShortcut; Pause-Here }
                '0' { return }
                default { Write-Host 'Invalid selection.' -ForegroundColor Red; Start-Sleep -Milliseconds 700 }
            }
        } catch {
            $message = Protect-OutputText -Text $_.Exception.Message
            Write-Host ''
            Write-Host ('[ERROR] ' + $message) -ForegroundColor Red
            Pause-Here
        }
    }
}

function Invoke-EntryPoint {
    try {
        switch ($Action) {
            'Menu' { Invoke-MainMenu }
            'Status' { Show-Status }
            'UseOpenAI' { Invoke-UseOpenAIOperation }
            'ConfigureProvider' {
                if ([string]::IsNullOrWhiteSpace($ProviderId) -or [string]::IsNullOrWhiteSpace($BaseUrl)) { throw 'ConfigureProvider requires -ProviderId and -BaseUrl.' }
                if (-not $NoAuth -and [string]::IsNullOrWhiteSpace($EnvKey)) { throw 'ConfigureProvider requires -EnvKey unless -NoAuth is used.' }
                Invoke-ConfigureProviderOperation -Id $ProviderId -Name $ProviderName -Url $BaseUrl -EnvironmentKey $EnvKey -ProviderHasNoAuth ([bool]$NoAuth)
            }
            'SetProvider' {
                if ([string]::IsNullOrWhiteSpace($ProviderId) -or [string]::IsNullOrWhiteSpace($Model)) { throw 'SetProvider requires -ProviderId and -Model.' }
                Invoke-SetProviderOperation -Id $ProviderId -ModelId $Model -Effort $ReasoningEffort
            }
            'SetContext' {
                if ($null -eq $ContextWindow -or $null -eq $AutoCompactLimit) { throw 'SetContext requires -ContextWindow and -AutoCompactLimit.' }
                Invoke-SetContextOperation -Window ([long]$ContextWindow) -Compact ([long]$AutoCompactLimit)
            }
            'ResetContext' { Invoke-ResetContextOperation -AllowUnmanagedRemoval ([bool]$ForceRemoveUnmanagedContext) }
            'ToggleLongContext' { Invoke-ToggleLongContextOperation }
            'MigrateLegacySecret' {
                if ([string]::IsNullOrWhiteSpace($ProviderId)) { throw 'MigrateLegacySecret requires -ProviderId.' }
                Invoke-MigrateLegacySecretOperation -Id $ProviderId -EnvironmentKey $EnvKey -Target $EnvironmentTarget -AllowEnvironmentOverwrite ([bool]$ForceOverwriteEnvironmentVariable)
            }
            'Validate' {
                [void](Read-ConfigDocument)
                $result = Test-CodexConfigParse
                if ($Json) { Write-Output ($result | ConvertTo-Json -Depth 4) }
                else { Write-Host ($result.Message); if ($result.Success) { Write-Host '[OK]' -ForegroundColor Green } }
                if (-not $result.Success) { throw $result.Message }
            }
        }
        $script:EntryExitCode = 0
    } catch {
        $message = Protect-OutputText -Text $_.Exception.Message
        Write-Host ('[ERROR] ' + $message) -ForegroundColor Red
        $script:EntryExitCode = 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-EntryPoint
    exit $script:EntryExitCode
}
