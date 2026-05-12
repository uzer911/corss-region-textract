# Cross-Region Lambda Invoice Processing

This Lambda function processes invoices using AWS services across multiple regions to optimize for service availability and quota allocation.

## Cross-Region Architecture
                                                                       https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
```
┌─────────────────────────────────────────────────────────────┐
│                     Lambda Function                          │
│                   (Any AWS Region)                           │
└─────────────────────────────────────────────────────────────┘
                            │
            ┌───────────────┼───────────────┐
            │               │               │
            ▼               ▼               ▼
    ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
    │   Textract   │ │   Bedrock    │ │  S3 + DynamoDB│
    │ eu-central-1 │ │ eu-north-1   │ │  Lambda Region│
    │  (Frankfurt) │ │  (Stockholm) │ │               │
    └──────────────┘ └──────────────┘ └──────────────┘
```

## Why Cross-Region?

- **Textract**: Available in `eu-central-1` (Frankfurt) but not in `eu-north-1`
- **Bedrock**: Quota available in `eu-north-1` (Stockholm)
- **S3 & DynamoDB**: Use the Lambda's deployment region for lowest latency

## Configuration

### Environment Variables

Set these in your Lambda configuration:

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `eu-central-1` | Lambda's region (auto-set) |
| `TEXTRACT_REGION` | `eu-central-1` | Region for Textract service |
| `BEDROCK_REGION` | `eu-north-1` | Region for Bedrock service |
| `TEXTRACT_OUTPUT_BUCKET` | _(optional)_ | S3 bucket for extracted text |

### Example Lambda Environment Variables

```json
{
  "TEXTRACT_REGION": "eu-central-1",
  "BEDROCK_REGION": "eu-north-1",
  "TEXTRACT_OUTPUT_BUCKET": "my-textract-output-bucket"
}
```

## IAM Permissions

Your Lambda execution role needs permissions for **cross-region** service access:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "textract:AnalyzeExpense"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "eu-central-1"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel"
      ],
      "Resource": "arn:aws:bedrock:eu-north-1::foundation-model/us.amazon.nova-micro-v1:0",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "eu-north-1"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::your-invoice-bucket/*",
        "arn:aws:s3:::your-textract-output-bucket/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem"
      ],
      "Resource": "arn:aws:dynamodb:*:*:table/invoices"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
```

## S3 Cross-Region Considerations

### Important: S3 Bucket Location

When Textract accesses an S3 object, the **S3 bucket must be in the same region as Textract** for optimal performance and to avoid potential access issues.

**Option 1: Single-Region S3 (Recommended for Simplicity)**
- Keep your invoice bucket in `eu-central-1` (same as Textract)
- Deploy Lambda in `eu-central-1`
- No cross-region S3 access needed

**Option 2: Cross-Region S3 (Current Setup)**
- If your S3 bucket is in a different region, Textract can still access it
- May incur cross-region data transfer costs
- Slightly higher latency

### Cross-Region Data Transfer Costs

Be aware of AWS data transfer pricing:
- **Textract reading from S3**: If S3 bucket is in a different region than Textract, you'll pay for data transfer OUT of the S3 region
- **Typical cost**: $0.02 per GB between EU regions
- **Recommendation**: For high-volume processing, co-locate S3 bucket with Textract in `eu-central-1`

## Deployment Steps

### 1. Create DynamoDB Table

```bash
aws dynamodb create-table \
    --table-name invoices \
    --attribute-definitions \
        AttributeName=invoice_id,AttributeType=S \
    --key-schema \
        AttributeName=invoice_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region eu-central-1
```

### 2. Create S3 Buckets

```bash
# Invoice upload bucket (should match Textract region)
aws s3 mb s3://my-invoice-uploads --region eu-central-1

# Output bucket for extracted text
aws s3 mb s3://my-textract-output --region eu-central-1
```

### 3. Enable Bedrock Model Access

```bash
# In Stockholm region, enable Nova Micro model
aws bedrock list-foundation-models \
    --region eu-north-1 \
    --query 'modelSummaries[?modelId==`us.amazon.nova-micro-v1:0`]'
```

Go to AWS Console → Bedrock → Model access (in eu-north-1) and enable `Amazon Nova Micro`.

### 4. Package and Deploy Lambda

```bash
# Create deployment package
zip lambda_function.zip lambda_function.py

# Create Lambda function
aws lambda create-function \
    --function-name invoice-processor \
    --runtime python3.11 \
    --role arn:aws:iam::YOUR_ACCOUNT_ID:role/lambda-execution-role \
    --handler lambda_function.lambda_handler \
    --zip-file fileb://lambda_function.zip \
    --timeout 300 \
    --memory-size 512 \
    --environment Variables="{
        TEXTRACT_REGION=eu-central-1,
        BEDROCK_REGION=eu-north-1,
        TEXTRACT_OUTPUT_BUCKET=my-textract-output
    }" \
    --region eu-central-1
```

### 5. Configure S3 Trigger

```bash
# Add S3 event notification
aws s3api put-bucket-notification-configuration \
    --bucket my-invoice-uploads \
    --notification-configuration file://s3-notification.json
```

**s3-notification.json:**
```json
{
  "LambdaFunctionConfigurations": [
    {
      "LambdaFunctionArn": "arn:aws:lambda:eu-central-1:YOUR_ACCOUNT_ID:function:invoice-processor",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {
              "Name": "suffix",
              "Value": ".pdf"
            }
          ]
        }
      }
    }
  ]
}
```

## Testing

### Upload a Test Invoice

```bash
aws s3 cp sample-invoice.pdf s3://my-invoice-uploads/ --region eu-central-1
```

### Check Lambda Logs

```bash
aws logs tail /aws/lambda/invoice-processor --follow --region eu-central-1
```

You should see:
```
Processing invoice: sample-invoice.pdf from bucket: my-invoice-uploads
Calling Textract in region: eu-central-1
Calling Bedrock in region: eu-north-1
Successfully processed invoice: sample-invoice.pdf
```

### Verify DynamoDB

```bash
aws dynamodb scan --table-name invoices --region eu-central-1
```

## Monitoring & Troubleshooting

### CloudWatch Metrics

Monitor these metrics:
- **Lambda Duration**: Should be < 60 seconds for typical invoices
- **Textract Errors**: Check for `400` errors (document too large)
- **Bedrock Throttling**: Monitor for `ThrottlingException`

### Common Issues

**1. Textract "Access Denied"**
- **Cause**: Lambda role lacks `textract:AnalyzeExpense` permission in `eu-central-1`
- **Fix**: Update IAM role with cross-region permissions

**2. Bedrock "Model Not Found"**
- **Cause**: Nova model not enabled in `eu-north-1`
- **Fix**: Enable model access in Bedrock console for Stockholm region

**3. S3 Cross-Region Timeout**
- **Cause**: Large invoice in different region than Textract
- **Fix**: Move S3 bucket to `eu-central-1` or increase Lambda timeout

**4. DynamoDB "Table Not Found"**
- **Cause**: Table exists in wrong region
- **Fix**: Create table in same region as Lambda

### Debug Logging

The function logs which region each service uses:
```
Calling Textract in region: eu-central-1
Calling Bedrock in region: eu-north-1
```

Check CloudWatch Logs to verify correct routing.

## Cost Optimization

### Regional Cost Differences

| Service | Region | Cost (per 1000 requests) |
|---------|--------|--------------------------|
| Textract | eu-central-1 | ~$1.50 |
| Bedrock Nova Micro | eu-north-1 | ~$0.11 (input) / $0.44 (output) |
| Lambda | eu-central-1 | ~$0.20 |

### Tips to Reduce Costs

1. **Use Bedrock rate limiting**: Already implemented in code (10 req/min)
2. **Cache Textract results**: Store in S3 to avoid re-processing
3. **Batch processing**: Process multiple invoices in one Lambda invocation
4. **Right-size Lambda**: 512MB is sufficient for most invoices

## Advanced Configuration

### Using Different Regions

To use different regions, update environment variables:

```bash
# Use Ireland for Textract, Stockholm for Bedrock
aws lambda update-function-configuration \
    --function-name invoice-processor \
    --environment Variables="{
        TEXTRACT_REGION=eu-west-1,
        BEDROCK_REGION=eu-north-1
    }" \
    --region eu-central-1
```

### Supported Textract Regions

Textract `AnalyzeExpense` is available in:
- `us-east-1`, `us-east-2`, `us-west-2`
- `eu-west-1`, `eu-west-2`, `eu-central-1`
- `ap-south-1`, `ap-southeast-1`, `ap-southeast-2`, `ap-northeast-2`
- `ca-central-1`

### Supported Bedrock Regions for Nova Models

Nova models are available in:
- `us-east-1`, `us-west-2`
- `eu-west-1`, `eu-north-1`
- `ap-southeast-1`, `ap-southeast-2`

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                   │
│  User uploads invoice.pdf to S3 (eu-central-1)                  │
│                                                                   │
└─────────────────────────┬───────────────────────────────────────┘
                          │
                          │ S3 Event Notification
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                                                                   │
│  Lambda Function (eu-central-1)                                 │
│  ┌────────────────────────────────────────────────────┐         │
│  │  1. Extract bucket & key from event                │         │
│  │  2. Call Textract (eu-central-1) ────────┐         │         │
│  │  3. Parse invoice data                   │         │         │
│  │  4. Call Bedrock (eu-north-1) ──────┐    │         │         │
│  │  5. Save to DynamoDB                │    │         │         │
│  │  6. Save text to S3                 │    │         │         │
│  └─────────────────────────────────────┼────┼─────────┘         │
│                                         │    │                   │
└─────────────────────────────────────────┼────┼───────────────────┘
                                          │    │
                    ┌─────────────────────┘    └──────────────────┐
                    ▼                                              ▼
    ┌───────────────────────────┐              ┌──────────────────────────┐
    │  Bedrock (eu-north-1)    │              │  Textract (eu-central-1) │
    │  - Nova Micro model      │              │  - AnalyzeExpense API    │
    │  - Analyze invoice       │              │  - Extract fields        │
    │  - Check inconsistencies │              │  - Parse line items      │
    └───────────────────────────┘              └──────────────────────────┘
                    │
                    ▼
    ┌───────────────────────────────────────────────────────────────┐
    │  Results Stored (eu-central-1)                                │
    │  ┌─────────────────────┐       ┌────────────────────────┐    │
    │  │  DynamoDB Table     │       │  S3 Processed Text     │    │
    │  │  - invoice_id       │       │  - extracted_text.txt  │    │
    │  │  - line_items       │       │  - bedrock_analysis    │    │
    │  │  - llm_analysis     │       └────────────────────────┘    │
    │  └─────────────────────┘                                      │
    └───────────────────────────────────────────────────────────────┘
```

## Security Best Practices

1. **Least Privilege IAM**: Only grant permissions for specific regions
2. **Encrypt at Rest**: Enable S3 and DynamoDB encryption
3. **VPC Endpoints**: Use VPC endpoints to avoid internet routing (optional)
4. **Secrets Management**: Use AWS Secrets Manager for API keys if needed
5. **CloudTrail**: Enable logging for all API calls

## License

CloudAge
