#!/bin/bash

# Cross-Region Lambda Invoice Processor - Deployment Script
# This script deploys the Lambda function with cross-region AWS service configuration

set -e  # Exit on any error

# Configuration
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAMBDA_REGION="eu-central-1"
TEXTRACT_REGION="eu-central-1"
BEDROCK_REGION="eu-north-1"
FUNCTION_NAME="invoice_processing"
DYNAMODB_TABLE="invoices"
S3_INVOICE_BUCKET="textractmultiregion-eu-central-1"
S3_OUTPUT_BUCKET="textractmultiregion-eu-central-1"

echo "========================================="
echo "Cross-Region Invoice Processor Deployment"
echo "========================================="
echo "AWS Account: ${AWS_ACCOUNT_ID}"
echo "Lambda Region: ${LAMBDA_REGION}"
echo "Textract Region: ${TEXTRACT_REGION}"
echo "Bedrock Region: ${BEDROCK_REGION}"
echo "========================================="

# Step 1: Create DynamoDB Table
echo ""
echo "Step 1: Creating DynamoDB table '${DYNAMODB_TABLE}'..."
aws dynamodb create-table \
    --table-name ${DYNAMODB_TABLE} \
    --attribute-definitions AttributeName=invoice_id,AttributeType=S \
    --key-schema AttributeName=invoice_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region ${LAMBDA_REGION} \
    2>/dev/null || echo "Table already exists, skipping..."

# Step 2: Create S3 Buckets
echo ""
echo "Step 2: Creating S3 buckets..."
aws s3 mb s3://${S3_INVOICE_BUCKET} --region ${LAMBDA_REGION} 2>/dev/null || echo "Invoice bucket already exists"
aws s3 mb s3://${S3_OUTPUT_BUCKET} --region ${LAMBDA_REGION} 2>/dev/null || echo "Output bucket already exists"

# Step 3: Create IAM Role
echo ""
echo "Step 3: Creating IAM execution role..."
ROLE_NAME="${FUNCTION_NAME}-role"

# Create trust policy
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create role
aws iam create-role \
    --role-name ${ROLE_NAME} \
    --assume-role-policy-document file:///tmp/trust-policy.json \
    2>/dev/null || echo "Role already exists"

# Attach policy
aws iam put-role-policy \
    --role-name ${ROLE_NAME} \
    --policy-name ${ROLE_NAME}-policy \
    --policy-document file://iam-policy.json

echo "Waiting 10 seconds for IAM role to propagate..."
sleep 10

# Step 4: Package Lambda Function
echo ""
echo "Step 4: Packaging Lambda function..."
zip -q lambda_function.zip lambda_function.py
echo "Created lambda_function.zip"

# Step 5: Deploy Lambda Function
echo ""
echo "Step 5: Deploying Lambda function..."
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

aws lambda create-function \
    --function-name ${FUNCTION_NAME} \
    --runtime python3.11 \
    --role ${ROLE_ARN} \
    --handler lambda_function.lambda_handler \
    --zip-file fileb://lambda_function.zip \
    --timeout 300 \
    --memory-size 512 \
    --environment Variables="{TEXTRACT_REGION=${TEXTRACT_REGION},BEDROCK_REGION=${BEDROCK_REGION},TEXTRACT_OUTPUT_BUCKET=${S3_OUTPUT_BUCKET}}" \
    --region ${LAMBDA_REGION} \
    2>/dev/null && echo "Lambda function created successfully!" || {
        echo "Function already exists, updating code..."
        aws lambda update-function-code \
            --function-name ${FUNCTION_NAME} \
            --zip-file fileb://lambda_function.zip \
            --region ${LAMBDA_REGION}
        
        aws lambda update-function-configuration \
            --function-name ${FUNCTION_NAME} \
            --environment Variables="{TEXTRACT_REGION=${TEXTRACT_REGION},BEDROCK_REGION=${BEDROCK_REGION},TEXTRACT_OUTPUT_BUCKET=${S3_OUTPUT_BUCKET}}" \
            --region ${LAMBDA_REGION}
    }

# Step 6: Add Lambda Permission for S3
echo ""
echo "Step 6: Granting S3 permission to invoke Lambda..."
LAMBDA_ARN="arn:aws:lambda:${LAMBDA_REGION}:${AWS_ACCOUNT_ID}:function:${FUNCTION_NAME}"

aws lambda add-permission \
    --function-name ${FUNCTION_NAME} \
    --statement-id s3-trigger-permission \
    --action lambda:InvokeFunction \
    --principal s3.amazonaws.com \
    --source-arn arn:aws:s3:::${S3_INVOICE_BUCKET} \
    --region ${LAMBDA_REGION} \
    2>/dev/null || echo "Permission already exists"

# Step 7: Configure S3 Event Notification
echo ""
echo "Step 7: Configuring S3 trigger..."
cat > /tmp/s3-notification.json <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "s3-trigger",
      "LambdaFunctionArn": "${LAMBDA_ARN}",
      "Events": ["s3:ObjectCreated:*"]
    }
  ]
}
EOF

aws s3api put-bucket-notification-configuration \
    --bucket ${S3_INVOICE_BUCKET} \
    --notification-configuration file:///tmp/s3-notification.json

echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "📦 Resources Created:"
echo "  ✓ DynamoDB Table: ${DYNAMODB_TABLE} (${LAMBDA_REGION})"
echo "  ✓ S3 Invoice Bucket: ${S3_INVOICE_BUCKET} (${LAMBDA_REGION})"
echo "  ✓ S3 Output Bucket: ${S3_OUTPUT_BUCKET} (${LAMBDA_REGION})"
echo "  ✓ IAM Role: ${ROLE_NAME}"
echo "  ✓ Lambda Function: ${FUNCTION_NAME} (${LAMBDA_REGION})"
echo ""
echo "🌍 Cross-Region Configuration:"
echo "  ✓ Textract: ${TEXTRACT_REGION} (Frankfurt)"
echo "  ✓ Bedrock: ${BEDROCK_REGION} (Stockholm)"
echo ""
echo "📝 Next Steps:"
echo "  1. Enable Amazon Nova Micro in Bedrock (${BEDROCK_REGION})"
echo "     AWS Console → Bedrock → Model access → Enable model"
echo ""
echo "  2. Test with sample invoice:"
echo "     aws s3 cp sample-invoice.pdf s3://${S3_INVOICE_BUCKET}/"
echo ""
echo "  3. Monitor logs:"
echo "     aws logs tail /aws/lambda/${FUNCTION_NAME} --follow --region ${LAMBDA_REGION}"
echo ""
echo "  4. Check results:"
echo "     aws dynamodb scan --table-name ${DYNAMODB_TABLE} --region ${LAMBDA_REGION}"
echo ""
echo "========================================="

# Cleanup temp files
rm -f /tmp/trust-policy.json /tmp/s3-notification.json
