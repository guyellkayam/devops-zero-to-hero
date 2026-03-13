# 01 — AWS Account Security Setup

## Why This Matters
Your AWS root account has unlimited power. If someone gets access, they can spin up
hundreds of expensive instances, delete everything, or mine crypto on your bill.
This guide locks it down BEFORE you build anything.

---

## Step 1: Enable MFA on Root Account

MFA (Multi-Factor Authentication) adds a second layer — even if your password leaks,
attackers can't get in without your phone.

### How:
1. Log into AWS Console as **root** (the email you signed up with)
2. Click your account name (top-right) → **Security credentials**
3. Under **Multi-factor authentication (MFA)** → click **Assign MFA device**
4. Choose **Authenticator app**
5. Scan the QR code with your phone app:
   - **Google Authenticator** (free, simple)
   - **Authy** (free, has backup — recommended)
   - **1Password** (if you use it)
6. Enter 2 consecutive codes from the app
7. Click **Assign MFA**

> **IMPORTANT**: Save the QR code or secret key somewhere safe (password manager).
> If you lose your phone and don't have the backup, you'll be locked out of root.

---

## Step 2: Create an IAM Admin User

**Rule**: Never use root for daily work. Create a separate IAM user.

### How:
1. Go to **IAM** → **Users** → **Create user**
2. User name: `devops-admin`
3. Check **Provide user access to the AWS Management Console**
4. Choose **I want to create an IAM user** (not Identity Center for now)
5. Set a strong password
6. Click **Next**
7. **Permissions**:
   - Choose **Attach policies directly**
   - Search and check: `AdministratorAccess`
   - (We'll scope this down later — for now you need full access to set things up)
8. Click **Next** → **Create user**
9. **SAVE the sign-in URL** — it looks like: `https://123456789012.signin.aws.amazon.com/console`

### Enable MFA on IAM User Too:
1. Go to **IAM** → **Users** → `devops-admin`
2. **Security credentials** tab → **Assign MFA device**
3. Same process as root

### Create Access Keys (for CLI):
1. Go to **IAM** → **Users** → `devops-admin` → **Security credentials**
2. Scroll to **Access keys** → **Create access key**
3. Choose **Command Line Interface (CLI)**
4. Check the acknowledgment checkbox
5. Click **Create access key**
6. **SAVE both keys immediately**:
   - Access Key ID: `AKIA...`
   - Secret Access Key: `wJal...`

> **WARNING**: The secret key is shown ONLY ONCE. If you lose it, you must create new keys.
> NEVER commit these keys to Git. NEVER share them.

---

## Step 3: Set Up Billing Alarms

Without alerts, a misconfigured resource or attack can cost thousands before you notice.

### Create a Budget:
1. Go to **Billing** → **Budgets** → **Create budget**
2. Choose **Customize (advanced)**
3. Budget type: **Cost budget**
4. Name: `Monthly Limit`
5. Period: **Monthly**, Recurring
6. Budget amount: **$50** (covers our ~$25-45/mo target)
7. **Add alert thresholds**:
   - Alert 1: 50% ($25) — informational
   - Alert 2: 80% ($40) — warning
   - Alert 3: 100% ($50) — critical
8. Add your **email** for notifications
9. Click **Create budget**

### Enable Cost Explorer://need to do that 
1. Go to **Billing** → **Cost Explorer**
2. Click **Enable Cost Explorer**
3. It takes ~24 hours to populate data

---

## Step 4: Enable CloudTrail

CloudTrail logs every API call in your account. Essential for security auditing.

### How:
1. Go to **CloudTrail** → **Create trail**
2. Trail name: `main-trail`
3. Choose **Create a new S3 bucket** (it will name it automatically)
4. **Log events**: Management events (read + write) — this is the free tier
5. Click **Next** → **Create trail**

> **Free**: 1 trail with management events = $0.
> Data events (S3 object-level, Lambda) cost extra — skip for now.

---

## Step 5: Log Out of Root — Use IAM User From Now On

1. Sign out of root
2. Go to your IAM sign-in URL: `https://ACCOUNT_ID.signin.aws.amazon.com/console`
3. Log in as `devops-admin`
4. Verify MFA works

> **From this point on, you should NEVER log in as root again**
> unless you need to change account-level settings (like closing the account).

---

## Step 6: Configure AWS CLI on Your Laptop

```bash
# Run this in your terminal
aws configure

# It will ask:
# AWS Access Key ID: paste your access key
# AWS Secret Access Key: paste your secret key
# Default region name: us-east-1  (or your preferred region)
# Default output format: json
```

### Verify:
```bash
aws sts get-caller-identity
```

Expected output:
```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/devops-admin"
}
```

If you see your account ID and username — you're connected securely.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Unable to locate credentials" | Run `aws configure` again |
| MFA device lost | Use root recovery process (requires email + phone) |
| Budget alerts not arriving | Check spam folder, verify email in Budget settings |
| CloudTrail not showing events | Wait 15 minutes, events appear with delay |

---

## Security Checklist

- [ ] Root MFA enabled
- [ ] IAM user `devops-admin` created
- [ ] IAM user MFA enabled
- [ ] Access keys created and saved securely
- [ ] Billing budget set with email alerts
- [ ] Cost Explorer enabled
- [ ] CloudTrail enabled
- [ ] AWS CLI configured and verified
- [ ] Logged out of root, using IAM user only

---

## What's Next?
→ [02 — Local Tools Setup](02-local-tools-setup.md)
