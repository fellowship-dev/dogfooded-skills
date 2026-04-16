---
name: fly-io
description: Deploy applications to Fly.io platform including flyctl CLI setup, fly.toml configuration, Fly.io database setup, fly secrets management, Fly.io-specific GitHub Actions workflows, fly logs monitoring, and Fly.io troubleshooting. Activates on "fly.io", "flyctl", "fly.toml", "fly secrets", "fly logs", "fly app", "fly postgres" (Fly.io-specific PostgreSQL). Requires flyctl CLI and Fly.io account.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# Fly.io

This skill provides comprehensive guidance for deploying applications to Fly.io, including initial setup, database management, CI/CD integration, and production operations.

## When to Use

This skill activates automatically when working with:

- Fly.io-specific tasks ("fly.io", "deploy to fly", "fly.io setup", "flyctl")
- Fly.io configuration ("fly.toml", "fly app", "fly launch")
- Fly.io database operations ("fly postgres", "fly pg")
- Fly.io environment management ("fly secrets", "fly env")
- Fly.io monitoring ("fly logs", "fly status", "fly dashboard")
- Fly.io GitHub Actions ("fly deploy github action", "flyctl in CI/CD")

## Core Principles

1. **Security First**: Always encrypt sensitive data, never commit unencrypted secrets
2. **Database Safety**: Use proxying for database access, maintain regular backups
3. **Environment Isolation**: Separate development, staging, and production configurations
4. **Cost Awareness**: Optimize resource allocation, monitor usage regularly
5. **Automation**: Leverage CI/CD for consistent, repeatable deployments
6. **Monitoring**: Implement comprehensive logging and health checks

## Prerequisites

Before beginning Fly.io deployment:

1. **Fly.io Account**: Active account with credit card attached (required for PostgreSQL)
2. **CLI Installation**: `flyctl` command-line tool installed and authenticated
3. **Environment Variables**: Project-specific configuration ready
4. **Application Ready**: Application configured for production deployment

## Instructions

### 1. Initial Setup and Authentication

**Install Fly.io CLI:**

```bash
# Standard installation
curl -L https://fly.io/install.sh | sh

# Add to PATH (adjust based on your environment)
export FLYCTL_INSTALL="/home/user/.fly"
export PATH="$FLYCTL_INSTALL/bin:$PATH"

# Verify installation
flyctl version
```

**Authenticate with Fly.io:**

```bash
flyctl auth login
```

This opens a browser for authentication. After successful login, your credentials are stored locally.

### 2. Environment Variable Management

**Encryption for Security:**

Fly.io deployments should use encrypted environment files to protect sensitive data:

```bash
# Decrypt environment file (requires ENV_PASS variable)
openssl enc -aes-256-cbc -pbkdf2 -salt -d -in .env.enc -out .env -k $ENV_PASS

# After modifying .env, re-encrypt
openssl enc -aes-256-cbc -pbkdf2 -salt -in .env -out .env.enc -k $ENV_PASS

# For production environment
openssl enc -aes-256-cbc -pbkdf2 -salt -in .env -out .env.enc.prod -k $ENV_PASS
```

**IMPORTANT Security Notes:**
- Never commit unencrypted `.env` files
- Store `ENV_PASS` securely (GitHub secrets, password manager)
- Use different encryption passwords for staging/production
- Add `.env` to `.gitignore` if not already present

### 3. Database Setup (PostgreSQL)

**Create PostgreSQL Database:**

```bash
# Create new PostgreSQL database on Fly.io
flyctl postgres create

# When prompted, use naming convention: {project-name}-db
# Example: myapp-db
```

**Important database creation options:**
- Choose region closest to your users
- Select appropriate resource tier (start small, scale up)
- Note the database credentials provided
- Database name typically matches app name + "-db" suffix

**Attach Database to Application:**

```bash
# Attach database to your application
flyctl pg attach {project-name}-db -a {project-name}

# If attachment fails, set DATABASE_URL manually
flyctl secrets set DATABASE_URL=postgres://user:pass@host:5432/dbname -a {project-name}
```

**Verify database connection:**

```bash
# Check database status
flyctl status -a {project-name}-db

# Test connection via proxy
flyctl proxy 5433 -a {project-name}-db
# In another terminal: psql -h localhost -p 5433 -U {username} -d {dbname}
```

### 4. Application Creation and Configuration

**Launch New Application:**

```bash
# Create application (don't deploy yet)
flyctl launch

# Follow prompts:
# - Choose app name (matches ENV_NAME variable)
# - Select region (same as database for best performance)
# - Choose resource allocation
# - Decline immediate deployment (configure first)
```

**Configure Application:**

After `flyctl launch`, review and customize `fly.toml`:

```toml
app = "your-app-name"

[build]
  # Adjust based on your application type

[env]
  PORT = "8080"
  HOST = "::"
  # Add other non-secret environment variables

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = true
  auto_start_machines = true
  min_machines_running = 0
```

**Set Secrets:**

```bash
# Set individual secrets
flyctl secrets set APP_KEYS="your-app-keys" -a {project-name}
flyctl secrets set API_TOKEN_SALT="your-salt" -a {project-name}

# Import from .env file (ensure it's decrypted first)
flyctl secrets import -a {project-name} < .env
```

### 5. Deployment Workflow

**Pre-Deployment Checklist:**

- [ ] Environment variables configured (production values)
- [ ] Database created and attached
- [ ] `fly.toml` reviewed and customized
- [ ] Secrets set via `flyctl secrets`
- [ ] Application builds successfully locally
- [ ] Dependencies are production-ready

**Initial Deployment:**

```bash
# Deploy application
flyctl deploy -a {project-name}

# Monitor deployment
flyctl logs -a {project-name}

# Check status
flyctl status -a {project-name}
```

**Post-Deployment Verification:**

```bash
# Open application in browser
flyctl open -a {project-name}

# Check health endpoint
curl https://{project-name}.fly.dev/health

# Review logs for errors
flyctl logs -a {project-name}
```

### 6. Domain and SSL Configuration

**Add Custom Domain:**

```bash
# Add certificate for custom domain
flyctl certs create yourdomain.com -a {project-name}

# Check certificate status
flyctl certs show yourdomain.com -a {project-name}
```

**DNS Configuration:**

1. Point your domain's A/AAAA records to Fly.io
2. Wait for DNS propagation
3. Verify certificate issuance
4. Update `APP_URL` environment variable to custom domain
5. Re-deploy with updated configuration

### 7. Database Management

**PostgreSQL Dump (Backup):**

```bash
# Standard dump format (custom format, compressed)
pg_dump -Fc --no-acl --no-owner -h HOST -U USERNAME -d DATABASE_NAME > dump_file.dump

# Example for local database
pg_dump -Fc --no-acl --no-owner -h localhost -U postgres -d strapi > backup.dump
```

**PostgreSQL Restore:**

```bash
# Standard restore
pg_restore --verbose --clean --no-acl --no-owner -h HOST -p PORT -U USERNAME -d "DATABASE_NAME" dump_file.dump

# Example for local database
pg_restore --verbose --clean --no-acl --no-owner -h localhost -U postgres -d strapi backup.dump
```

**Upload Local Database to Fly.io:**

```bash
# 1. Export local database
pg_dump -Fc --no-acl --no-owner -h localhost -U postgres -d {dbname} > latest.dump

# 2. Proxy production database (run in separate terminal)
flyctl proxy 5433 -a {project-name}-db

# 3. In another terminal, restore to production
DB_USER={check_fly_dashboard}  # Get from Fly.io dashboard
DB_NAME={check_fly_dashboard}   # Get from Fly.io dashboard
pg_restore --verbose --clean --no-acl --no-owner -h localhost -p 5433 -U $DB_USER -d "$DB_NAME" latest.dump

# 4. Clean up
rm latest.dump
```

**Download Production Database from Fly.io:**

```bash
# 1. Proxy production database (run in separate terminal)
flyctl proxy 5433 -a {project-name}-db

# 2. In another terminal, dump production database
DB_USER={check_fly_dashboard}
DB_NAME={check_fly_dashboard}
pg_dump -Fc --no-acl --no-owner -h localhost -p 5433 -U $DB_USER -d "$DB_NAME" > production.dump

# 3. Restore to local database
pg_restore --verbose --clean --no-acl --no-owner -h localhost -U postgres -d {dbname} production.dump

# 4. Clean up
rm production.dump
```

**Database Proxy for Direct Access:**

```bash
# Proxy database to local port
flyctl proxy 5433 -a {project-name}-db

# Connect with psql
psql -h localhost -p 5433 -U {username} -d {dbname}

# Connect with GUI tools (PgAdmin, DBeaver, etc.)
# Host: localhost
# Port: 5433
# User: {from Fly.io dashboard}
# Database: {from Fly.io dashboard}
```

### 8. GitHub Actions CI/CD Integration

**Setup Continuous Deployment:**

1. Generate Fly.io API token:
   ```bash
   flyctl auth token
   ```

2. Add GitHub repository secrets:
   - `FLY_API_TOKEN`: Your Fly.io API token
   - `ENV_PASS`: Environment encryption password (if using encrypted .env)

3. Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy to Fly.io

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Fly.io CLI
        uses: superfly/flyctl-actions/setup-flyctl@master

      - name: Decrypt environment variables
        run: |
          openssl enc -aes-256-cbc -pbkdf2 -salt -d \
            -in .env.enc.prod -out .env -k ${{ secrets.ENV_PASS }}

      - name: Deploy to Fly.io
        run: flyctl deploy --remote-only
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
```

**Best Practices for CI/CD:**
- Use `--remote-only` flag to build on Fly.io servers
- Separate staging and production workflows
- Implement smoke tests after deployment
- Configure Slack/Discord notifications for deployment status
- Use GitHub environments for approval gates on production deploys

### 9. Monitoring and Troubleshooting

**Essential Monitoring Commands:**

```bash
# Check application status
flyctl status -a {project-name}

# View real-time logs
flyctl logs -a {project-name}

# View logs with filtering
flyctl logs -a {project-name} --region iad

# Check database status
flyctl status -a {project-name}-db

# View metrics
flyctl metrics -a {project-name}

# SSH into application
flyctl ssh console -a {project-name}
```

**Common Issues and Solutions:**

1. **Port Configuration Problems:**
   - Verify `fly.toml` internal_port matches application PORT
   - Ensure HOST is set to "::" for IPv6 compatibility
   - Check APP_URL matches deployed domain/URL

2. **Database Connection Failures:**
   - Verify DATABASE_URL format and credentials
   - Check database is in same region as app
   - Test connection via proxy: `flyctl proxy 5433 -a {project-name}-db`
   - Review database logs: `flyctl logs -a {project-name}-db`

3. **Environment Variable Issues:**
   - Verify secrets are set: `flyctl secrets list -a {project-name}`
   - Check production values in .env before encryption
   - Ensure ENV_PASS is correct when decrypting
   - Re-import secrets after changes: `flyctl secrets import`

4. **Deployment Failures:**
   - Review build logs: `flyctl logs -a {project-name}`
   - Check Dockerfile or buildpack configuration
   - Verify all dependencies in package.json/requirements.txt
   - Test build locally before deploying
   - Increase build timeout if needed

5. **Application Crashes:**
   - Check logs for error messages: `flyctl logs -a {project-name}`
   - Verify health check endpoint is responding
   - Review resource allocation (memory, CPU)
   - Check for database connection issues
   - SSH into container to debug: `flyctl ssh console -a {project-name}`

### 10. Scaling and Performance

**Vertical Scaling (Resource Allocation):**

```bash
# Scale VM resources
flyctl scale vm shared-cpu-1x --memory 512 -a {project-name}

# Available VM sizes:
# shared-cpu-1x (256MB, 512MB, 1GB, 2GB)
# dedicated-cpu-1x (2GB, 4GB, 8GB)
# dedicated-cpu-2x (4GB, 8GB, 16GB)
```

**Horizontal Scaling (Machine Count):**

```bash
# Scale number of machines
flyctl scale count 2 -a {project-name}

# Auto-scaling configuration in fly.toml:
[http_service]
  auto_stop_machines = true
  auto_start_machines = true
  min_machines_running = 0  # Scale to zero when idle
```

**Regional Deployment:**

```bash
# Add machines in multiple regions
flyctl regions add iad lhr syd -a {project-name}

# View current regions
flyctl regions list -a {project-name}

# Remove regions
flyctl regions remove lhr -a {project-name}
```

### 11. Cost Optimization

**Strategies for Reducing Costs:**

1. **Auto-stop/Auto-start**: Enable in fly.toml to scale to zero during idle periods
2. **Right-size Resources**: Start with smallest VM size, scale up only if needed
3. **Database Optimization**: Choose appropriate PostgreSQL tier, monitor usage
4. **Regional Strategy**: Deploy only in regions with active users
5. **Monitoring**: Set up billing alerts in Fly.io dashboard

**Cost Monitoring:**

```bash
# View current usage and costs
flyctl dashboard

# Check resource allocation
flyctl status -a {project-name}
flyctl status -a {project-name}-db
```

## Supporting Files

This skill includes supporting templates:

- **fly.toml.template**: Basic Fly.io configuration template
- **deployment-checklist.md**: Pre-deployment verification checklist
- **github-actions-workflow.yml**: Sample CI/CD workflow

Access these via: `.claude/skills/flyio-deployment/templates/`

## Common Deployment Patterns

### Pattern 1: Initial Production Deployment

```bash
# 1. Setup and authenticate
flyctl auth login

# 2. Create database
flyctl postgres create  # Use {project-name}-db

# 3. Launch application
flyctl launch  # Don't deploy yet

# 4. Attach database
flyctl pg attach {project-name}-db -a {project-name}

# 5. Set secrets
flyctl secrets import -a {project-name} < .env

# 6. Deploy
flyctl deploy -a {project-name}

# 7. Verify
flyctl open -a {project-name}
flyctl logs -a {project-name}
```

### Pattern 2: Database Migration

```bash
# Export from source
pg_dump -Fc --no-acl --no-owner -h {source-host} -U {user} -d {db} > migration.dump

# Proxy Fly.io database
flyctl proxy 5433 -a {project-name}-db  # Separate terminal

# Import to Fly.io
pg_restore --verbose --clean --no-acl --no-owner \
  -h localhost -p 5433 -U {user} -d {db} migration.dump

# Verify
flyctl ssh console -a {project-name}
# Inside container: run database query to verify data
```

### Pattern 3: Rollback Deployment

```bash
# List recent releases
flyctl releases -a {project-name}

# Rollback to previous version
flyctl releases rollback -a {project-name}

# Or rollback to specific version
flyctl releases rollback {version-number} -a {project-name}

# Monitor rollback
flyctl logs -a {project-name}
```

## Security Best Practices

1. **Environment Encryption**: Always encrypt .env files before committing
2. **Database Access**: Use database proxying instead of exposing publicly
3. **API Tokens**: Store Fly.io API tokens in GitHub secrets, never in code
4. **SSL Certificates**: Always enable force_https in fly.toml
5. **Database Backups**: Implement automated backup strategy (S3, external storage)
6. **Secrets Rotation**: Regularly rotate API tokens, database passwords, encryption keys
7. **Access Control**: Use Fly.io organizations for team access management
8. **Network Security**: Configure firewall rules, restrict database access

## Validation Checklist

Before considering deployment complete:

- [ ] Application accessible via public URL
- [ ] Health check endpoint responding correctly
- [ ] Database connection working
- [ ] All environment variables set correctly
- [ ] SSL certificate issued and active
- [ ] Logs showing no errors
- [ ] CI/CD pipeline configured and tested
- [ ] Database backups configured
- [ ] Monitoring and alerting set up
- [ ] Documentation updated with deployment URLs and procedures

## Real-World Gotchas (learned the hard way)

### High-Risk Account Lock
Fly.io flags dormant accounts as "high risk". Creating apps/DBs fails with:
> Your account has been marked as high risk. Please go to https://fly.io/high-risk-unlock

**Fix**: Must visit the URL in a browser logged into the Fly account. CLI cannot bypass this.

### Auto-Stop Is Aggressive
With `auto_stop_machines = "stop"` and `min_machines_running = 0`, machines stop after ~60s idle. Some frameworks take 5-10s to cold boot. This means:
- First request after idle gets a slow response (wake + boot)
- Rapid sequential API calls may hit a stopped machine between calls
- **Always hit `/_health` and wait for 204 before running batch operations**

### Fly Creates 2 Machines by Default
Even with `min_machines_running = 0`, `fly deploy` creates 2 machines for "HA". For dev/staging, destroy the second one:
```bash
fly status --app <app>  # Find both machine IDs
fly machine stop <second-id> --app <app>
fly machine destroy <second-id> --app <app> --force
```

### DATABASE_SSL Must Be False on Internal Network
`fly postgres attach` sets `DATABASE_URL` with `sslmode=disable`. If your app has a `DATABASE_SSL` env var, set it to `false`:
```toml
[env]
  DATABASE_SSL = "false"
```

### DNS + Cert Setup (Cloudflare)
When using Cloudflare for DNS:
1. **Records must be unproxied** (`proxied=false`) — Fly needs direct traffic for TLS termination
2. **Check for stale records** — old deployments may have left proxied A/AAAA records. Delete them first.
3. **ACME CNAME** — `fly certs setup` gives you a `_acme-challenge` CNAME target. Create/update it for Let's Encrypt validation.
4. Cert issuance is fast (~30s) once DNS is correct.

### Deploy Flag: No `--region`
Use `--primary-region` or set `primary_region` in `fly.toml`. The flag `--region` does not exist on `fly deploy`.

### Bash Token Piping Bug
Long API tokens (256+ chars) cause empty stdout when piped through bash variable expansion + curl. Workarounds:
- Store token in a file: `echo -n "TOKEN" > /tmp/.token && TK=$(cat /tmp/.token)`
- Use curl with `-o file` instead of piping
- Use Python `urllib.request` (most reliable in sandbox environments)

## Additional Resources

- [Fly.io Official Documentation](https://fly.io/docs/)
- [Fly.io CLI Reference](https://fly.io/docs/flyctl/)
- [Fly.io Pricing](https://fly.io/docs/about/pricing/)
- [Fly.io Community Forum](https://community.fly.io/)
- [GitHub Actions Integration](https://fly.io/docs/app-guides/continuous-deployment-with-github-actions/)

## Notes

- Always test deployments in staging environment before production
- Keep flyctl CLI updated: `flyctl version update`
- Monitor Fly.io status page for platform incidents
- Join Fly.io community for support and best practices
- Consider using Fly.io's managed PostgreSQL for production workloads
