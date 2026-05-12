# Testing Guide for Cross-Region Invoice Processor

## Quick Test Checklist

- [ ] Bedrock model enabled in eu-north-1
- [ ] Lambda deployed with correct environment variables
- [ ] IAM role has cross-region permissions
- [ ] S3 buckets created
- [ ] DynamoDB table exists
- [ ] invoice uploaded

## Pre-Deployment Verification

### 1. Check Bedrock Model Access

```bash
# List available models in Stockholm
aws bedrock list-foundation-models \
    --region eu-north-1 \
    --query 'modelSummaries[?modelId==`us.amazon.nova-micro-v1:0`]' \
    --output json

# If empty, enable model access in console:
# https://eu-north-1.console.aws.amazon.com/bedrock/home?region=eu-north-1#/modelaccess
```

Expected output:
```json
[
  {
    "modelArn": "arn:aws:bedrock:eu-north-1::foundation-model/us.amazon.nova-micro-v1:0",
    "modelId": "us.amazon.nova-micro-v1:0",
    "modelName": "Nova Micro"
  }
]
```

### 2. Verify Textract Availability

```bash
# Check Textract service in Frankfurt
aws textract help --region eu-central-1

# Should show available commands including analyze-expense
```

### 3. Test IAM Permissions

```bash
# Verify Lambda role can assume correctly
aws iam get-role --role-name invoice-processor-role

# Check attached policies
aws iam get-role-policy \
    --role-name invoice-processor-role \
    --policy-name invoice-processor-role-policy
```

## Testing the Lambda Function

### Test 1: Manual Invocation with Test Event

Create a test event file:

```bash
cat > test-event.json <<'EOF'
{
  "Records": [
    {
      "s3": {
        "bucket": {
          "name": "invoice-uploads-YOUR_ACCOUNT_ID"
        },
        "object": {
          "key": "test-invoice.pdf"
        }
      }
    }
  ]
}
EOF
```

Upload a sample invoice:
```bash
# Create or use existing invoice PDF
aws s3 cp sample-invoice.pdf s3://invoice-uploads-YOUR_ACCOUNT_ID/test-invoice.pdf
```

Invoke Lambda manually:
```bash
aws lambda invoke \
    --function-name invoice-processor \
    --payload file://test-event.json \
    --region eu-central-1 \
    response.json

# Check response
cat response.json
```

Expected response:
```json
{
  "statusCode": 200,
  "body": "\"Invoice successfully processed!\""
}
```

### Test 2: S3 Trigger (Real-World Test)

```bash
# Upload invoice directly to S3 (triggers Lambda automatically)
aws s3 cp sample-invoice.pdf s3://invoice-uploads-YOUR_ACCOUNT_ID/invoice-001.pdf

# Wait a few seconds, then check logs
aws logs tail /aws/lambda/invoice-processor --follow --region eu-central-1
```

Expected log output:
```
START RequestId: abc-123-def-456
Processing invoice: invoice-001.pdf from bucket: invoice-uploads-12345
Calling Textract in region: eu-central-1
Calling Bedrock in region: eu-north-1
Successfully inserted invoice INV-001 into DynamoDB
Saved text to source bucket: invoice-uploads-12345/processed-text/invoice-001.txt
Successfully processed invoice: invoice-001.pdf
END RequestId: abc-123-def-456
```

### Test 3: Verify Data Storage

#### Check DynamoDB:
```bash
aws dynamodb scan \
    --table-name invoices \
    --region eu-central-1 \
    --output json
```

Expected output:
```json
{
  "Items": [
    {
      "invoice_id": {"S": "INV-001"},
      "invoice_number": {"S": "INV-001"},
      "total": {"S": "$1,234.56"},
      "due_date": {"S": "2024-03-15"},
      "receipt_date": {"S": "2024-03-01"},
      "line_items": {
        "L": [
          {
            "M": {
              "item": {"S": "Product A"},
              "price": {"S": "$500.00"}
            }
          }
        ]
      },
      "llm_analysis": {"S": "No inconsistencies found..."}
    }
  ],
  "Count": 1,
  "ScannedCount": 1
}
```

#### Check S3 Output:
```bash
# List processed text files
aws s3 ls s3://textract-output-YOUR_ACCOUNT_ID/

# Download and view extracted text
aws s3 cp s3://invoice-uploads-YOUR_ACCOUNT_ID/processed-text/invoice-001.txt - | head -20
```

## Load Testing

### Test Bedrock Rate Limiting

Create multiple invoices to test rate limiter:

```bash
# Upload 20 invoices rapidly
for i in {1..20}; do
  aws s3 cp sample-invoice.pdf \
    s3://invoice-uploads-YOUR_ACCOUNT_ID/invoice-batch-$i.pdf &
done
wait

# Monitor processing
aws logs tail /aws/lambda/invoice-processor --follow --region eu-central-1
```

You should see rate limiting in action:
```
ThrottlingException: Retry 1/4 after 2.34s
ThrottlingException: Retry 2/4 after 4.67s
```

### Test Concurrent Processing

```bash
# Enable reserved concurrency (optional)
aws lambda put-function-concurrency \
    --function-name invoice-processor \
    --reserved-concurrent-executions 5 \
    --region eu-central-1

# Upload batch and monitor
for i in {1..50}; do
  aws s3 cp sample-invoice.pdf \
    s3://invoice-uploads-YOUR_ACCOUNT_ID/concurrent-$i.pdf
done
```

## Troubleshooting Common Issues

### Issue 1: "AccessDeniedException" from Textract

**Symptom:**
```
ClientError: An error occurred (AccessDeniedException) when calling the AnalyzeExpense operation
```

**Diagnosis:**
```bash
# Check if Lambda role has Textract permissions
aws iam simulate-principal-policy \
    --policy-source-arn arn:aws:iam::YOUR_ACCOUNT_ID:role/invoice-processor-role \
    --action-names textract:AnalyzeExpense \
    --resource-arns "*"
```

**Fix:**
```bash
# Ensure IAM policy includes Textract permissions
aws iam put-role-policy \
    --role-name invoice-processor-role \
    --policy-name invoice-processor-role-policy \
    --policy-document file://iam-policy.json
```

### Issue 2: "ResourceNotFoundException" for Bedrock Model

**Symptom:**
```
ClientError: An error occurred (ResourceNotFoundException) when calling the InvokeModel operation
```

**Diagnosis:**
```bash
# Check if model is enabled in Stockholm
aws bedrock list-foundation-models \
    --region eu-north-1 \
    --output json | grep nova-micro
```

**Fix:**
1. Go to AWS Console → Bedrock (eu-north-1)
2. Navigate to "Model access"
3. Enable "Amazon Nova Micro"
4. Wait 2-3 minutes for activation

### Issue 3: "ThrottlingException" - Daily Quota Exceeded

**Symptom:**
```
Daily token quota exceeded. Skipping retries.
```

**Diagnosis:**
```bash
# Check CloudWatch metrics for Bedrock usage
aws cloudwatch get-metric-statistics \
    --namespace AWS/Bedrock \
    --metric-name InvocationCount \
    --dimensions Name=ModelId,Value=us.amazon.nova-micro-v1:0 \
    --start-time $(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 3600 \
    --statistics Sum \
    --region eu-north-1
```

**Fix:**
- Wait until quota resets (midnight UTC)
- Request quota increase via AWS Support
- Reduce `max_requests_per_minute` in code

### Issue 4: S3 "NoSuchBucket" Error

**Symptom:**
```
Failed to save to configured bucket textract-output-12345: NoSuchBucket
```

**Diagnosis:**
```bash
# Check if bucket exists
aws s3 ls s3://textract-output-YOUR_ACCOUNT_ID 2>&1
```

**Fix:**
```bash
# Create the bucket
aws s3 mb s3://textract-output-YOUR_ACCOUNT_ID --region eu-central-1

# Or update Lambda environment variable to use existing bucket
aws lambda update-function-configuration \
    --function-name invoice-processor \
    --environment Variables="{TEXTRACT_REGION=eu-central-1,BEDROCK_REGION=eu-north-1,TEXTRACT_OUTPUT_BUCKET=my-existing-bucket}" \
    --region eu-central-1
```

### Issue 5: Lambda Timeout

**Symptom:**
```
Task timed out after 3.00 seconds
```

**Diagnosis:**
```bash
# Check average execution duration
aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Duration \
    --dimensions Name=FunctionName,Value=invoice-processor \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Average,Maximum \
    --region eu-central-1
```

**Fix:**
```bash
# Increase timeout to 5 minutes
aws lambda update-function-configuration \
    --function-name invoice-processor \
    --timeout 300 \
    --region eu-central-1
```

### Issue 6: Cross-Region Latency

**Symptom:**
Slow processing times (>60 seconds per invoice)

**Diagnosis:**
```bash
# Check logs for timing breakdown
aws logs filter-log-events \
    --log-group-name /aws/lambda/invoice-processor \
    --filter-pattern "Calling" \
    --region eu-central-1
```

**Optimization:**
1. Co-locate S3 bucket with Textract (eu-central-1)
2. Use VPC endpoints for AWS services
3. Increase Lambda memory (more CPU)

## Monitoring Dashboard

### Create CloudWatch Dashboard

```bash
cat > dashboard.json <<'EOF'
{
  "widgets": [
    {
      "type": "metric",
      "properties": {
        "metrics": [
          ["AWS/Lambda", "Invocations", {"stat": "Sum", "label": "Total Invocations"}],
          [".", "Errors", {"stat": "Sum", "label": "Errors"}],
          [".", "Throttles", {"stat": "Sum", "label": "Throttles"}]
        ],
        "period": 300,
        "stat": "Average",
        "region": "eu-central-1",
        "title": "Lambda Metrics",
        "yAxis": {
          "left": {
            "min": 0
          }
        }
      }
    },
    {
      "type": "metric",
      "properties": {
        "metrics": [
          ["AWS/Bedrock", "InvocationCount", {"stat": "Sum", "label": "Bedrock Calls"}],
          [".", "InvocationClientErrors", {"stat": "Sum", "label": "Client Errors"}],
          [".", "InvocationServerErrors", {"stat": "Sum", "label": "Server Errors"}]
        ],
        "period": 300,
        "stat": "Average",
        "region": "eu-north-1",
        "title": "Bedrock Metrics (Stockholm)"
      }
    }
  ]
}
EOF

aws cloudwatch put-dashboard \
    --dashboard-name invoice-processor \
    --dashboard-body file://dashboard.json \
    --region eu-central-1
```

### Set Up Alarms

```bash
# Alarm for Lambda errors
aws cloudwatch put-metric-alarm \
    --alarm-name invoice-processor-errors \
    --alarm-description "Alert when Lambda function errors" \
    --metric-name Errors \
    --namespace AWS/Lambda \
    --statistic Sum \
    --period 300 \
    --threshold 5 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 1 \
    --dimensions Name=FunctionName,Value=invoice-processor \
    --region eu-central-1

# Alarm for Bedrock throttling
aws cloudwatch put-metric-alarm \
    --alarm-name bedrock-throttling \
    --alarm-description "Alert on Bedrock throttling" \
    --metric-name InvocationClientErrors \
    --namespace AWS/Bedrock \
    --statistic Sum \
    --period 300 \
    --threshold 10 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 2 \
    --dimensions Name=ModelId,Value=us.amazon.nova-micro-v1:0 \
    --region eu-north-1
```

## Performance Benchmarks

### Expected Performance

| Metric | Value |
|--------|-------|
| Cold Start | 2-3 seconds |
| Warm Execution | 5-15 seconds |
| Textract Call | 2-5 seconds |
| Bedrock Call | 3-8 seconds |
| DynamoDB Write | <1 second |
| S3 Write | <1 second |

### Optimization Targets

- **99th percentile**: <30 seconds
- **Error rate**: <1%
- **Throttle rate**: <5%

## Cleanup After Testing

```bash
# Delete test data from DynamoDB
aws dynamodb delete-table \
    --table-name invoices \
    --region eu-central-1

# Empty and delete S3 buckets
aws s3 rm s3://invoice-uploads-YOUR_ACCOUNT_ID --recursive
aws s3 rb s3://invoice-uploads-YOUR_ACCOUNT_ID

aws s3 rm s3://textract-output-YOUR_ACCOUNT_ID --recursive
aws s3 rb s3://textract-output-YOUR_ACCOUNT_ID

# Delete Lambda function
aws lambda delete-function \
    --function-name invoice-processor \
    --region eu-central-1

# Delete IAM role
aws iam delete-role-policy \
    --role-name invoice-processor-role \
    --policy-name invoice-processor-role-policy

aws iam delete-role \
    --role-name invoice-processor-role
```

## Success Criteria

✅ All tests pass without errors
✅ Logs show correct regions for each service
✅ DynamoDB contains processed invoice data
✅ S3 contains extracted text files
✅ Bedrock analysis is included in results
✅ No throttling errors (or handled gracefully)
✅ Average execution time <30 seconds
