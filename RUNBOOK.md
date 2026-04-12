# Incident Runbook

Step-by-step playbooks for common infrastructure incidents.
Each section is self-contained — jump directly to the one you need.

**Quick reference: which playbook do I need?**

| Symptom | Go to |
|---|---|
| App returning 503s intermittently | [1. Patroni Leader Flapping](#1-patroni-leader-flapping) |
| `patronictl list` shows "start failed" | [2. Patroni Replica Recovery](#2-patroni-replica-recovery) |
| App completely unreachable | [3. Caddy Down](#3-caddy-down) |
| `etcdctl endpoint health` shows unhealthy nodes | [4. etcd Cluster Degraded](#4-etcd-cluster-degraded) |
| No recent backup in GitHub Actions | [5. Backup Failure](#5-backup-failure) |
| Need to restore from backup | [6. Database Restore](#6-database-restore) |
| Deploy stuck or failed in CI | [7. Failed Deploy](#7-failed-deploy) |
| Counter returning same value / not incrementing | [8. Database Read-Only](#8-database-read-only) |

**Server quick-connect:**
```bash
# SSH into servers (replace N with 1, 2, or 3)
ssh deploy@138.201.137.181   # rishi-1 (Swarm manager)
ssh deploy@136.243.150.84    # rishi-2
ssh deploy@136.243.147.225   # rishi-3
```

---

## 1. Patroni Leader Flapping

**Symptoms:** Intermittent 503 errors, 20+ second response times, HAProxy logs
showing the leader going DOWN and UP repeatedly.

**Cause:** The Patroni leader is briefly returning 503 on its `/master` health
check endpoint. This happens during PostgreSQL checkpoints, vacuum operations,
or when the leader is under heavy load. HAProxy marks it DOWN after 3 failed
checks (9 seconds), then marks it UP again when checks pass.

**Impact:** During the DOWN window, all database connections queue or fail. If
replicas are also unhealthy, there are ZERO available backends and all requests
fail.

### Steps

1. **Check cluster status:**
   ```bash
   ssh deploy@138.201.137.181
   C=$(docker ps -qf "name=<STACK>_patroni-rishi" | head -1)
   docker exec "$C" patronictl -c /etc/patroni.yml list
   ```
   Replace `<STACK>` with your Swarm stack name (e.g.,
   `rishi-hetzner-infra-template-db`). You can find it in `project.config`
   as `SWARM_STACK`.

2. **If replicas show "start failed"** → go to
   [2. Patroni Replica Recovery](#2-patroni-replica-recovery). This is the
   most common root cause — with healthy replicas, brief leader blips don't
   affect availability.

3. **If replicas are healthy but leader is still flapping**, check HAProxy logs:
   ```bash
   docker logs --tail 50 $(docker ps -qf "name=<STACK>_haproxy" | head -1)
   ```
   Look for "DOWN" and "UP" messages. If they're seconds apart, the leader
   is recovering quickly and the issue may resolve on its own.

4. **If the leader is stuck in a long DOWN state**, check Patroni logs:
   ```bash
   docker logs --tail 100 $(docker ps -qf "name=<STACK>_patroni-rishi-1" | head -1)
   ```
   Look for: `ERROR`, `CRITICAL`, checkpoint warnings, or etcd connection errors.

5. **Nuclear option — restart the leader's Patroni container:**
   ```bash
   # This triggers a controlled failover to a healthy replica
   docker exec "$C" patronictl -c /etc/patroni.yml restart <SCOPE> rishi-1
   ```
   Replace `<SCOPE>` with your Patroni scope (e.g.,
   `rishi-hetzner-infra-template-cluster`). This is safe IF at least one
   replica is streaming.

### Resolution

The root cause is almost always degraded replicas. Once replicas are healthy
(see playbook 2), the leader can flap without affecting availability —
HAProxy will route to a healthy replica during the blip.

---

## 2. Patroni Replica Recovery

**Symptoms:** `patronictl list` shows replicas in "start failed" state.
The infra-health.yml workflow reports Patroni as degraded.

**Cause:** Stale PostgreSQL lock files, WAL divergence after unclean shutdown,
or corrupted data directory. Most commonly happens after a server reboot or
Docker container crash.

**Impact:** No immediate outage (the leader handles all traffic), but the
cluster has lost redundancy. If the leader goes down, there's no healthy
replica to promote — total outage until manual intervention.

### Steps

1. **Automated fix (preferred):**
   ```bash
   cd ~/Claude\ Projects/yral-rishi-hetzner-infra-template
   bash scripts/fix-failed-replicas.sh
   ```
   This script SSHes to rishi-1, identifies failed replicas, and runs
   `patronictl reinit` on each one. Takes ~10-30 seconds.

2. **Manual fix (if the script doesn't work):**
   ```bash
   ssh deploy@138.201.137.181
   C=$(docker ps -qf "name=<STACK>_patroni-rishi" | head -1)
   
   # List the cluster to see which nodes are failed
   docker exec "$C" patronictl -c /etc/patroni.yml list
   
   # Reinit each failed replica (replace <SCOPE> and <NODE>)
   docker exec "$C" patronictl -c /etc/patroni.yml reinit <SCOPE> rishi-2 --force
   docker exec "$C" patronictl -c /etc/patroni.yml reinit <SCOPE> rishi-3 --force
   
   # Wait 30 seconds, then verify
   sleep 30
   docker exec "$C" patronictl -c /etc/patroni.yml list
   ```

3. **Verify all replicas are streaming:**
   ```
   | rishi-1 | Leader  | running   |
   | rishi-2 | Replica | streaming |  ← should say "streaming", not "start failed"
   | rishi-3 | Replica | streaming |  ← same
   ```

### Automatic recovery

The `infra-health.yml` workflow runs every 5 minutes and automatically
reinitializes failed replicas. If the self-healing worked, you'll see
the cluster recover without manual intervention. Check the workflow run
in GitHub Actions for details.

### Replicas stuck on old timeline (state "running", not "streaming")

After a failover, a replica may show `running` instead of `streaming` and
have a different timeline (TL) number than the leader. This means it's
running PostgreSQL but NOT replicating from the new leader — it's stuck
on the old leader's data.

The `infra-health.yml` auto-reinit catches this automatically. To fix
manually, reinit the stuck replica:

```bash
ssh deploy@138.201.137.181
C=$(docker ps -qf "name=<STACK>_patroni-rishi" | head -1)
docker exec "$C" patronictl -c /etc/patroni.yml reinit <SCOPE> rishi-3 --force
```

### When reinit doesn't work

If `patronictl reinit` fails repeatedly, the issue may be deeper:
- Check the replica's Patroni logs for the specific error
- The data volume may be corrupted beyond reinit — wipe it manually:
  ```bash
  # On the server with the failed replica (e.g., rishi-2):
  ssh deploy@136.243.150.84
  docker service scale <STACK>_patroni-rishi-2=0
  docker volume rm <STACK>_patroni-rishi-2-data
  docker service scale <STACK>_patroni-rishi-2=1
  ```
  This forces a complete fresh start.

---

## 3. Caddy Down

**Symptoms:** App completely unreachable. `curl https://<domain>/health`
returns connection refused or timeout. But SSHing to the server and
curling locally works fine.

**Cause:** The Caddy reverse proxy container crashed or its config is invalid.

### Steps

1. **Check if Caddy is running:**
   ```bash
   ssh deploy@138.201.137.181
   docker ps -f name=caddy
   ```
   If it's not listed, it crashed. If it shows "Restarting", it's crash-looping.

2. **Check Caddy logs:**
   ```bash
   docker logs --tail 30 caddy
   ```
   Look for: config parse errors, certificate errors, or bind port conflicts.

3. **Validate the Caddy config:**
   ```bash
   docker exec caddy caddy validate --config /etc/caddy/Caddyfile
   ```
   If this fails, a project's snippet file is broken.

4. **Find the broken snippet:**
   ```bash
   ls /home/deploy/caddy/conf.d/
   # Try removing each snippet one at a time and re-validating
   ```

5. **Restart Caddy:**
   ```bash
   docker restart caddy
   ```

6. **Check the OTHER server too** (Cloudflare round-robins between rishi-1
   and rishi-2):
   ```bash
   ssh deploy@136.243.150.84
   docker ps -f name=caddy
   docker logs --tail 30 caddy
   ```

### Prevention

The deploy-app.sh script validates Caddy config before AND after swapping
snippets. If a bad snippet is deployed, it's automatically removed. Caddy
crashes are most likely caused by manual edits to the Caddyfile.

---

## 4. etcd Cluster Degraded

**Symptoms:** `etcdctl endpoint health` shows fewer than 3 healthy nodes.
Patroni logs may show "failed to update leader key" or etcd connection errors.

**Cause:** etcd node crashed, network partition, or disk full.

**Impact:** etcd needs 2 of 3 nodes for quorum. With 1 node down, the cluster
still works but has no fault tolerance. With 2 nodes down, etcd loses quorum
and Patroni cannot elect a leader — new failovers will fail.

### Steps

1. **Check etcd health from rishi-1:**
   ```bash
   ssh deploy@138.201.137.181
   E=$(docker ps -qf "name=<STACK>_etcd-rishi-1" | head -1)
   docker exec "$E" etcdctl \
     --endpoints=http://etcd-rishi-1:2379,http://etcd-rishi-2:2379,http://etcd-rishi-3:2379 \
     endpoint health
   ```

2. **Check which node is unhealthy** and look at its logs:
   ```bash
   # If etcd-rishi-2 is unhealthy, check it on rishi-2:
   ssh deploy@136.243.150.84
   docker logs --tail 50 $(docker ps -qf "name=<STACK>_etcd-rishi-2" | head -1)
   ```

3. **Restart the unhealthy etcd node:**
   ```bash
   # From rishi-1 (Swarm manager):
   docker service update --force <STACK>_etcd-rishi-2
   ```

4. **If restart doesn't help** — the etcd data may be corrupted. Remove and
   recreate the volume:
   ```bash
   docker service scale <STACK>_etcd-rishi-2=0
   docker volume rm <STACK>_etcd-rishi-2-data
   docker service scale <STACK>_etcd-rishi-2=1
   ```
   The node will rejoin the cluster and sync from the other 2 nodes.

5. **If quorum is lost (2+ nodes down):**
   This is a critical situation. Patroni cannot elect a new leader, but the
   CURRENT leader keeps running. Do NOT restart the leader's Patroni.
   Focus on getting etcd back to 2+ nodes first:
   ```bash
   # Check which etcd nodes are still running
   docker service ls | grep etcd
   # Force-restart the down nodes one at a time
   docker service update --force <STACK>_etcd-rishi-2
   docker service update --force <STACK>_etcd-rishi-3
   ```

### Prevention

The etcd stack uses rolling updates (`parallelism: 1, delay: 30s`) so
Swarm never restarts all 3 nodes at once. etcd failures are rare and
usually caused by disk issues or network partitions.

---

## 5. Backup Failure

**Symptoms:** The backup.yml workflow shows red in GitHub Actions.
`infra-health.yml` reports "Last backup status: failure".

**Cause:** Database unreachable, S3 credentials expired, S3 bucket full,
or network issue to Hetzner Object Storage.

### Steps

1. **Check the failed workflow run:**
   ```bash
   gh run list --workflow=backup.yml --limit 5
   # Get the run ID of the failed run
   gh run view <RUN_ID> --log-failed
   ```

2. **Common failures and fixes:**

   | Error in logs | Fix |
   |---|---|
   | `pg_dump: connection refused` | Database is down — fix Patroni first (playbook 1/2) |
   | `mc: Access Denied` | S3 credentials expired — rotate in GitHub Secrets |
   | `dump file is X bytes — too small` | pg_dump connected but got no data — check POSTGRES_DB name |
   | `VERIFICATION FAILED` | Upload succeeded but verify failed — re-run manually |

3. **Trigger a manual backup:**
   ```bash
   gh workflow run backup.yml
   gh run watch   # watch it complete
   ```

4. **Verify the backup exists in S3:**
   ```bash
   # From a machine with mc configured:
   mc ls hetzner/rishi-yral/<PROJECT_REPO>/daily/
   ```

### Prevention

Backups run daily at 3:00 AM UTC. The infra-health.yml workflow checks
the last backup status every 5 minutes. If you have Uptime Kuma configured,
backup failures are included in the health status push.

---

## 6. Database Restore

**When to use:** Data corruption, accidental deletion, or disaster recovery.

### Steps

1. **Restore from the latest backup:**
   ```bash
   bash scripts/restore-from-backup.sh --latest
   ```

2. **Restore from a specific date:**
   ```bash
   bash scripts/restore-from-backup.sh --date 2026-04-10
   ```

3. **What the restore script does:**
   - Downloads the backup from S3
   - Drops the existing database
   - Creates a fresh database
   - Restores the SQL dump
   - Re-runs any pending migrations
   - Restarts app containers to clear stale connection pools

4. **After restoring, verify:**
   ```bash
   curl https://<domain>/health
   curl https://<domain>/
   ```

### Important notes

- **RPO (data loss window):** Up to 24 hours. Backups run at 3:00 AM UTC.
  If the database is corrupted at 14:00, you lose 11 hours of data.
- **Streaming replication protects against server failure** (zero data loss),
  but NOT against data corruption (corruption replicates to all nodes).
- **Restore requires the Patroni leader to be running.** If the leader is
  down, fix Patroni first (playbooks 1/2).

---

## 7. Failed Deploy

**Symptoms:** GitHub Actions deploy workflow failed. App may be partially
updated (rishi-1 on new version, rishi-2 on old).

### Steps

1. **Check the CI logs:**
   ```bash
   gh run list --workflow=deploy.yml --limit 5
   gh run view <RUN_ID> --log-failed
   ```

2. **Common failures:**

   | Where it failed | What happened | Fix |
   |---|---|---|
   | gitleaks | Secret accidentally committed | Remove the secret, add to .gitleaks.toml allowlist if false positive |
   | test | Unit test or template integrity failed | Fix the test, push again |
   | build-and-push | Docker build failed | Check Dockerfile syntax, dependency issues |
   | Trivy CRITICAL | Critical CVE in a dependency | Update the vulnerable package, rebuild |
   | deploy-db-stack | Swarm stack deploy failed | Check Patroni/etcd logs on rishi-1 |
   | deploy-app Server 1 | Canary failed health check | Auto-rolled back. Check app logs for crash reason |
   | deploy-app Server 2 | Server 2 deploy failed | Server 1 is on new version, Server 2 rolled back. Fix and re-push |

3. **If the canary auto-rolled back:**
   ```bash
   # Check what's running on rishi-1
   ssh deploy@138.201.137.181
   docker ps -f name=<PROJECT_REPO>
   cat /home/deploy/<PROJECT_REPO>/.last_good_image_tag
   ```
   The auto-rollback restores the previous known-good image. The
   `.last_good_image_tag` file shows which version is running.

4. **To manually deploy a specific version:**
   ```bash
   ssh deploy@138.201.137.181
   cd /home/deploy/<PROJECT_REPO>
   IMAGE_TAG=<git-sha> docker compose up -d
   ```

---

## 8. Database Read-Only

**Symptoms:** The counter returns the same value on every request, or
the app returns 503 with "Database unavailable". Patroni logs show
"cannot execute UPDATE in a read-only transaction".

**Cause:** The app's connection pool is connected to a node that WAS the
leader but has been demoted to a read-only replica (failover happened).

### Steps

1. **Check who the current leader is:**
   ```bash
   ssh deploy@138.201.137.181
   C=$(docker ps -qf "name=<STACK>_patroni-rishi" | head -1)
   docker exec "$C" patronictl -c /etc/patroni.yml list
   ```

2. **The app should auto-recover.** The retry logic in `database.py`
   detects `ReadOnlySqlTransaction` errors and gets a fresh connection
   through HAProxy (which routes to the new leader). This takes up to
   3 attempts (~1 second).

3. **If auto-recovery isn't working**, restart the app container to
   force a new connection pool:
   ```bash
   ssh deploy@138.201.137.181
   cd /home/deploy/<PROJECT_REPO>
   docker compose restart
   ```

4. **Check HAProxy is routing to the correct leader:**
   ```bash
   docker logs --tail 20 $(docker ps -qf "name=<STACK>_haproxy" | head -1)
   ```
   You should see the current leader in the connection logs. If HAProxy
   shows "no server available", the leader may not be responding to
   health checks — see playbook 1.

---

## General Debugging Commands

```bash
# View all containers for a service
docker ps -f "name=<STACK>"

# View Patroni cluster status
docker exec $(docker ps -qf "name=<STACK>_patroni-rishi" | head -1) \
  patronictl -c /etc/patroni.yml list

# View etcd cluster health
docker exec $(docker ps -qf "name=<STACK>_etcd-rishi-1" | head -1) \
  etcdctl --endpoints=http://etcd-rishi-1:2379,http://etcd-rishi-2:2379,http://etcd-rishi-3:2379 \
  endpoint health

# View HAProxy connection logs
docker logs --tail 50 $(docker ps -qf "name=<STACK>_haproxy" | head -1)

# View app container logs
docker logs --tail 50 <PROJECT_REPO>

# View Caddy logs
docker logs --tail 50 caddy

# Check Docker Swarm node status
docker node ls

# Check Docker Swarm service status
docker stack services <STACK>

# Check Docker Swarm service task status (shows crashes, restarts)
docker stack ps <STACK>
```
