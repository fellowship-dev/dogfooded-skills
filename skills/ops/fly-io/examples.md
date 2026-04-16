# Fly.io Deployment Skill - Usage Examples

This document provides concrete examples of how to use the flyio-deployment skill for common scenarios.

## Example 1: First-Time Deployment

### Scenario
You have a Node.js application with PostgreSQL database that you want to deploy to Fly.io for the first time.

### User Prompt
"I need to deploy my Express.js app to Fly.io. It uses PostgreSQL and needs environment variables for API keys."

### Expected Workflow

1. **Install and authenticate flyctl**
```bash
curl -L https://fly.io/install.sh | sh
export FLYCTL_INSTALL="/home/user/.fly"
export PATH="$FLYCTL_INSTALL/bin:$PATH"
flyctl auth login
```

2. **Create PostgreSQL database**
```bash
flyctl postgres create
# Choose name: myapp-db
# Select region: iad (closest to users)
# Choose tier: Development (start small)
```

3. **Launch application**
```bash
flyctl launch
# Choose app name: myapp
# Select same region as database: iad
# Decline immediate deployment
```

4. **Configure fly.toml**
```toml
app = "myapp"
primary_region = "iad"

[env]
  PORT = "8080"
  HOST = "::"
  NODE_ENV = "production"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = true
  auto_start_machines = true
```

5. **Attach database and set secrets**
```bash
flyctl pg attach myapp-db -a myapp
flyctl secrets set API_KEY="your-key" -a myapp
flyctl secrets set SESSION_SECRET="your-secret" -a myapp
```

6. **Deploy**
```bash
flyctl deploy -a myapp
flyctl open -a myapp
```

## Example 2: Database Migration

### Scenario
You need to migrate data from a local PostgreSQL database to your Fly.io production database.

### User Prompt
"Copy my local database to Fly.io production database."

### Expected Workflow

1. **Export local database**
```bash
pg_dump -Fc --no-acl --no-owner -h localhost -U postgres -d myapp > local_backup.dump
```

2. **Start Fly.io database proxy (Terminal 1)**
```bash
flyctl proxy 5433 -a myapp-db
```

3. **Import to Fly.io (Terminal 2)**
```bash
# Get database credentials from Fly.io dashboard
DB_USER="postgres"
DB_NAME="myapp"
pg_restore --verbose --clean --no-acl --no-owner \
  -h localhost -p 5433 -U $DB_USER -d "$DB_NAME" local_backup.dump
```

4. **Verify migration**
```bash
flyctl ssh console -a myapp
# Inside container: connect to database and verify data
psql $DATABASE_URL -c "SELECT COUNT(*) FROM users;"
```

5. **Clean up**
```bash
rm local_backup.dump
```

## Example 3: GitHub Actions CI/CD

### Scenario
Set up automated deployments to Fly.io when code is pushed to the main branch.

### User Prompt
"Set up GitHub Actions to automatically deploy to Fly.io when I push to main."

### Expected Workflow

1. **Generate Fly.io API token**
```bash
flyctl auth token
# Copy the token output
```

2. **Add GitHub secrets**
- Go to repository Settings > Secrets and variables > Actions
- Add `FLY_API_TOKEN` with the token from step 1
- Add `ENV_PASS` with your encryption password (if using encrypted .env)

3. **Create workflow file**

Create `.github/workflows/deploy-flyio.yml`:

```yaml
name: Deploy to Fly.io

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: superfly/flyctl-actions/setup-flyctl@master

      - name: Decrypt environment
        run: |
          openssl enc -aes-256-cbc -pbkdf2 -salt -d \
            -in .env.enc.prod -out .env -k ${{ secrets.ENV_PASS }}

      - name: Deploy to Fly.io
        run: flyctl deploy --remote-only
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}

      - name: Health check
        run: |
          sleep 30
          curl --fail https://myapp.fly.dev/health
```

4. **Test workflow**
```bash
git add .github/workflows/deploy-flyio.yml
git commit -m "Add Fly.io deployment workflow"
git push origin main
# Watch Actions tab in GitHub for deployment progress
```

## Example 4: Custom Domain Setup

### Scenario
Add a custom domain with SSL to your Fly.io application.

### User Prompt
"Add my custom domain myapp.com to my Fly.io deployment with SSL."

### Expected Workflow

1. **Create certificate**
```bash
flyctl certs create myapp.com -a myapp
flyctl certs create www.myapp.com -a myapp
```

2. **Get DNS configuration**
```bash
flyctl certs show myapp.com -a myapp
# Note the DNS challenge values
```

3. **Configure DNS records**
Add these records to your DNS provider:
```
A     @       <IPv4-from-flyctl>
AAAA  @       <IPv6-from-flyctl>
CNAME www     myapp.fly.dev
```

4. **Wait for DNS propagation**
```bash
# Check DNS propagation
dig myapp.com
dig www.myapp.com

# Monitor certificate status
flyctl certs show myapp.com -a myapp
```

5. **Update application configuration**
```bash
# Update APP_URL in .env
echo "APP_URL=https://myapp.com" >> .env

# Encrypt and deploy
openssl enc -aes-256-cbc -pbkdf2 -salt -in .env -out .env.enc.prod -k $ENV_PASS
flyctl secrets import -a myapp < .env
flyctl deploy -a myapp
```

6. **Verify**
```bash
curl https://myapp.com
curl https://www.myapp.com
```

## Example 5: Scaling Application

### Scenario
Your application is getting more traffic and needs to scale up.

### User Prompt
"Scale my Fly.io app to handle more traffic."

### Expected Workflow

1. **Check current configuration**
```bash
flyctl status -a myapp
flyctl scale show -a myapp
```

2. **Vertical scaling (increase VM resources)**
```bash
# Upgrade to larger VM with more memory
flyctl scale vm shared-cpu-1x --memory 1024 -a myapp
```

3. **Horizontal scaling (add more machines)**
```bash
# Add machines in multiple regions
flyctl regions add iad lhr syd -a myapp
flyctl scale count 2 -a myapp
```

4. **Verify scaling**
```bash
flyctl status -a myapp
flyctl machines list -a myapp
```

5. **Monitor performance**
```bash
flyctl metrics -a myapp
flyctl logs -a myapp
```

## Example 6: Troubleshooting Failed Deployment

### Scenario
Your deployment fails and you need to debug the issue.

### User Prompt
"My Fly.io deployment is failing with a build error."

### Expected Workflow

1. **Check deployment logs**
```bash
flyctl logs -a myapp
```

2. **Review build process**
```bash
# Deploy with verbose output
flyctl deploy -a myapp --verbose
```

3. **Common issues to check**

**Issue: Port mismatch**
```bash
# Check fly.toml internal_port matches your app's PORT
# Verify in fly.toml:
[http_service]
  internal_port = 8080  # Must match your app

# Verify in your app code:
const PORT = process.env.PORT || 8080
```

**Issue: Missing environment variables**
```bash
# List current secrets
flyctl secrets list -a myapp

# Add missing secrets
flyctl secrets set MISSING_VAR=value -a myapp
```

**Issue: Database connection**
```bash
# Verify database attachment
flyctl postgres list
flyctl status -a myapp-db

# Test database connection
flyctl proxy 5433 -a myapp-db
psql -h localhost -p 5433 -U postgres -d myapp
```

4. **SSH into container for debugging**
```bash
flyctl ssh console -a myapp

# Inside container:
env | grep DATABASE  # Check DATABASE_URL
curl localhost:8080/health  # Test internal endpoint
ps aux  # Check running processes
```

5. **Rollback if needed**
```bash
flyctl releases -a myapp
flyctl releases rollback -a myapp
```

## Example 7: Database Backup to S3

### Scenario
Set up automated database backups to AWS S3.

### User Prompt
"Back up my Fly.io database to S3 daily."

### Expected Workflow

1. **Manual backup first**
```bash
# Start proxy
flyctl proxy 5433 -a myapp-db

# Dump database (in another terminal)
TODAY=$(date +'%Y-%m-%d')
pg_dump -Fc --no-acl --no-owner \
  -h localhost -p 5433 -U postgres -d myapp > backup-$TODAY.dump

# Upload to S3
aws s3 cp backup-$TODAY.dump s3://my-backups/myapp/backup-$TODAY.dump
aws s3 cp backup-$TODAY.dump s3://my-backups/myapp/backup-latest.dump

# Clean up
rm backup-$TODAY.dump
```

2. **Create backup script**

Create `scripts/backup-db.sh`:

```bash
#!/bin/bash
set -e

APP_NAME="myapp"
DB_NAME="myapp-db"
S3_BUCKET="my-backups"
TODAY=$(date +'%Y-%m-%d')

# Start proxy in background
flyctl proxy 5433 -a $DB_NAME &
PROXY_PID=$!
sleep 5

# Dump database
pg_dump -Fc --no-acl --no-owner \
  -h localhost -p 5433 -U postgres -d $APP_NAME > backup-$TODAY.dump

# Upload to S3
aws s3 cp backup-$TODAY.dump s3://$S3_BUCKET/$APP_NAME/backup-$TODAY.dump
aws s3 cp backup-$TODAY.dump s3://$S3_BUCKET/$APP_NAME/backup-latest.dump

# Clean up
rm backup-$TODAY.dump
kill $PROXY_PID
```

3. **Schedule with cron or GitHub Actions**

Create `.github/workflows/backup-db.yml`:

```yaml
name: Database Backup

on:
  schedule:
    - cron: '0 2 * * *'  # Daily at 2 AM UTC
  workflow_dispatch:

jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: superfly/flyctl-actions/setup-flyctl@master

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Run backup
        run: bash scripts/backup-db.sh
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

## Example 8: Multi-Environment Setup

### Scenario
Set up separate staging and production environments.

### User Prompt
"Create separate staging and production Fly.io deployments."

### Expected Workflow

1. **Create staging environment**
```bash
# Create staging database
flyctl postgres create
# Name: myapp-staging-db
# Region: iad

# Launch staging app
flyctl launch
# Name: myapp-staging
# Region: iad
# Don't deploy yet

# Attach database
flyctl pg attach myapp-staging-db -a myapp-staging

# Set secrets
flyctl secrets import -a myapp-staging < .env.staging
```

2. **Create production environment**
```bash
# Create production database
flyctl postgres create
# Name: myapp-db
# Region: iad (or closer to users)

# Launch production app
flyctl launch
# Name: myapp
# Region: iad
# Don't deploy yet

# Attach database
flyctl pg attach myapp-db -a myapp

# Set secrets
flyctl secrets import -a myapp < .env.production
```

3. **Configure deployment workflow**

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches: [main, develop]

jobs:
  deploy-staging:
    if: github.ref == 'refs/heads/develop'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: superfly/flyctl-actions/setup-flyctl@master
      - run: flyctl deploy --remote-only --app myapp-staging
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}

  deploy-production:
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - uses: superfly/flyctl-actions/setup-flyctl@master
      - run: flyctl deploy --remote-only --app myapp
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

## Example 9: Cost Optimization

### Scenario
Reduce Fly.io costs while maintaining good performance.

### User Prompt
"Optimize my Fly.io costs."

### Expected Workflow

1. **Enable auto-scaling**

Update `fly.toml`:

```toml
[http_service]
  auto_stop_machines = true
  auto_start_machines = true
  min_machines_running = 0  # Scale to zero when idle
```

2. **Right-size VM**
```bash
# Start with smallest VM
flyctl scale vm shared-cpu-1x --memory 256 -a myapp

# Monitor performance
flyctl metrics -a myapp

# Adjust if needed
flyctl scale vm shared-cpu-1x --memory 512 -a myapp
```

3. **Optimize regions**
```bash
# Check current regions
flyctl regions list -a myapp

# Remove unused regions
flyctl regions remove lhr syd -a myapp

# Keep only primary region
flyctl regions set iad -a myapp
```

4. **Database optimization**
```bash
# Check database tier
flyctl status -a myapp-db

# Downgrade if appropriate
flyctl postgres config update --vm-size shared-cpu-1x -a myapp-db
```

5. **Monitor costs**
```bash
# View usage dashboard
flyctl dashboard

# Set up billing alerts in Fly.io dashboard
# Settings > Billing > Alerts
```

## Testing Prompts

Use these prompts to test skill activation:

### Direct Deployment
- "Deploy my app to Fly.io"
- "How do I use flyctl?"
- "Set up Fly.io deployment"

### Database
- "Create PostgreSQL on Fly.io"
- "Migrate database to Fly.io"
- "Backup Fly.io database"

### Configuration
- "Configure fly.toml"
- "Set Fly.io secrets"
- "Add custom domain to Fly.io"

### Troubleshooting
- "Fly.io deployment failed"
- "Debug Fly.io logs"
- "Rollback Fly.io deployment"

### CI/CD
- "GitHub Actions Fly.io"
- "Automate Fly.io deployment"
- "CI/CD for Fly.io"
