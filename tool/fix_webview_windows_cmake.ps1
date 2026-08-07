# CMake 3.31+ CMP0175：webview_windows 0.4.x 的 add_custom_command(TARGET) 中不能使用 DEPENDS。
# 在 flutter pub get 之后若 CMake 仍告警，可运行本脚本修正 Pub 缓存中的插件。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tool\fix_webview_windows_cmake.ps1
$ErrorActionPreference = "Stop"
$hosted = Join-Path $env:LOCALAPPDATA "Pub\Cache\hosted"
if (-not (Test-Path $hosted)) {
    Write-Error "未找到 Pub 缓存目录: $hosted"
}
$files = Get-ChildItem -Path $hosted -Recurse -Filter "CMakeLists.txt" -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'webview_windows-[0-9.]+\\windows\\CMakeLists\.txt$' }
if (-not $files) {
    Write-Error "未找到 webview_windows 的 windows/CMakeLists.txt，请先执行 flutter pub get"
}
foreach ($f in $files) {
    $raw = [System.IO.File]::ReadAllText($f.FullName)
    if ($raw -notmatch 'DEPENDS\s+\$\{NUGET\}') {
        Write-Host "已跳过（无 DEPENDS 或已修复）: $($f.FullName)"
        continue
    }
    $new = $raw -replace '(?m)^\s*DEPENDS\s+\$\{NUGET\}\s*\r?\n', ''
    if ($new -eq $raw) {
        Write-Host "替换失败: $($f.FullName)"
        continue
    }
    [System.IO.File]::WriteAllText($f.FullName, $new)
    Write-Host "已修复: $($f.FullName)"
}
