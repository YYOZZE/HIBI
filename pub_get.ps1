# 使用国内镜像解析依赖，避免 pub.dev socket 错误
# 在项目根目录执行: .\pub_get.ps1

$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
Write-Host "已设置国内镜像，正在执行 flutter pub get ..." -ForegroundColor Cyan
flutter pub get
