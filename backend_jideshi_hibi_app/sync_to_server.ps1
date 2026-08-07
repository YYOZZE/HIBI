# 将后端代码同步到云服务器并重启服务（root 账号，不覆盖服务器上的 .env）
# 用法：在项目根目录执行 .\backend_jideshi_hibi_app\sync_to_server.ps1
# 说明：默认不使用 SSH 连接复用，避免 Windows 环境下 ControlMaster 不兼容

$ErrorActionPreference = "Stop"
$scriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
}
elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    (Get-Location).Path
}
$server = if ($env:SERVER) { $env:SERVER } else { "root@121.41.6.21" }
$remoteDir = "/root/jideshi_hibi_backend"
$remoteStaticDir = "$remoteDir/static"

$files = @(
    "api_only_app.py",
    "hibi_ct4_fallback.py",
    "hibi_ct4_fallback_b64.txt",
    "hibi_auth_sync.py",
    "hibi_graph_captcha.py",
    "hibi_abp_tools.py",
    "hibi_asr.py",
    "hibi_sauc_protocol.py",
    "asr_cli_demo.py",
    "tool_schemas.json",
    "hibi_payment.py",
    "requirements.txt",
    "Dockerfile",
    "run_with_venv.sh",
    "jideshi-hibi-api.service",
    ".env.example",
    "豆包Pro配置说明.md",
    "README.md",
    "DEPLOY_ALIYUN.md",
    "云服务器更新说明.md",
    "server_redeploy.sh",
    "ASR语音识别配置说明.md",
    "ecs_check_and_fix.sh",
    "ECS排查与修复步骤.md"
)

$paths = @()
foreach ($f in $files) {
    $path = Join-Path $scriptDir $f
    if (Test-Path $path) { $paths += $path }
}
if ($paths.Count -eq 0) { Write-Host "没有可同步的文件" -ForegroundColor Yellow; exit 0 }

# 1. 上传所有文件（会提示输入密码）
Write-Host "同步 $($paths.Count) 个文件到 $remoteDir ..." -ForegroundColor Cyan
& scp $paths "${server}:${remoteDir}/"
if ($LASTEXITCODE -ne 0) {
    Write-Host "scp 失败" -ForegroundColor Red
    exit $LASTEXITCODE
}

# 2. 同步图形认证 SDK 静态文件（用于 /api/auth/captcha/sdk.js）
$captchaSdk = if ($scriptDir) { Join-Path -Path $scriptDir -ChildPath "static\ct4.js" } else { $null }
if ($captchaSdk -and (Test-Path -Path $captchaSdk)) {
    Write-Host "同步图形认证 SDK 到 $remoteStaticDir ..." -ForegroundColor Cyan
    & ssh $server "mkdir -p $remoteStaticDir"
    if ($LASTEXITCODE -eq 0) {
        & scp $captchaSdk "${server}:${remoteStaticDir}/ct4.js"
    }
}

# 3. 在 ECS 上重启服务（systemd）
Write-Host "在 ECS 上重启 jideshi-hibi-api..." -ForegroundColor Cyan
& ssh $server "cd $remoteDir && chmod +x ecs_check_and_fix.sh 2>/dev/null"
if ($LASTEXITCODE -ne 0) {
    Write-Host "远端目录检查失败，请确认 $remoteDir 存在" -ForegroundColor Red
    exit $LASTEXITCODE
}
& ssh $server "systemctl restart jideshi-hibi-api && systemctl is-active jideshi-hibi-api && systemctl status jideshi-hibi-api --no-pager -l"
if ($LASTEXITCODE -ne 0) {
    Write-Host "重启或 status 返回非零，请登录 ECS 检查 systemctl status jideshi-hibi-api" -ForegroundColor Yellow
}
else {
    Write-Host "同步并重启完成。验证: http://121.41.6.21:7861/docs" -ForegroundColor Green
}
