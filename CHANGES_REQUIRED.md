# Changes Required Before Deployment

Before deploying this project, you need to fix **4 things** in 2 files.

---

## File 1: `lambda_function.py`

### Change 1 — Fix the Bedrock Model ID

Find this line (around line 230):
```python
model_id = 'amazon.nova-micro-v1:0'
```

Change it to:
```python
model_id = 'eu.amazon.nova-micro-v1:0'
```

**Why?** The `eu.` prefix is required when calling Bedrock from a different region (cross-region call). Without it, you get a "Model Not Found" error.

---

## File 2: `iam-policy.json`

### Change 2 — Fix the Bedrock Permission ARN

Find this line:
```
arn:aws:bedrock:eu-north-1::foundation-model/us.amazon.nova-micro-v1:0
```

Change it to:
```
arn:aws:bedrock:eu-north-1::foundation-model/eu.amazon.nova-micro-v1:0
```

**Why?** The ARN must match the model ID we use in the code. `us.` was wrong for EU region.

---

### Change 3 — Fix the Invalid S3 Action

Find these two lines (they appear twice in the file):
```
"s3:HeadBucket"
```

Change both to:
```
"s3:ListBucket"
```

**Why?** `s3:HeadBucket` does not exist as an IAM permission. AWS will reject the policy with an error. The correct action is `s3:ListBucket`.

---

### Change 4 — Fix the S3 Bucket Name

Find this section:
```json
"Resource": [
    "arn:aws:s3:::*-invoice-uploads/*",
    "arn:aws:s3:::textract-ml-ai-*/*",
    "arn:aws:s3:::textract-processed-invoices/*"
]
```

Change it to your actual bucket name:
```json
"Resource": [
    "arn:aws:s3:::YOUR-BUCKET-NAME/*"
]
```

**Why?** The policy must point to your actual S3 bucket. Replace `YOUR-BUCKET-NAME` with the name of the bucket you created in AWS.

---

## Summary

| # | File | What to Change | Why |
|---|------|---------------|-----|
| 1 | `lambda_function.py` | `amazon.nova-micro-v1:0` → `eu.amazon.nova-micro-v1:0` | Cross-region Bedrock requires `eu.` prefix |
| 2 | `iam-policy.json` | Bedrock ARN `us.` → `eu.` | Must match the model ID in code |
| 3 | `iam-policy.json` | `s3:HeadBucket` → `s3:ListBucket` (x2) | `HeadBucket` is not a valid IAM action |
| 4 | `iam-policy.json` | Replace S3 bucket ARNs with your bucket name | Policy must point to your actual bucket |
