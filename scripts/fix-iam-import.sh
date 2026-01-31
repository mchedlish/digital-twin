#!/bin/bash
# Manual fix script to import existing IAM resources into Terraform state
# Run this if you encounter "EntityAlreadyExists" errors

set -e

ENVIRONMENT=${1:-dev}
PROJECT_NAME=${2:-twin}

echo "🔧 Fixing IAM role import for ${PROJECT_NAME}-${ENVIRONMENT}..."

cd "$(dirname "$0")/../terraform"

# Get AWS Account ID and Region
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}

# Initialize Terraform
echo "📦 Initializing Terraform..."

# Remove ALL local terraform state to avoid migration prompts
if [ -d ".terraform" ]; then
  echo "   Cleaning old Terraform configuration..."
  rm -rf .terraform
fi
if [ -f "terraform.tfstate" ]; then
  echo "   Removing local state file..."
  rm -f terraform.tfstate terraform.tfstate.backup
fi
if [ -d "terraform.tfstate.d" ]; then
  echo "   Removing workspace state files..."
  rm -rf terraform.tfstate.d
fi

terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="use_lockfile=true" \
  -backend-config="encrypt=true"

# Select workspace
echo "🎯 Selecting workspace: $ENVIRONMENT"
terraform workspace select "$ENVIRONMENT"

IAM_ROLE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-lambda-role"

# Check if role exists in AWS
if ! aws iam get-role --role-name "$IAM_ROLE_NAME" &>/dev/null; then
  echo "❌ IAM role $IAM_ROLE_NAME does not exist in AWS"
  echo "   No import needed. You can proceed with deployment."
  exit 0
fi

echo "✓ Found IAM role: $IAM_ROLE_NAME"

# Check if already in state
if terraform state show aws_iam_role.lambda_role &>/dev/null; then
  echo "✓ Role already in Terraform state"
  echo ""
  echo "Current state:"
  terraform state show aws_iam_role.lambda_role | head -10
  exit 0
fi

# Import the role
echo ""
echo "📥 Importing IAM role..."
terraform import aws_iam_role.lambda_role "$IAM_ROLE_NAME"

echo ""
echo "📥 Importing policy attachments..."

# Import policy attachments
terraform import aws_iam_role_policy_attachment.lambda_basic \
  "${IAM_ROLE_NAME}/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
  2>/dev/null && echo "   ✓ lambda_basic" || echo "   ⚠️  lambda_basic (may not be attached)"

terraform import aws_iam_role_policy_attachment.lambda_bedrock \
  "${IAM_ROLE_NAME}/arn:aws:iam::aws:policy/AmazonBedrockFullAccess" \
  2>/dev/null && echo "   ✓ lambda_bedrock" || echo "   ⚠️  lambda_bedrock (may not be attached)"

terraform import aws_iam_role_policy_attachment.lambda_s3 \
  "${IAM_ROLE_NAME}/arn:aws:iam::aws:policy/AmazonS3FullAccess" \
  2>/dev/null && echo "   ✓ lambda_s3" || echo "   ⚠️  lambda_s3 (may not be attached)"

echo ""
echo "✅ Import complete! You can now run your deployment again."
echo ""
echo "To verify, run:"
echo "  cd terraform"
echo "  terraform workspace select $ENVIRONMENT"
echo "  terraform state list | grep lambda_role"
