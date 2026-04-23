# Fly.io Deployment Checklist

Use this checklist to ensure all steps are completed for a successful Fly.io deployment.

## Pre-Deployment

### Account and CLI Setup
- [ ] Fly.io account created with credit card attached
- [ ] flyctl CLI installed and up to date (`flyctl version`)
- [ ] Authenticated with Fly.io (`flyctl auth login`)
- [ ] Verified account status (`flyctl auth whoami`)

### Application Preparation
- [ ] Application builds successfully locally
- [ ] All dependencies listed in package.json/requirements.txt/etc.
- [ ] Dockerfile or buildpack configuration verified
- [ ] Health check endpoint implemented and tested
- [ ] Production-ready error handling in place
- [ ] Logging configured appropriately

### Environment Configuration
- [ ] .env file created with production values
- [ ] All required environment variables documented
- [ ] Sensitive data encrypted (using openssl or similar)
- [ ] .env added to .gitignore
- [ ] ENV_PASS stored securely (password manager, GitHub secrets)

### Database Setup (if applicable)
- [ ] PostgreSQL database created on Fly.io
- [ ] Database naming convention followed ({project-name}-db)
- [ ] Database credentials securely stored
- [ ] Database backup strategy planned
- [ ] Migration scripts tested locally

## Deployment

### Initial Configuration
- [ ] `flyctl launch` executed successfully
- [ ] App name chosen (matches project naming convention)
- [ ] Region selected (close to users, same as database)
- [ ] fly.toml reviewed and customized
- [ ] Resource allocation appropriate for workload
- [ ] Auto-scaling configuration reviewed

### Database Integration
- [ ] Database attached to application (`flyctl pg attach`)
- [ ] DATABASE_URL secret set correctly
- [ ] Database connection tested via proxy
- [ ] Initial database schema deployed (migrations)
- [ ] Database connection pooling configured if needed

### Secrets and Environment
- [ ] All secrets imported (`flyctl secrets import`)
- [ ] Secrets list verified (`flyctl secrets list`)
- [ ] Production URLs/domains configured
- [ ] API keys and tokens set
- [ ] Third-party service credentials configured

### Deployment Execution
- [ ] Initial deployment successful (`flyctl deploy`)
- [ ] Deployment logs reviewed for errors
- [ ] Application status shows "running" (`flyctl status`)
- [ ] Health check passing
- [ ] Application accessible via Fly.io URL

## Post-Deployment

### Verification
- [ ] Application opens in browser (`flyctl open`)
- [ ] Critical user flows tested manually
- [ ] API endpoints responding correctly
- [ ] Database operations working
- [ ] File uploads/downloads working (if applicable)
- [ ] Email sending working (if applicable)
- [ ] Third-party integrations functional

### Domain and SSL
- [ ] Custom domain DNS configured (if applicable)
- [ ] SSL certificate created (`flyctl certs create`)
- [ ] Certificate status verified (`flyctl certs show`)
- [ ] HTTPS redirect working
- [ ] APP_URL updated to custom domain
- [ ] Application re-deployed with domain changes

### Monitoring and Logging
- [ ] Logs streaming without errors (`flyctl logs`)
- [ ] Metrics dashboard reviewed (`flyctl metrics`)
- [ ] Alerting configured (Fly.io dashboard)
- [ ] Error tracking service integrated (Sentry, etc.)
- [ ] Uptime monitoring configured (UptimeRobot, etc.)

### Performance and Scaling
- [ ] Response times acceptable
- [ ] Memory usage within limits
- [ ] CPU usage reasonable
- [ ] Database query performance optimized
- [ ] Auto-scaling configuration tested
- [ ] Regional deployment strategy decided

### Security
- [ ] All secrets stored securely (not in code)
- [ ] Database not publicly accessible
- [ ] SSL/TLS enabled and enforced
- [ ] Security headers configured
- [ ] Rate limiting implemented (if needed)
- [ ] CORS configured correctly
- [ ] Authentication/authorization working

### CI/CD Integration (if applicable)
- [ ] GitHub Actions workflow created
- [ ] FLY_API_TOKEN secret added to GitHub
- [ ] ENV_PASS secret added to GitHub (if using encryption)
- [ ] Workflow triggers configured correctly
- [ ] Test deployment from CI/CD successful
- [ ] Deployment notifications configured

### Documentation and Handoff
- [ ] Deployment procedures documented
- [ ] Environment variables documented
- [ ] Database schema documented
- [ ] API endpoints documented
- [ ] Troubleshooting guide created
- [ ] Rollback procedures documented
- [ ] Team members granted access (Fly.io organization)

### Backup and Recovery
- [ ] Database backup tested
- [ ] Database restore tested
- [ ] Backup automation configured (S3, etc.)
- [ ] Backup retention policy defined
- [ ] Disaster recovery plan documented
- [ ] Application data backup strategy implemented

## Cost Optimization

- [ ] VM size appropriate for workload
- [ ] Auto-stop/auto-start enabled (if suitable)
- [ ] Regional deployment optimized
- [ ] Database tier appropriate for usage
- [ ] Billing alerts configured
- [ ] Resource usage monitored regularly

## Ongoing Maintenance

- [ ] Update schedule defined
- [ ] Security patch policy established
- [ ] Dependency update process defined
- [ ] Monitoring dashboard reviewed regularly
- [ ] Performance optimization planned
- [ ] Capacity planning for growth

## Rollback Plan

- [ ] Previous version documented
- [ ] Rollback command tested (`flyctl releases rollback`)
- [ ] Database migration rollback strategy defined
- [ ] Rollback triggers identified
- [ ] Communication plan for rollback events

## Sign-Off

- [ ] Technical lead approval
- [ ] Security review completed
- [ ] Performance benchmarks met
- [ ] Documentation complete
- [ ] Team trained on deployment process
- [ ] Stakeholders notified of deployment

---

**Deployment Date**: _______________
**Deployed By**: _______________
**Application Name**: _______________
**Application URL**: _______________
**Database Name**: _______________
**Region(s)**: _______________

**Notes**:
