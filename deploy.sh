#!/usr/bin/env bash
# deploy.sh — Deploys Regionalszenarien 2025 API to AWS
# Usage: bash deploy.sh [--region eu-central-1] [--bucket-suffix my-uni]
#
# Prerequisites: aws CLI configured (aws configure), python3, zip

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-eu-central-1}"
BUCKET_SUFFIX="${BUCKET_SUFFIX:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "demo")}"
S3_BUCKET="netzengpaesse-daten-api-${BUCKET_SUFFIX}"
S3_DATA_KEY="data.json"
LAMBDA_FUNCTION="netzengpaesse-daten-api"
LAMBDA_ROLE="netzengpaesse-daten-api-role"
API_NAME="netzengpaesse-daten-api"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TAGS="course=CDUS semester=SoSe26 university=HSB"
TAGS_JSON='{"course":"CDUS","semester":"SoSe26","university":"HSB"}'

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --region) AWS_REGION="$2"; shift 2 ;;
    --bucket-suffix) S3_BUCKET="regionalszenarien-2025-$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo "============================================"
echo " Deploying Regionalszenarien 2025 API"
echo "  Region : $AWS_REGION"
echo "  Bucket : $S3_BUCKET"
echo "  Lambda : $LAMBDA_FUNCTION"
echo "============================================"

# ── Step 1: Preprocess Excel → data.json ─────────────────────────────────────
echo ""
echo "[1/6] Generating data.json from Excel..."
if [ ! -f "$SCRIPT_DIR/data/data.json" ]; then
  python3 "$SCRIPT_DIR/scripts/preprocess.py"
else
  echo "  data.json already exists, skipping (delete to regenerate)"
fi

# ── Step 2: Create S3 bucket ──────────────────────────────────────────────────
echo ""
echo "[2/6] Creating S3 bucket: $S3_BUCKET ..."
if aws s3api head-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
  echo "  Bucket already exists."
else
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "$S3_BUCKET" \
      --region "$AWS_REGION"
  else
    aws s3api create-bucket \
      --bucket "$S3_BUCKET" \
      --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
  # Block all public access
  aws s3api put-public-access-block \
    --bucket "$S3_BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  aws s3api put-bucket-tagging \
    --bucket "$S3_BUCKET" \
    --tagging "TagSet=[{Key=course,Value=CDUS},{Key=semester,Value=SoSe26},{Key=university,Value=HSB}]"
  echo "  Bucket created, public access blocked, tags applied."
fi

# ── Step 3: Upload data.json to S3 ───────────────────────────────────────────
echo ""
echo "[3/6] Uploading data.json to s3://$S3_BUCKET/$S3_DATA_KEY ..."
aws s3 cp "$SCRIPT_DIR/data/data.json" "s3://$S3_BUCKET/$S3_DATA_KEY" \
  --region "$AWS_REGION" \
  --content-type "application/json"
echo "  Uploaded."

# ── Step 4: Create IAM role for Lambda ───────────────────────────────────────
echo ""
echo "[4/6] Setting up IAM role: $LAMBDA_ROLE ..."

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE" \
  --query 'Role.Arn' --output text 2>/dev/null || true)

if [ -z "$ROLE_ARN" ]; then
  ROLE_ARN=$(aws iam create-role \
    --role-name "$LAMBDA_ROLE" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --tags Key=course,Value=CDUS Key=semester,Value=SoSe26 Key=university,Value=HSB \
    --query 'Role.Arn' --output text)
  echo "  Role created: $ROLE_ARN"

  # Basic Lambda execution (CloudWatch Logs)
  aws iam attach-role-policy \
    --role-name "$LAMBDA_ROLE" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

  # Inline policy: s3:GetObject on our bucket only
  aws iam put-role-policy \
    --role-name "$LAMBDA_ROLE" \
    --policy-name "s3-read-data" \
    --policy-document "{
      \"Version\": \"2012-10-17\",
      \"Statement\": [{
        \"Effect\": \"Allow\",
        \"Action\": \"s3:GetObject\",
        \"Resource\": \"arn:aws:s3:::${S3_BUCKET}/${S3_DATA_KEY}\"
      }]
    }"

  echo "  Waiting for role propagation..."
  sleep 12
else
  echo "  Role already exists: $ROLE_ARN"
fi

# ── Step 5: Package and deploy Lambda ────────────────────────────────────────
echo ""
echo "[5/6] Packaging Lambda function..."

BUILD_DIR="$SCRIPT_DIR/.build"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
cp "$SCRIPT_DIR/lambda/handler.py" "$BUILD_DIR/handler.py"

cd "$BUILD_DIR"
zip -q lambda.zip handler.py
cd "$SCRIPT_DIR"

# Convert to Windows path for AWS CLI (needed in Git Bash on Windows)
ZIP_PATH=$(cygpath -w "$BUILD_DIR/lambda.zip" 2>/dev/null || echo "$BUILD_DIR/lambda.zip")

FUNCTION_EXISTS=$(aws lambda get-function --function-name "$LAMBDA_FUNCTION" \
  --region "$AWS_REGION" --query 'Configuration.FunctionName' --output text 2>/dev/null || true)

if [ -z "$FUNCTION_EXISTS" ]; then
  echo "  Creating Lambda function..."
  aws lambda create-function \
    --function-name "$LAMBDA_FUNCTION" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler handler.handler \
    --zip-file "fileb://$ZIP_PATH" \
    --timeout 15 \
    --memory-size 256 \
    --environment "Variables={S3_BUCKET=$S3_BUCKET,S3_KEY=$S3_DATA_KEY}" \
    --tags "$TAGS_JSON" \
    --region "$AWS_REGION" \
    --query 'FunctionArn' --output text
else
  echo "  Updating Lambda function code..."
  aws lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION" \
    --zip-file "fileb://$ZIP_PATH" \
    --region "$AWS_REGION" \
    --query 'FunctionArn' --output text

  aws lambda update-function-configuration \
    --function-name "$LAMBDA_FUNCTION" \
    --environment "Variables={S3_BUCKET=$S3_BUCKET,S3_KEY=$S3_DATA_KEY}" \
    --region "$AWS_REGION" > /dev/null
fi

rm -rf "$BUILD_DIR"
echo "  Lambda deployed."

# ── Step 6: Create API Gateway HTTP API ──────────────────────────────────────
echo ""
echo "[6/6] Setting up API Gateway..."

LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$LAMBDA_FUNCTION" \
  --region "$AWS_REGION" \
  --query 'Configuration.FunctionArn' --output text)

API_ID=$(aws apigatewayv2 get-apis \
  --region "$AWS_REGION" \
  --query "Items[?Name=='$API_NAME'].ApiId" --output text 2>/dev/null || true)

if [ -z "$API_ID" ]; then
  echo "  Creating HTTP API..."
  API_ID=$(aws apigatewayv2 create-api \
    --name "$API_NAME" \
    --protocol-type HTTP \
    --tags "$TAGS_JSON" \
    --region "$AWS_REGION" \
    --query 'ApiId' --output text)

  # Integration
  INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "$LAMBDA_ARN" \
    --payload-format-version "2.0" \
    --region "$AWS_REGION" \
    --query 'IntegrationId' --output text)

  # Catch-all route
  aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key 'ANY /{proxy+}' \
    --target "integrations/$INTEGRATION_ID" \
    --region "$AWS_REGION" > /dev/null

  aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key 'GET /' \
    --target "integrations/$INTEGRATION_ID" \
    --region "$AWS_REGION" > /dev/null

  # Auto-deploy stage
  aws apigatewayv2 create-stage \
    --api-id "$API_ID" \
    --stage-name '$default' \
    --auto-deploy \
    --region "$AWS_REGION" > /dev/null

  # Allow API Gateway to invoke Lambda
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  aws lambda add-permission \
    --function-name "$LAMBDA_FUNCTION" \
    --statement-id "apigateway-invoke" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
    --region "$AWS_REGION" > /dev/null

  echo "  API Gateway created."
else
  echo "  API Gateway already exists: $API_ID"
fi

API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Deployment complete!"
echo "============================================"
echo ""
echo "  API URL: $API_URL"
echo ""
echo "  Example requests:"
echo "    curl '$API_URL/'"
echo "    curl '$API_URL/regions/Nord'"
echo "    curl '$API_URL/regions/Bayern'"
echo "    curl '$API_URL/forecast?region=Nord&anlagenart=Windenergie%20an%20Land&year=2045'"
echo ""
echo "  Tags applied: course=CDUS | semester=SoSe26 | university=HSB"
echo ""
echo "  S3 data: s3://$S3_BUCKET/$S3_DATA_KEY"
echo "  Lambda:  $LAMBDA_FUNCTION ($AWS_REGION)"
echo ""
