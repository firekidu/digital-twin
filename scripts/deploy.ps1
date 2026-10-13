param(
    [string]$Environment = "dev",   # dev | test | prod
    [string]$ProjectName = "twin"
)
$ErrorActionPreference = "Stop"

# Native commands don't trigger $ErrorActionPreference in PowerShell 5.1
function Assert-Success($Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed (exit code $LASTEXITCODE)" }
}

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

# 1. Build Lambda package
Set-Location (Split-Path $PSScriptRoot -Parent)   # project root
Write-Host "Building Lambda package..." -ForegroundColor Yellow
Set-Location backend
uv run deploy.py
Assert-Success "Lambda build"
Set-Location ..

# 2. Terraform workspace & apply
# Pass the OpenAI key to Terraform from backend/.env unless already set
if (-not $env:TF_VAR_openai_api_key) {
    $KeyLine = Get-Content backend\.env -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=' } | Select-Object -First 1
    if (-not $KeyLine) { throw "OPENAI_API_KEY not found in backend\.env and TF_VAR_openai_api_key is not set" }
    $env:TF_VAR_openai_api_key = ($KeyLine -replace '^\s*OPENAI_API_KEY\s*=\s*', '').Trim().Trim('"').Trim("'")
}

Set-Location terraform
terraform init -input=false
Assert-Success "terraform init"

if (-not (terraform workspace list | Select-String $Environment)) {
    terraform workspace new $Environment
} else {
    terraform workspace select $Environment
}

if ($Environment -eq "prod") {
    terraform apply -var-file="prod.tfvars" -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
    Assert-Success "terraform apply"
} else {
    terraform apply -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
    Assert-Success "terraform apply"
}

$ApiUrl        = terraform output -raw api_gateway_url
$FrontendBucket = terraform output -raw s3_frontend_bucket
Assert-Success "terraform output"
try { $CustomUrl = terraform output -raw custom_domain_url } catch { $CustomUrl = "" }

# 3. Build + deploy frontend
Set-Location ..\frontend

# Create production environment file with API URL
Write-Host "Setting API URL for production..." -ForegroundColor Yellow
"NEXT_PUBLIC_API_URL=$ApiUrl" | Out-File .env.production -Encoding utf8

npm install
Assert-Success "npm install"
npm run build
Assert-Success "npm run build"
aws s3 sync .\out "s3://$FrontendBucket/" --delete
Assert-Success "S3 sync"
Set-Location ..

# 4. Final summary
$CfUrl = terraform -chdir=terraform output -raw cloudfront_url
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
if ($CustomUrl) {
    Write-Host "Custom domain  : $CustomUrl" -ForegroundColor Cyan
}
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan
