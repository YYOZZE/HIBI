# 一次性永久设置 Flutter 国内镜像（解决 pub.dev socket 错误、手机调试启动不了）
# 以管理员身份运行 或 直接双击/在 PowerShell 中执行均可（无需管理员）
# 执行后请【关闭并重新打开】IDE 和终端，再运行/调试项目。

$pubUrl = "https://pub.flutter-io.cn"
$storageUrl = "https://storage.flutter-io.cn"

Write-Host "正在永久设置 Flutter 国内镜像（当前用户环境变量）..." -ForegroundColor Cyan
[Environment]::SetEnvironmentVariable("PUB_HOSTED_URL", $pubUrl, "User")
[Environment]::SetEnvironmentVariable("FLUTTER_STORAGE_BASE_URL", $storageUrl, "User")
Write-Host "  PUB_HOSTED_URL = $pubUrl" -ForegroundColor Green
Write-Host "  FLUTTER_STORAGE_BASE_URL = $storageUrl" -ForegroundColor Green
Write-Host ""
Write-Host "已设置完成。请务必：" -ForegroundColor Yellow
Write-Host "  1. 关闭当前 IDE（如 Android Studio / Cursor / VS Code）" -ForegroundColor White
Write-Host "  2. 关闭所有已打开的终端" -ForegroundColor White
Write-Host "  3. 重新打开 IDE，再运行或调试项目（含手机调试）" -ForegroundColor White
Write-Host ""
Write-Host "之后无需再执行本脚本，新开的所有窗口都会自动使用镜像。" -ForegroundColor Cyan
