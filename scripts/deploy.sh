#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}          # dev | test | prod
PROJECT_NAME=${2:-twin}

echo "🚀 Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

# 1. Build Lambda package
cd "$(dirname "$0")/.."        # project root
echo "📦 Building Lambda package..."
(cd backend && uv run deploy.py)

# 2. Terraform workspace & apply
cd terraform
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}

# Remove ALL local terraform state to avoid migration prompts
if [ -d ".terraform" ]; then
  echo "🧹 Cleaning old Terraform configuration..."
  rm -rf .terraform
fi
if [ -f "terraform.tfstate" ]; then
  echo "🧹 Removing local state files..."
  rm -f terraform.tfstate terraform.tfstate.backup
fi
if [ -d "terraform.tfstate.d" ]; then
  echo "🧹 Removing workspace state files..."
  rm -rf terraform.tfstate.d
fi

terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="use_lockfile=true" \
  -backend-config="encrypt=true"

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace new "$ENVIRONMENT"
else
  terraform workspace select "$ENVIRONMENT"
fi

# Import existing IAM role if it exists (prevents EntityAlreadyExists error)
echo "🔍 Checking for existing IAM role..."
IAM_ROLE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-lambda-role"

# Check if role exists in AWS
if aws iam get-role --role-name "$IAM_ROLE_NAME" &>/dev/null; then
  echo "   Found existing IAM role: $IAM_ROLE_NAME"
  
  # Check if role is already in Terraform state
  if terraform state show aws_iam_role.lambda_role &>/dev/null; then
    echo "   ✓ Role already managed by Terraform"
  else
    echo "📥 Importing existing IAM role and policies into Terraform state..."
    
    # Import the IAM role
    if terraform import aws_iam_role.lambda_role "$IAM_ROLE_NAME"; then
      echo "   ✓ IAM role imported"
    else
      echo "   ❌ Failed to import IAM role"
      exit 1
    fi
    
    # Import policy attachments if they exist
    echo "   Importing policy attachments..."
    terraform import aws_iam_role_policy_attachment.lambda_basic "${IAM_ROLE_NAME}/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || echo "      (lambda_basic not attached or already imported)"
    terraform import aws_iam_role_policy_attachment.lambda_bedrock "${IAM_ROLE_NAME}/arn:aws:iam::aws:policy/AmazonBedrockFullAccess" 2>/dev/null || echo "      (lambda_bedrock not attached or already imported)"
    terraform import aws_iam_role_policy_attachment.lambda_s3 "${IAM_ROLE_NAME}/arn:aws:iam::aws:policy/AmazonS3FullAccess" 2>/dev/null || echo "      (lambda_s3 not attached or already imported)"
    
    echo "   ✓ Import process complete"
  fi
else
  echo "   No existing role found - will create new one"
fi

# Use prod.tfvars for production environment
if [ "$ENVIRONMENT" = "prod" ]; then
  TF_APPLY_CMD=(terraform apply -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve)
else
  TF_APPLY_CMD=(terraform apply -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve)
fi

echo "🎯 Applying Terraform..."
"${TF_APPLY_CMD[@]}"

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || true)

# 3. Build + deploy frontend
cd ../frontend

# Create production environment file with API URL
echo "📝 Setting API URL for production..."
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production

npm install
npm run build
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

# 4. Final messages
echo -e "\n✅ Deployment complete!"
echo "🌐 CloudFront URL : $(terraform -chdir=terraform output -raw cloudfront_url)"
if [ -n "$CUSTOM_URL" ]; then
  echo "🔗 Custom domain  : $CUSTOM_URL"
fi
echo "📡 API Gateway    : $API_URL"