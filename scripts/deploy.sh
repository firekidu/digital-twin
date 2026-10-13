#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}    # dev | test | prod
PROJECT_NAME=${2:-twin}

echo "🚀 Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

# 1. Build Lambda package
cd "$(dirname "$0")/.."    # project root
echo "📦 Building Lambda package..."
(cd backend && uv run deploy.py)

# 2. Terraform workspace & apply
# Pass the OpenAI key to Terraform from backend/.env unless already set
if [ -z "$TF_VAR_openai_api_key" ]; then
    KEY_LINE=$(grep -E '^\s*OPENAI_API_KEY\s*=' backend/.env 2>/dev/null | head -1 || true)
    if [ -z "$KEY_LINE" ]; then
        echo "❌ Error: OPENAI_API_KEY not found in backend/.env and TF_VAR_openai_api_key is not set"
        exit 1
    fi
    TF_VAR_openai_api_key=$(echo "${KEY_LINE#*=}" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^[\"']//" -e "s/[\"']$//")
    export TF_VAR_openai_api_key
fi

cd terraform
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-eu-north-1}

echo "🔧 Initializing Terraform with S3 backend..."
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
    terraform workspace new "$ENVIRONMENT"
else
    terraform workspace select "$ENVIRONMENT"
fi

if [ "$ENVIRONMENT" = "prod" ]; then
    terraform apply -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
else
    terraform apply -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve
fi

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || true)

# 3. Build + deploy frontend
cd ../frontend

echo "🔗 Setting API URL for production..."
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production

npm install
npm run build
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

# 4. Final summary
CF_URL=$(terraform -chdir=terraform output -raw cloudfront_url)
echo "✅ Deployment complete!"
echo "🌐 CloudFront URL : $CF_URL"
if [ -n "$CUSTOM_URL" ]; then
    echo "🔗 Custom domain  : $CUSTOM_URL"
fi
echo "📡 API Gateway    : $API_URL"
