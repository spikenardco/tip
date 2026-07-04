# tip installer for Windows.
#   irm https://raw.githubusercontent.com/spikenardco/tip/main/scripts/install.ps1 | iex
# Env overrides: TIP_VERSION, TIP_INSTALL_DIR, TIP_BASE_URL, TIP_API_URL
$ErrorActionPreference = 'Stop'

$Repo    = 'spikenardco/tip'
$BaseUrl = if ($env:TIP_BASE_URL) { $env:TIP_BASE_URL } else { "https://github.com/$Repo/releases/download" }
$ApiUrl  = if ($env:TIP_API_URL)  { $env:TIP_API_URL }  else { "https://api.github.com/repos/$Repo/releases/latest" }
$Asset   = 'tip-windows-x86_64.exe'

$Version = if ($env:TIP_VERSION) {
    $env:TIP_VERSION
} else {
    (Invoke-RestMethod -Uri $ApiUrl -Headers @{ 'User-Agent' = 'tip-installer' }).tag_name
}
if (-not $Version) { throw 'could not determine version; set TIP_VERSION' }

$Dir = if ($env:TIP_INSTALL_DIR) { $env:TIP_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'tip\bin' }
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
try {
    Write-Host "==> Installing tip $Version ($Asset)"
    $binPath = Join-Path $Tmp 'tip.exe'
    Invoke-WebRequest -Uri "$BaseUrl/$Version/$Asset" -OutFile $binPath
    $sumPath = Join-Path $Tmp 'checksums.txt'
    Invoke-WebRequest -Uri "$BaseUrl/$Version/checksums.txt" -OutFile $sumPath

    $line = Get-Content $sumPath | Where-Object { $_ -match [regex]::Escape($Asset) } | Select-Object -First 1
    if (-not $line) { throw "no checksum for $Asset in checksums.txt" }
    $expected = ($line -split '\s+')[0].ToLower()
    $actual   = (Get-FileHash -Algorithm SHA256 $binPath).Hash.ToLower()
    if ($expected -ne $actual) { throw "checksum mismatch (expected $expected, got $actual)" }
    Write-Host '==> Checksum verified'

    Copy-Item -Force $binPath (Join-Path $Dir 'tip.exe')
    Write-Host "==> Installed tip to $Dir\tip.exe"

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$Dir*") {
        Write-Warning "$Dir is not on your PATH. Add it via: setx PATH `"$Dir;`$env:PATH`""
    }
} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
