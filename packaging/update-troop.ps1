# TROOP terminal updater (Windows). Downloads the latest Setup.exe, verifies
# its checksum, and silently updates the existing install in place (the
# installer remembers its location in the registry).
# Usage:  powershell -c "irm https://raw.githubusercontent.com/charlesjsantosgit/troop/main/packaging/update-troop.ps1 | iex"
$ErrorActionPreference = "Stop"
$Repo = "charlesjsantosgit/troop"
Write-Host "TROOP updater (Windows)"
$Release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest"
$Tag = $Release.tag_name
$Ver = $Tag.TrimStart("v")
$Setup = "TROOP-$Ver-Windows-x86_64-Setup.exe"
$Work = Join-Path $env:TEMP "troop-update"
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$SetupPath = Join-Path $Work $Setup
Write-Host "Downloading TROOP $Ver..."
Invoke-WebRequest "https://github.com/$Repo/releases/download/$Tag/$Setup" -OutFile $SetupPath
$Sums = (Invoke-WebRequest "https://github.com/$Repo/releases/download/$Tag/TROOP-$Ver-SHA256SUMS.txt").Content
$Expected = (($Sums -split "`n" | Where-Object { $_ -match [regex]::Escape($Setup) }) -split "\s+")[0].ToLower()
$Actual = (Get-FileHash $SetupPath -Algorithm SHA256).Hash.ToLower()
if ($Expected -ne $Actual) { throw "Checksum mismatch - aborting." }
Get-Process TROOP -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process -FilePath $SetupPath -ArgumentList "/S" -Wait
Write-Host "TROOP $Ver installed silently into the existing install location - ook!"
