# Fly.io Deployment Quick Reference

This reference provides quick command lookups and common patterns for Fly.io deployments.

## Essential Commands

### CLI Installation and Authentication

```bash
# Install flyctl
curl -L https://fly.io/install.sh | sh

# Authenticate
flyctl auth login

# Check authentication status
flyctl auth whoami

# Generate API token (for CI/CD)
flyctl auth token

# Update flyctl to latest version
flyctl version update
```

### Application Management

```bash
# Launch new application
flyctl launch

# Deploy application
flyctl deploy

# Deploy with specific Dockerfile
flyctl deploy --dockerfile Dockerfile.prod

# Deploy with remote-only build
flyctl deploy --remote-only

# Open application in browser
flyctl open

# View application status
flyctl status -a {app-name}

# List all applications
flyctl apps list

# Destroy application
flyctl apps destroy {app-name}
```

### Database Operations

```bash
# Create PostgreSQL database
flyctl postgres create

# List databases
flyctl postgres list

# Attach database to application
flyctl pg attach {db-name} -a {app-name}

# Database status
flyctl status -a {db-name}

# Proxy database to localhost
flyctl proxy 5433 -a {db-name}

# Connect to database
flyctl postgres connect -a {db-name}

# Database configuration
flyctl postgres config show -a {db-name}

# Database backups
flyctl postgres backup list -a {db-name}
flyctl postgres backup create -a {db-name}
```

### Secrets Management

```bash
# Set single secret
flyctl secrets set KEY=value -a {app-name}

# Set multiple secrets
flyctl secrets set KEY1=value1 KEY2=value2 -a {app-name}

# Import secrets from file
flyctl secrets import -a {app-name} < .env

# List secrets (values hidden)
flyctl secrets list -a {app-name}

# Unset secret
flyctl secrets unset KEY -a {app-name}
```

### Monitoring and Logging

```bash
# View real-time logs
flyctl logs -a {app-name}

# View logs from specific region
flyctl logs -a {app-name} --region iad

# View metrics
flyctl metrics -a {app-name}

# View releases/deployments
flyctl releases -a {app-name}

# Rollback to previous release
flyctl releases rollback -a {app-name}

# Rollback to specific version
flyctl releases rollback {version} -a {app-name}
```

### Scaling

```bash
# Scale number of machines
flyctl scale count 2 -a {app-name}

# Scale VM resources
flyctl scale vm shared-cpu-1x --memory 512 -a {app-name}

# View current scale configuration
flyctl scale show -a {app-name}

# Available VM types
flyctl platform vm-sizes
```

### Regions

```bash
# List available regions
flyctl platform regions

# List app's current regions
flyctl regions list -a {app-name}

# Add regions
flyctl regions add iad lhr syd -a {app-name}

# Remove regions
flyctl regions remove lhr -a {app-name}

# Set backup regions
flyctl regions set iad lhr --backup syd -a {app-name}
```

### Certificates (SSL/TLS)

```bash
# Add certificate for custom domain
flyctl certs create yourdomain.com -a {app-name}

# List certificates
flyctl certs list -a {app-name}

# Show certificate details
flyctl certs show yourdomain.com -a {app-name}

# Delete certificate
flyctl certs delete yourdomain.com -a {app-name}
```

### SSH and Console Access

```bash
# SSH into application
flyctl ssh console -a {app-name}

# Run command via SSH
flyctl ssh console -a {app-name} -C "ls -la"

# SSH to specific machine
flyctl ssh console -a {app-name} --select
```

### Volumes (Persistent Storage)

```bash
# Create volume
flyctl volumes create {volume-name} --region iad --size 10 -a {app-name}

# List volumes
flyctl volumes list -a {app-name}

# Extend volume size
flyctl volumes extend {volume-id} --size 20 -a {app-name}

# Delete volume
flyctl volumes delete {volume-id} -a {app-name}
```

## PostgreSQL Commands

### Database Dump and Restore

```bash
# Dump database (custom format, recommended)
pg_dump -Fc --no-acl --no-owner -h {host} -U {user} -d {dbname} > backup.dump

# Dump database (SQL format)
pg_dump -h {host} -U {user} -d {dbname} > backup.sql

# Dump specific tables
pg_dump -Fc --no-acl --no-owner -h {host} -U {user} -d {dbname} -t table1 -t table2 > tables.dump

# Restore from custom format
pg_restore --verbose --clean --no-acl --no-owner -h {host} -U {user} -d {dbname} backup.dump

# Restore from SQL format
psql -h {host} -U {user} -d {dbname} < backup.sql

# Restore specific tables
pg_restore --verbose --clean --no-acl --no-owner -h {host} -U {user} -d {dbname} -t table1 tables.dump
```

### Connect via psql

```bash
# Basic connection
psql -h {host} -p {port} -U {user} -d {dbname}

# Connection with environment variables
PGHOST={host} PGPORT={port} PGUSER={user} PGDATABASE={dbname} psql

# Connection string
psql postgres://{user}:{password}@{host}:{port}/{dbname}
```

## Environment File Encryption

### OpenSSL Encryption/Decryption

```bash
# Encrypt .env file
openssl enc -aes-256-cbc -pbkdf2 -salt -in .env -out .env.enc -k $ENV_PASS

# Decrypt .env file
openssl enc -aes-256-cbc -pbkdf2 -salt -d -in .env.enc -out .env -k $ENV_PASS

# Encrypt for production
openssl enc -aes-256-cbc -pbkdf2 -salt -in .env -out .env.enc.prod -k $ENV_PASS

# Decrypt production file
openssl enc -aes-256-cbc -pbkdf2 -salt -d -in .env.enc.prod -out .env -k $ENV_PASS
```

## Common Workflows

### Initial Deployment Workflow

```bash
# 1. Authenticate
flyctl auth login

# 2. Create database
flyctl postgres create  # Choose {app-name}-db

# 3. Launch application
flyctl launch  # Don't deploy yet

# 4. Attach database
flyctl pg attach {app-name}-db -a {app-name}

# 5. Set secrets
flyctl secrets import -a {app-name} < .env

# 6. Deploy
flyctl deploy -a {app-name}

# 7. Verify
flyctl open -a {app-name}
```

### Database Migration Workflow

```bash
# 1. Export source database
pg_dump -Fc --no-acl --no-owner -h {source-host} -U {user} -d {db} > migration.dump

# 2. Start proxy to Fly.io database (separate terminal)
flyctl proxy 5433 -a {app-name}-db

# 3. Import to Fly.io (another terminal)
pg_restore --verbose --clean --no-acl --no-owner \
  -h localhost -p 5433 -U {user} -d {db} migration.dump

# 4. Verify data
flyctl ssh console -a {app-name}
# Run verification queries inside container
```

### Update Deployment Workflow

```bash
# 1. Make code changes
# ... edit files ...

# 2. Test locally
npm run build
npm run start

# 3. Update secrets if needed
flyctl secrets set NEW_KEY=value -a {app-name}

# 4. Deploy
flyctl deploy -a {app-name}

# 5. Monitor deployment
flyctl logs -a {app-name}

# 6. Verify
flyctl open -a {app-name}

# 7. Rollback if needed
flyctl releases rollback -a {app-name}
```

### Backup and Restore Workflow

```bash
# Backup production database
# 1. Start proxy
flyctl proxy 5433 -a {app-name}-db  # Terminal 1

# 2. Dump database (Terminal 2)
pg_dump -Fc --no-acl --no-owner \
  -h localhost -p 5433 -U {user} -d {db} > backup-$(date +%Y%m%d).dump

# 3. Upload to S3 (optional)
aws s3 cp backup-$(date +%Y%m%d).dump s3://{bucket}/backups/

# Restore from backup
# 1. Start proxy
flyctl proxy 5433 -a {app-name}-db  # Terminal 1

# 2. Restore database (Terminal 2)
pg_restore --verbose --clean --no-acl --no-owner \
  -h localhost -p 5433 -U {user} -d {db} backup-20240101.dump
```

## Troubleshooting Commands

### Debugging Deployments

```bash
# View detailed deployment logs
flyctl logs -a {app-name}

# Check application status
flyctl status -a {app-name}

# View machine details
flyctl machines list -a {app-name}

# View specific machine logs
flyctl logs -a {app-name} --instance {instance-id}

# SSH to debug
flyctl ssh console -a {app-name}

# Check environment variables
flyctl ssh console -a {app-name} -C "env"
```

### Database Debugging

```bash
# Check database status
flyctl status -a {app-name}-db

# View database logs
flyctl logs -a {app-name}-db

# Connect to database
flyctl postgres connect -a {app-name}-db

# Check database configuration
flyctl postgres config show -a {app-name}-db

# Test connection via proxy
flyctl proxy 5433 -a {app-name}-db
psql -h localhost -p 5433 -U {user} -d {db}
```

### Performance Debugging

```bash
# View metrics
flyctl metrics -a {app-name}

# Check resource usage
flyctl ssh console -a {app-name} -C "top"

# Check memory usage
flyctl ssh console -a {app-name} -C "free -h"

# Check disk usage
flyctl ssh console -a {app-name} -C "df -h"

# Check running processes
flyctl ssh console -a {app-name} -C "ps aux"
```

## Configuration Files

### fly.toml Essential Sections

```toml
# Application name
app = "your-app-name"
primary_region = "iad"

# Environment variables
[env]
  PORT = "8080"
  HOST = "::"
  NODE_ENV = "production"

# HTTP service configuration
[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = true
  auto_start_machines = true
  min_machines_running = 0

# Health checks
[[services.http_checks]]
  interval = "10s"
  grace_period = "5s"
  method = "get"
  path = "/health"
  timeout = "2s"

# VM configuration
[[vm]]
  cpu_kind = "shared"
  cpus = 1
  memory_mb = 512
```

### .dockerignore

```
node_modules
npm-debug.log
.env
.env.*
!.env.example
.git
.gitignore
.DS_Store
*.md
.vscode
.idea
coverage
.cache
dist
build
tmp
temp
```

### Dockerfile Best Practices

```dockerfile
# Multi-stage build for smaller images
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

FROM node:18-alpine
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY . .
EXPOSE 8080
CMD ["npm", "start"]
```

## Environment Variables

### Common Fly.io Environment Variables

```bash
# Fly.io provides these automatically:
FLY_APP_NAME          # Your application name
FLY_REGION            # Current region (iad, lhr, etc.)
FLY_PUBLIC_IP         # Public IPv4 address
FLY_PRIVATE_IP        # Private IPv6 address
FLY_ALLOC_ID          # Allocation/machine ID
```

### Application-Specific Variables

```bash
# Required for most applications
PORT                  # Port to listen on
HOST                  # Host address (usually "::")
NODE_ENV              # Environment (production, development)
DATABASE_URL          # PostgreSQL connection string
APP_URL               # Public application URL

# Common optional variables
REDIS_URL             # Redis connection string
SESSION_SECRET        # Session encryption key
API_KEY               # External API keys
AWS_ACCESS_KEY_ID     # AWS credentials
AWS_SECRET_ACCESS_KEY # AWS credentials
```

## Pricing Reference

### Compute Pricing (as of 2024)

- **shared-cpu-1x**: $0.0000022/sec (~$5.70/month for 1 machine running 24/7)
- **dedicated-cpu-1x**: $0.0000089/sec (~$23/month)
- **Memory**: Included in CPU pricing (256MB-2GB for shared, 2GB+ for dedicated)
- **Scale to zero**: Free when machines stopped (auto-stop/auto-start)

### Database Pricing

- **Development**: 1GB storage, shared CPU (~$0/month with free tier)
- **Production**: Starting at ~$10/month for basic tier
- **Storage**: $0.15/GB/month beyond included storage

### Network Pricing

- **Inbound**: Free
- **Outbound**: First 100GB free, then $0.02/GB

## Resource Links

- Documentation: https://fly.io/docs/
- CLI Reference: https://fly.io/docs/flyctl/
- Pricing: https://fly.io/docs/about/pricing/
- Status Page: https://status.flyio.net/
- Community: https://community.fly.io/
- GitHub Actions: https://fly.io/docs/app-guides/continuous-deployment-with-github-actions/
