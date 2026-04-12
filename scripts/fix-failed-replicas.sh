#!/bin/bash
# ---------------------------------------------------------------------------
# fix-failed-replicas.sh — reinitialize Patroni replicas that are stuck in
# "start failed" state.
#
# WHAT IS "start failed"?
# It means the replica tried to start PostgreSQL but couldn't — usually
# because of stale lock files, corrupted data, or WAL (write-ahead log)
# that diverged too far from the leader. The replica is stuck and won't
# recover on its own.
#
# WHAT DOES THIS SCRIPT DO?
#   1. SSHes to rishi-1 (the Swarm manager) and checks the Patroni cluster
#   2. Identifies which replicas are in "start failed" state
#   3. Verifies a healthy leader exists (we need it to copy data from)
#   4. Runs `patronictl reinit` on each failed replica
#      (this wipes the replica's data and does a fresh copy from the leader)
#   5. Waits up to 120 seconds for replicas to finish re-bootstrapping
#   6. Verifies the cluster is healthy (1 leader + 2 streaming replicas)
#
# WHAT IS `patronictl reinit`?
# Patroni's official command to recover a failed replica. It:
#   - Stops PostgreSQL on the replica
#   - Deletes the replica's data directory
#   - Runs pg_basebackup to copy ALL data from the current leader
#   - Starts PostgreSQL on the replica as a streaming replica
# This is safe because replicas are read-only copies of the leader — they
# never have data the leader doesn't have.
#
# WHEN TO USE THIS:
#   - When `patronictl list` shows replicas in "start failed"
#   - After a server crash or unclean Docker shutdown
#   - The infra-health.yml workflow also runs this automatically
#
# USAGE:
#   bash scripts/fix-failed-replicas.sh
#
# SAFE TO RE-RUN: if all replicas are healthy, it does nothing.
# ---------------------------------------------------------------------------

# Stop on any error. Treat unset variables as errors.
set -euo pipefail

# Find the repo root (one directory up from scripts/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load project.config (gets SWARM_STACK, PATRONI_SCOPE, etc.)
set -a
# shellcheck disable=SC1091
source "${REPO_ROOT}/project.config"
set +a

# Load servers.config (gets SERVER_1_IP, DEPLOY_USER, SSH_KEY_PATH)
# shellcheck disable=SC1091
source "${REPO_ROOT}/servers.config"

# Expand ~ in the SSH key path to the actual home directory
SSH_KEY="${SSH_KEY_PATH/#\~/$HOME}"

# Helper: SSH to a server as the deploy user
ssh_to() {
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR \
        "${DEPLOY_USER}@$1" "$2"
}

echo "==> Checking Patroni cluster health..."
echo "    Stack: ${SWARM_STACK}"
echo "    Scope: ${PATRONI_SCOPE}"
echo ""

# Step 1: Get the current cluster status from rishi-1 (the Swarm manager)
CLUSTER_STATUS=$(ssh_to "${SERVER_1_IP}" "
    C=\$(docker ps -qf 'name=${SWARM_STACK}_patroni-rishi' | head -1)
    if [ -z \"\$C\" ]; then
        echo 'NO_CONTAINER'
        exit 1
    fi
    docker exec \"\$C\" patronictl -c /etc/patroni.yml list 2>/dev/null
")

# Print the full cluster table so the user can see the current state
echo "${CLUSTER_STATUS}"
echo ""

# Check if we found a container at all
if echo "${CLUSTER_STATUS}" | grep -q "NO_CONTAINER"; then
    echo "FATAL: no Patroni container found on rishi-1. Is the stack running?"
    exit 1
fi

# Step 2: Check if there's a healthy leader (we need one to reinit from)
LEADER_COUNT=$(echo "${CLUSTER_STATUS}" | grep -c "Leader" || true)
if [ "${LEADER_COUNT}" -lt 1 ]; then
    echo "FATAL: no leader found in the cluster. Cannot reinit without a leader."
    echo "       Manual intervention required — check Patroni and etcd logs."
    exit 1
fi
echo "✓ Leader is running"

# Step 3: Find replicas in "start failed" state
FAILED_NODES=$(echo "${CLUSTER_STATUS}" | grep "start failed" | awk -F'|' '{gsub(/ /,"",$2); print $2}')
if [ -z "${FAILED_NODES}" ]; then
    echo "✓ No failed replicas — cluster is healthy. Nothing to do."
    exit 0
fi

# Count and list the failed nodes
FAILED_COUNT=$(echo "${FAILED_NODES}" | wc -l | tr -d ' ')
echo ""
echo "Found ${FAILED_COUNT} failed replica(s): ${FAILED_NODES//$'\n'/, }"
echo ""

# Step 4: Reinit each failed replica using patronictl
for NODE in ${FAILED_NODES}; do
    echo "==> Reinitializing ${NODE}..."
    # patronictl reinit <scope> <node-name> --force
    # --force skips the interactive confirmation prompt
    ssh_to "${SERVER_1_IP}" "
        C=\$(docker ps -qf 'name=${SWARM_STACK}_patroni-rishi' | head -1)
        docker exec \"\$C\" patronictl -c /etc/patroni.yml reinit ${PATRONI_SCOPE} ${NODE} --force 2>&1
    " || echo "    WARNING: reinit command returned non-zero for ${NODE} (may still be working)"
done

# Step 5: Wait for replicas to finish bootstrapping
echo ""
echo "==> Waiting for replicas to re-bootstrap (up to 120 seconds)..."
echo "    (pg_basebackup copies ALL data from the leader — this takes a moment)"
HEALTHY=0
for i in $(seq 1 40); do
    sleep 3
    # Check the cluster status again
    STATUS=$(ssh_to "${SERVER_1_IP}" "
        C=\$(docker ps -qf 'name=${SWARM_STACK}_patroni-rishi' | head -1)
        docker exec \"\$C\" patronictl -c /etc/patroni.yml list 2>/dev/null
    " || echo "")

    # Count streaming replicas
    STREAMING=$(echo "${STATUS}" | grep -c "streaming" || true)
    STILL_FAILED=$(echo "${STATUS}" | grep -c "start failed" || true)
    CREATING=$(echo "${STATUS}" | grep -c "creating replica" || true)

    if [ "${STREAMING}" -ge 2 ] && [ "${STILL_FAILED}" -eq 0 ]; then
        echo ""
        echo "${STATUS}"
        echo ""
        echo "✓ All replicas recovered after $((i * 3)) seconds"
        HEALTHY=1
        break
    fi

    # Print progress every 15 seconds
    if [ $((i % 5)) -eq 0 ]; then
        echo "    ${STREAMING} streaming, ${STILL_FAILED} failed, ${CREATING} bootstrapping... ($((i * 3))s)"
    fi
done

if [ "${HEALTHY}" -eq 0 ]; then
    echo ""
    echo "WARNING: replicas did not fully recover within 120 seconds."
    echo "         This can be normal for large databases (pg_basebackup is still copying)."
    echo "         Check again in a minute:"
    echo "         ssh deploy@${SERVER_1_IP} 'docker exec \$(docker ps -qf name=${SWARM_STACK}_patroni-rishi | head -1) patronictl -c /etc/patroni.yml list'"
    echo ""
    # Print current state for reference
    ssh_to "${SERVER_1_IP}" "
        C=\$(docker ps -qf 'name=${SWARM_STACK}_patroni-rishi' | head -1)
        docker exec \"\$C\" patronictl -c /etc/patroni.yml list 2>/dev/null
    " || true
fi

echo ""
echo "Done."
