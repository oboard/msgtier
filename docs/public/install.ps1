# Usage: irm https://msgtier.oboard.fun/install.ps1 | iex
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
  throw 'MsgTier currently provides Windows x64 binaries only.'
}

$asset = 'msgtier-windows-x64.exe'
$installDir = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'msgtier\bin' }
$baseUrl = 'https://github.com/oboard/msgtier/releases/latest/download'
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "msgtier-$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
  $download = Join-Path $tempDir $asset
  $sums = Join-Path $tempDir 'SHA256SUMS'
  Invoke-WebRequest -Uri "$baseUrl/$asset" -OutFile $download
  Invoke-WebRequest -Uri "$baseUrl/SHA256SUMS" -OutFile $sums
  $checksumLine = Get-Content $sums | Where-Object { $_ -match "^[a-fA-F0-9]{64}\s+\*?$([regex]::Escape($asset))$" } | Select-Object -First 1
  if (-not $checksumLine) { throw "No valid SHA-256 checksum for $asset." }
  $expected = $checksumLine.Substring(0, 64)
  $actual = (Get-FileHash -Path $download -Algorithm SHA256).Hash
  if ($actual -ne $expected) { throw "Checksum mismatch for $asset." }
  New-Item -ItemType Directory -Path $installDir -Force | Out-Null
  Copy-Item -Path $download -Destination (Join-Path $installDir 'msgtier.exe') -Force
}
finally {
  Remove-Item -Path $tempDir -Recurse -Force
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -notcontains $installDir) {
  $updatedPath = (@($userPath, $installDir) | Where-Object { $_ }) -join ';'
  [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'User')
  $env:Path = "$installDir;$env:Path"
  Write-Host 'Open a new PowerShell window to use msgtier.'
}
Write-Host "Installed msgtier to $installDir\msgtier.exe"
