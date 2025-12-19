param(
  [string]$Repo = $env:NYTGAMES_CLI_REPO,
  [string]$Version = $env:NYTGAMES_CLI_VERSION,
  [string]$InstallDir = $env:NYTGAMES_CLI_INSTALL_DIR
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Repo)) {
  $Repo = "ph8n/nytgames-cli"
}

$headers = @{ "User-Agent" = "nytgames-cli-installer" }

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
  $base = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($base)) {
    $base = Join-Path $HOME "AppData\\Local"
  }
  $InstallDir = Join-Path $base "nytgames-cli\\bin"
}

$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
switch ($arch) {
  "X64" { $arch = "amd64" }
  "Arm64" { throw "unsupported architecture: arm64 (Windows builds are amd64 only)" }
  default { throw "unsupported architecture: $arch" }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $release = Invoke-RestMethod -Headers $headers "https://api.github.com/repos/$Repo/releases/latest"
  $tag = $release.tag_name
  if (-not $tag) {
    throw "failed to resolve latest version from GitHub for $Repo"
  }
  $Version = $tag.TrimStart("v")
} else {
  $Version = $Version.TrimStart("v")
}

$asset = "nytgames-cli_${Version}_windows_${arch}.zip"
$baseUrl = "https://github.com/$Repo/releases/download/v$Version"
$url = "$baseUrl/$asset"
$checksumsUrl = "$baseUrl/checksums.txt"

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nytgames-cli-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
  $assetPath = Join-Path $tempDir $asset
  Write-Host "Downloading $url"
  Invoke-WebRequest -Uri $url -OutFile $assetPath -UseBasicParsing -Headers $headers

  $checksumsPath = Join-Path $tempDir "checksums.txt"
  $expected = $null
  try {
    Invoke-WebRequest -Uri $checksumsUrl -OutFile $checksumsPath -UseBasicParsing -Headers $headers
    $expectedLine = Get-Content $checksumsPath |
      Where-Object { $_ -match ("\s+" + [regex]::Escape($asset) + "$") } |
      Select-Object -First 1
    if ($expectedLine) {
      $expected = ($expectedLine -split "\s+")[0].ToLower()
    }
  } catch {
    $expected = $null
  }
  if ($expected) {
    $actual = (Get-FileHash -Algorithm SHA256 $assetPath).Hash.ToLower()
    if ($expected -ne $actual) {
      throw "checksum mismatch for $asset`nexpected: $expected`nactual:   $actual"
    }
  }

  Expand-Archive -Path $assetPath -DestinationPath $tempDir -Force

  $binPath = Join-Path $tempDir "nytgames.exe"
  if (-not (Test-Path $binPath)) {
    $bin = Get-ChildItem -Path $tempDir -Recurse -Filter "nytgames.exe" | Select-Object -First 1
    if ($bin) {
      $binPath = $bin.FullName
    } else {
      throw "failed to find nytgames.exe in archive"
    }
  }

  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  Copy-Item -Force $binPath (Join-Path $InstallDir "nytgames.exe")

  Write-Host "Installed nytgames.exe to $InstallDir"
  $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
  if ($userPath -and $userPath -notlike "*$InstallDir*") {
    Write-Warning "$InstallDir is not on your PATH. Add it to run 'nytgames' from any shell."
  }
} finally {
  if (Test-Path $tempDir) {
    Remove-Item -Recurse -Force $tempDir
  }
}
