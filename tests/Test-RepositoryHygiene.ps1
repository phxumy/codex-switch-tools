[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$patterns = @(
    [pscustomobject]@{ Name = 'OpenAI-like API key'; Regex = '(?i)sk-[A-Za-z0-9._-]{20,}' },
    [pscustomobject]@{ Name = 'Private key block'; Regex = '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----' },
    [pscustomobject]@{ Name = 'JWT-like token'; Regex = '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}' },
    [pscustomobject]@{ Name = 'Private Windows user path'; Regex = '(?i)[A-Z]:\\Users\\[^\\\r\n]+' },
    [pscustomobject]@{ Name = 'Legacy chat-client source path'; Regex = ('(?i)We' + 'Chat files|wx' + 'id_[A-Za-z0-9_]+') }
)

$findings = [System.Collections.Generic.List[object]]::new()
$files = Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
foreach ($file in $files) {
    try { $text = [IO.File]::ReadAllText($file.FullName) } catch { continue }
    foreach ($pattern in $patterns) {
        if ($text -match $pattern.Regex) {
            [void]$findings.Add([pscustomobject]@{ File = $file.FullName.Substring($repoRoot.Length + 1); Kind = $pattern.Name })
        }
    }
}

if ($findings.Count -gt 0) {
    $findings | Format-Table -AutoSize
    throw "Repository hygiene scan found $($findings.Count) potential secret/private-path issue(s). Values were not printed."
}

Write-Host ('[PASS] Repository hygiene scan checked ' + @($files).Count + ' files without exposing matched values.') -ForegroundColor Green
