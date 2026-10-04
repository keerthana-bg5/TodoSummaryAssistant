# Failure and Rollback Scenarios

Every image is tagged with its commit SHA, and the last healthy tag is stored on the server in `/opt/todo/.last_good_tag`.

## 1. A faulty version is deployed. How do I roll back?
- **Automatic:** the deploy step runs a health check against `/actuator/health`. If it fails within ~2 minutes, the script restores `IMAGE_TAG` to the previous good SHA and restarts the containers; the pipeline is marked failed.
- **Manual (faulty but healthy-looking):** either `git revert <bad-sha>` and push (pipeline redeploys a clean build), or on the server:
  ```bash
  cd /opt/todo && sed -i 's/^IMAGE_TAG=.*/IMAGE_TAG=<good-sha>/' .env && docker compose up -d backend frontend
  ```
  Old images remain in the registry, so any previous SHA can be redeployed.

## 2. The application crashes after deployment. What happens?
- `restart: unless-stopped` restarts the container; the Docker `HEALTHCHECK` marks it unhealthy if it keeps failing.
- The pipeline health check fails → automatic rollback (scenario 1).
- Prometheus fires `ServiceDown` (1 min) and `ContainerRestarting`; logs: `docker compose logs --tail=200 backend`.
- Typical causes: bad config/secret, DB unreachable (check RDS SG and endpoint), out of memory.

## 3. The CI/CD tool is unavailable. Can I still deploy?
Yes. Deployment is just Docker Compose on the server, so no CI is needed:
1. Build/push from a laptop (`docker build` + `docker push` with a tag) or reuse an existing tag.
2. SSH to the EC2 host, set `IMAGE_TAG` in `/opt/todo/.env`, run `docker compose pull && docker compose up -d`.
3. Run the same health check. Record the manual deploy in the repo/issue tracker, and reconcile once CI is back.

## 4. Secrets are leaked. What steps do I take?
1. **Revoke/rotate immediately**: DB password (RDS → modify master password), Cohere API key, Slack webhook, Docker Hub token, SSH deploy key.
2. Update SSM parameters (`aws ssm put-parameter --overwrite`) and redeploy so containers pick up new values.
3. If committed to Git: rotating is mandatory (history rewrite is not enough); then remove it with `git filter-repo`/BFG and force-push, and invalidate forks/caches.
4. Review CloudTrail, RDS logs and provider usage dashboards for misuse; check security groups were not changed.
5. Post-mortem: add secret scanning (GitHub secret scanning / gitleaks) to prevent recurrence.

## 5. The EC2 instance fails. How do I recover?
- Stateless by design: app state lives in RDS, config in SSM, images in the registry, and infra in Terraform.
- Recovery: `terraform apply` (or launch a new instance with the same IAM role and SG), update `EC2_HOST` secret / Elastic IP, re-run the pipeline (workflow_dispatch/push) to deploy.
- For a stopped/impaired instance, try stop/start first (new host); use an Elastic IP so the address survives. Grafana dashboards are provisioned from the repo; only Prometheus history is lost unless the volume is snapshotted.
- Estimated recovery: 10–15 minutes.

## 6. The RDS database becomes unavailable. Impact and recovery?
- **Impact:** the backend cannot read/write; API calls fail with 5xx, `/actuator/health` goes DOWN, `HighErrorRate` fires. The frontend loads but shows errors. No data is lost by an outage itself.
- **Recovery plan:**
  - Automated backups (7-day retention, point-in-time restore) and manual snapshots before risky changes.
  - **Multi-AZ** (recommended in production) gives automatic failover in ~1–2 minutes; single-AZ free tier does not.
  - Restore: `aws rds restore-db-instance-to-point-in-time` (or from snapshot) into a new instance, update `SPRING_DATASOURCE_URL` in SSM, redeploy.
  - Connection pool retries mean the app recovers on its own once the DB returns.
