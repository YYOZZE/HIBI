# 一次性部署到 ECS（使用密码，勿提交到 Git）
# 用法: $env:DEPLOY_PW='你的密码'; .\deploy_to_ecs.ps1
# 或: .\deploy_to_ecs.ps1 -Password '你的密码'

param([string]$Password = $env:DEPLOY_PW)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostAddr = "121.41.6.21"
$remoteDir = "/root/jideshi_hibi_backend"

$files = @(
    "api_only_app.py", "hibi_ct4_fallback.py", "hibi_ct4_fallback_b64.txt",
    "hibi_auth_sync.py", "hibi_abp_tools.py", "tool_schemas.json",
    "hibi_payment.py", "requirements.txt", "Dockerfile", "run_with_venv.sh",
    "jideshi-hibi-api.service", ".env.example", "豆包Pro配置说明.md", "README.md",
    "DEPLOY_ALIYUN.md", "云服务器更新说明.md", "server_redeploy.sh"
)

if (-not $Password) {
    Write-Host "请设置密码: `$env:DEPLOY_PW='...' 或 -Password '...'" -ForegroundColor Red
    exit 1
}

if (-not (Get-Module -ListAvailable Posh-SSH)) {
    Write-Host "正在安装 Posh-SSH 模块..." -ForegroundColor Cyan
    Install-Module Posh-SSH -Scope CurrentUser -Force -AllowClobber
}
Import-Module Posh-SSH -ErrorAction Stop

$sec = ConvertTo-SecureString $Password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("root", $sec)

Write-Host "1/2 上传文件到 $hostAddr ..." -ForegroundColor Cyan
foreach ($f in $files) {
    $path = Join-Path $scriptDir $f
    if (Test-Path $path) {
        Set-SCPItem -ComputerName $hostAddr -Credential $cred -Path $path -Destination $remoteDir -AcceptKey -Force
        Write-Host "  OK $f"
    }
}

Write-Host "2/2 重启服务..." -ForegroundColor Cyan
$session = New-SSHSession -ComputerName $hostAddr -Credential $cred -AcceptKey -Force
$result = Invoke-SSHCommand -SessionId $session.SessionId -Command "systemctl restart jideshi-hibi-api 2>/dev/null || (cd $remoteDir && nohup bash run_with_venv.sh &)"
Remove-SSHSession -SessionId $session.SessionId | Out-Null
if ($result.ExitStatus -eq 0) { Write-Host "重启已执行." -ForegroundColor Green } else { Write-Host "重启命令输出: $($result.Output)" -ForegroundColor Yellow }

Write-Host "完成. 验证: http://${hostAddr}:7861/docs" -ForegroundColor Green
