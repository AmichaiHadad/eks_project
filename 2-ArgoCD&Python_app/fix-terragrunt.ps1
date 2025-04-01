$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$terragruntDir = Join-Path $projectDir "terragrunt\argocd"
$terraformDir = Join-Path $projectDir "terraform\argocd"

Write-Host "Cleaning up Terragrunt cache and temporary files..." -ForegroundColor Cyan
if (Test-Path (Join-Path $terragruntDir ".terragrunt-cache")) {
    Remove-Item -Path (Join-Path $terragruntDir ".terragrunt-cache") -Recurse -Force
}

Write-Host "Fixing the bcrypt issue in main.tf..." -ForegroundColor Cyan
$mainTfPath = Join-Path $terraformDir "main.tf"
$content = Get-Content $mainTfPath -Raw
$content = $content -replace 'password = bcrypt\(random_password.argocd_admin_password.result\)', 'password = base64encode(random_password.argocd_admin_password.result)'
Set-Content -Path $mainTfPath -Value $content

Write-Host "Running Terragrunt init with clean environment..." -ForegroundColor Cyan
Push-Location $terragruntDir
try {
    terragrunt init --reconfigure
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Init successful. Running Terragrunt plan..." -ForegroundColor Green
        terragrunt plan
    }
}
finally {
    Pop-Location
}

Write-Host "Done!" -ForegroundColor Green 