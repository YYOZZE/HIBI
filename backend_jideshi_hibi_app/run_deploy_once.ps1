# 一次性部署：同步代码 + SSH 执行 Docker 构建与重启（会提示输入 root 密码共 2 次）
# 用法：在项目根目录执行 .\backend_jideshi_hibi_app\run_deploy_once.ps1
# 若 ECS 使用 systemd（无 Docker），请改用 sync_to_server.ps1（同步 + systemctl restart）。
# 后端仅部署在 ECS，不在本机运行。

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$server = "root@121.41.6.21"
$remoteDir = "/root/jideshi_hibi_backend"

$files = @(
    "api_only_app.py",
    "hibi_ct4_fallback.py",
    "hibi_ct4_fallback_b64.txt",
    "hibi_auth_sync.py",
    "hibi_abp_tools.py",
    "hibi_asr.py",
    "tool_schemas.json",
    "hibi_payment.py",
    "requirements.txt",
    "Dockerfile",
    ".env.example",
    "豆包Pro配置说明.md",
    "README.md",
    "DEPLOY_ALIYUN.md",
    "云服务器更新说明.md",
    "server_redeploy.sh",
    "ASR语音识别配置说明.md"
)

Write-Host "步骤 1/2：同步文件到服务器（会提示输入 root 密码）" -ForegroundColor Cyan
foreach ($f in $files) {
    $path = Join-Path $scriptDir $f
    if (Test-Path $path) {
        & scp $path "${server}:${remoteDir}/"
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}
Write-Host "步骤 2/2：在服务器上构建并重启容器（会再次提示输入 root 密码）" -ForegroundColor Cyan
& ssh $server "cd $remoteDir && docker build -t jideshi_hibi_api . && docker restart jideshi_hibi_api"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "部署完成。请验证: http://121.41.6.21:7861/docs" -ForegroundColor Green
