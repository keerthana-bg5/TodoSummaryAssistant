# Monitoring and Operations (Design Level)

## Metrics I monitor and why
| Area | Metric | Why |
|------|--------|-----|
| Traffic (RED) | request rate | Detects traffic drops (outage upstream) and spikes |
| Errors | 5xx ratio | Direct user impact; best signal of a bad release |
| Latency | p95 `http_server_requests` | Slowness precedes failures; the Cohere call is a likely bottleneck |
| Availability | `up`, uptime | Is the service reachable at all |
| Host | CPU, memory, disk (node-exporter) | Saturation on a small instance is the most likely infra failure |
| Containers | restarts, memory (cAdvisor) | Crash loops and OOM kills |
| JVM / DB pool | heap, GC pause, Hikari active/pending connections | Early signs of leaks and DB trouble |
| RDS (CloudWatch) | CPU, free storage, connections | Database health outside the host |

## Critical logs
- Backend application logs (errors, stack traces, failed Cohere/Slack calls, DB connection errors) via `docker compose logs`; Docker json-file with rotation, shipped to CloudWatch Logs in production.
- Deployment logs (Jenkins build console, the remote deploy output).
- nginx access/error logs (4xx/5xx patterns, probing).
- RDS error/slow query logs.
- SSH auth logs (`/var/log/secure`) and CloudTrail for security events.

## Alerts that matter
| Alert | Condition | Severity |
|-------|-----------|----------|
| ServiceDown | backend `up == 0` for 1m | critical, page |
| HighErrorRate | 5xx > 5% for 5m | critical, page |
| HighCPU | > 85% for 10m | warning |
| LowDiskSpace | < 15% free for 5m | warning (critical at 5%) |
| ContainerRestarting | > 2 restarts in 15m | warning |

## What should NOT alert (to avoid noise)
- Single failed scrape, brief CPU spikes (hence `for:` windows), 4xx responses (client errors), one slow request, deploy-time restarts (alerts have `for:` delays), memory use that is high but stable (JVM/page cache), and anything with no action attached. Warnings go to a channel; only critical alerts page someone.

## How operational issues are detected early
- Pipeline health check gates every deploy and auto-rolls back.
- Trend alerts: disk filling, rising p95 latency, growing restart count.
- Dashboards reviewed after each release (error rate and latency compared with the previous version).
- Synthetic check hitting `/actuator/health` from outside (e.g. Route 53 health check or UptimeRobot).
- Alert routing: Grafana/Alertmanager contact point (Slack) so the team sees warnings before users do.
