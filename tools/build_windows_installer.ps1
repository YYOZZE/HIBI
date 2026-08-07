# 仅执行 flutter build + ISCC，不对 Setup.exe 做任何后处理（避免安装包损坏）。
param(
  [string]$ProjectRoot = "c:\ALI_Z14\.TSING_important\Tsingcoop_products\pd\jideshi_hibi",
  [string]$IssPath = "windows\Hibi2024_setup.iss"
)
$ErrorActionPreference = "Stop"
Set-Location $ProjectRoot
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }
$iscc = "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) { throw "ISCC not found: $iscc" }
& $iscc $IssPath
if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }
Write-Host "Done. Run the generated Setup exe from the OutputDir — do not patch it with Resource Hacker."
