[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Join-Path $env:USERPROFILE '.codex') 'config.toml'),
    [switch]$SkipValidation,
    [switch]$NoDialog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch {
    # A detached console may not expose OutputEncoding. The toggle still works.
}

$longContextWindow = 872000
$longAutoCompactLimit = 800000
$blockStart = '# >>> Codex long-context toggle >>>'
$blockEnd = '# <<< Codex long-context toggle <<<'
$originalExisted = $false
$backupPath = $null
$tempPath = $null

function Show-ToggleMessage {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet('Information', 'Error')]
        [string]$Kind = 'Information'
    )

    Write-Host $Message

    if ($NoDialog) {
        return
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        $icon = if ($Kind -eq 'Error') {
            [System.Windows.Forms.MessageBoxIcon]::Error
        } else {
            [System.Windows.Forms.MessageBoxIcon]::Information
        }
        [void][System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            $icon
        )
    } catch {
        # Console output above is the fallback if a dialog cannot be displayed.
    }
}

function Remove-ContextOverrides {
    param(
        [string]$Text,
        [string]$NewLine
    )

    $escapedStart = [regex]::Escape($blockStart)
    $escapedEnd = [regex]::Escape($blockEnd)
    $managedBlock = "(?ms)\A$escapedStart\r?\n.*?^$escapedEnd(?:\r?\n){0,2}"
    $cleaned = [regex]::Replace($Text, $managedBlock, '')

    $targetLine = '(?m)^[ \t]*(?:model_context_window|model_auto_compact_token_limit)[ \t]*=.*?(?:\r?\n|\z)'
    $cleaned = [regex]::Replace($cleaned, $targetLine, '')

    return $cleaned
}

try {
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $configDirectory = Split-Path -Parent $ConfigPath

    if (-not (Test-Path -LiteralPath $configDirectory -PathType Container)) {
        throw "Codex config directory does not exist: $configDirectory"
    }

    $originalExisted = Test-Path -LiteralPath $ConfigPath -PathType Leaf
    $originalBytes = if ($originalExisted) {
        [System.IO.File]::ReadAllBytes($ConfigPath)
    } else {
        [byte[]]@()
    }

    $hasUtf8Bom = $originalBytes.Length -ge 3 -and
        $originalBytes[0] -eq 0xEF -and
        $originalBytes[1] -eq 0xBB -and
        $originalBytes[2] -eq 0xBF
    $utf8 = [System.Text.UTF8Encoding]::new($hasUtf8Bom, $true)
    $originalText = if ($originalExisted) {
        [System.IO.File]::ReadAllText($ConfigPath, $utf8)
    } else {
        ''
    }

    $newLine = if ($originalText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $contextMatch = [regex]::Match(
        $originalText,
        '(?m)^[ \t]*model_context_window[ \t]*=[ \t]*([0-9_]+)'
    )
    $compactMatch = [regex]::Match(
        $originalText,
        '(?m)^[ \t]*model_auto_compact_token_limit[ \t]*=[ \t]*([0-9_]+)'
    )

    $contextValue = if ($contextMatch.Success) {
        [long]($contextMatch.Groups[1].Value.Replace('_', ''))
    } else {
        0
    }
    $compactValue = if ($compactMatch.Success) {
        [long]($compactMatch.Groups[1].Value.Replace('_', ''))
    } else {
        0
    }

    $longModeWasEnabled =
        $contextValue -gt 272000 -or
        $compactValue -gt 272000 -or
        $originalText.StartsWith($blockStart, [System.StringComparison]::Ordinal)

    $cleanedText = Remove-ContextOverrides -Text $originalText -NewLine $newLine

    if ($longModeWasEnabled) {
        $newText = $cleanedText
        $newMode = 'Standard context (model default)'
        $modeAction = 'Long-context mode is now OFF.'
    } else {
        $managedBlock = @(
            $blockStart
            "model_context_window = $longContextWindow"
            "model_auto_compact_token_limit = $longAutoCompactLimit"
            $blockEnd
        ) -join $newLine

        $separator = if ($cleanedText.Length -gt 0) { $newLine + $newLine } else { $newLine }
        $newText = $managedBlock + $separator + $cleanedText
        $newMode = 'Long context (872K, auto-compact near 800K)'
        $modeAction = 'Long-context mode is now ON.'
    }

    if ($originalExisted) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $backupPath = "$ConfigPath.context-toggle-$timestamp.bak"
    }

    $tempPath = "$ConfigPath.toggle-$PID-$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($tempPath, $newText, $utf8)

    if ($originalExisted) {
        [System.IO.File]::Replace($tempPath, $ConfigPath, $backupPath, $true)
    } else {
        [System.IO.File]::Move($tempPath, $ConfigPath)
    }
    $tempPath = $null

    if (-not $SkipValidation) {
        $defaultConfigPath = [System.IO.Path]::GetFullPath(
            (Join-Path (Join-Path $env:USERPROFILE '.codex') 'config.toml')
        )
        if ($ConfigPath -eq $defaultConfigPath) {
            $codexCommand = Get-Command codex -ErrorAction SilentlyContinue
            if ($null -ne $codexCommand) {
                $validationOutput = & $codexCommand.Source debug models --bundled 2>&1
                if ($LASTEXITCODE -ne 0) {
                    if ($originalExisted -and $null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) {
                        Copy-Item -LiteralPath $backupPath -Destination $ConfigPath -Force
                    } elseif (-not $originalExisted -and (Test-Path -LiteralPath $ConfigPath)) {
                        Remove-Item -LiteralPath $ConfigPath -Force
                    }
                    $details = ($validationOutput | Out-String).Trim()
                    throw "Codex config validation failed. The original config was restored.`n$details"
                }
            }
        }
    }

    $backupNote = if ($null -ne $backupPath) {
        "`nBackup: $backupPath"
    } else {
        ''
    }
    $message = @"
$modeAction

Current mode: $newMode
Fully quit and reopen the Codex desktop app. You can then continue the same chat.$backupNote
"@.Trim()

    Show-ToggleMessage -Title 'Codex Context Window Toggle' -Message $message
    exit 0
} catch {
    if ($null -ne $tempPath -and (Test-Path -LiteralPath $tempPath)) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
    $message = "Toggle failed. No new configuration was applied.`n`n$($_.Exception.Message)"
    Show-ToggleMessage -Title 'Codex Context Window Toggle' -Message $message -Kind Error
    exit 1
}
