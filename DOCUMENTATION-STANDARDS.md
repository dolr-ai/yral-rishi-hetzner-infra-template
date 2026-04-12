# Documentation Standards for dolr-ai Services

Every service built from this template MUST follow these documentation rules.
These rules exist because Rishi has ADHD and is learning to code — every file
needs to be understandable on first read, without googling, without asking
someone, without prior programming knowledge.

**The goal:** someone who has never seen the codebase should be able to read
every file and understand 100% of what's happening.

---

## Rule 1: Every line gets a comment

Every single line of code gets a plain English comment explaining what it does.
No exceptions. If a line is "obvious" to a programmer, it's NOT obvious to
Rishi — comment it anyway.

### Comment style for code files (Python, shell scripts, SQL)

```python
# BAD — no comment
app = FastAPI()

# BAD — restates the code (useless)
# Create FastAPI app
app = FastAPI()

# GOOD — explains what this does and WHY it matters
# Create the web application. This is the "app" variable that uvicorn looks for.
# FastAPI handles: receiving HTTP requests, routing them to the right function,
# converting Python dictionaries to JSON responses, and sending them back.
app = FastAPI()
```

### Comment style for YAML files (docker-compose, stack files, workflows)

```yaml
# BAD
image: quay.io/coreos/etcd:v3.5.16

# GOOD
# Official etcd Docker image from CoreOS (the company that created etcd)
# v3.5.16 is a stable release
image: quay.io/coreos/etcd:v3.5.16
```

### Comment style for shell scripts

```bash
# BAD
set -euo pipefail

# GOOD
# "set -euo pipefail" = strict error handling:
#   -e: stop on any error
#   -u: treat unset variables as errors (catch typos)
#   -o pipefail: if any command in a pipe fails, the whole pipe fails
set -euo pipefail
```

### Rules for what to explain

1. **Technical terms** get explained in parentheses on first use:
   ```
   # "overlay" = a virtual network that spans multiple physical servers
   driver: overlay
   ```

2. **Shell syntax** gets broken down:
   ```bash
   # "${VAR:-default}" means "use VAR if set, otherwise use default"
   PGHOST="${PGHOST:-haproxy-rishi-1}"
   ```

3. **Why, not just what.** The MOST important thing to explain is WHY:
   ```bash
   # WHY BEFORE, NOT AFTER?
   # If migrations ran after the new app starts, there's a window where the
   # new code expects columns/tables that don't exist yet → app crashes.
   ```

4. **Flags and options** get individual explanations:
   ```bash
   # curl options:
   #   -s: silent (don't show progress bar)
   #   -o /dev/null: throw away the response body
   #   -w '%{http_code}': print ONLY the HTTP status code
   #   --max-time 10: give up after 10 seconds
   ```

5. **Numbers and magic values** get justified:
   ```yaml
   # max_attempts=10, window=120s: give up after 10 restarts in 2 minutes
   # (prevents infinite restart loops from burning CPU)
   ```

---

## Rule 2: Every file starts with a header block

Every file begins with a comment block (using the file's comment syntax)
that explains:

1. **What this file is** (one line)
2. **What it does** (numbered list of steps, 3-8 items)
3. **Key concepts** (explain any terms a non-programmer wouldn't know)
4. **When/how it's used** (what triggers this file to run)
5. **Required inputs** (env vars, secrets, config files it reads)

### Template for shell scripts

```bash
#!/bin/bash
# ---------------------------------------------------------------------------
# <filename> — <one-line description of what this file does>
#
# WHAT DOES THIS SCRIPT DO? (N steps)
#   1. <step one>
#   2. <step two>
#   ...
#
# WHAT IS <CONCEPT>?
#   <2-3 sentence explanation of any non-obvious concept>
#
# WHEN DOES THIS RUN?
#   <what triggers it — CI, cron, manual, etc.>
#
# USAGE:
#   <exact command to run it>
#
# REQUIRED ENVIRONMENT VARIABLES:
#   <list each required env var and what it contains>
# ---------------------------------------------------------------------------
```

### Template for Python files

```python
# ---------------------------------------------------------------------------
# <filename> — <one-line description>
#
# <2-4 sentences explaining what this file does and why it exists>
#
# KEY CONCEPTS:
#   <explain any non-obvious concept>
#
# DEPENDENCIES:
#   <what libraries/modules this file uses and why>
# ---------------------------------------------------------------------------
```

### Template for YAML files (stack files, workflows)

```yaml
# ---------------------------------------------------------------------------
# <filename> — <one-line description>
#
# WHAT IS <CONCEPT>?
# <2-4 sentences explaining the technology this file configures>
#
# HOW IS THIS FILE USED?
# <what command runs this file, or what system reads it>
#
# WHAT ARE THE ${VAR} THINGS?
# <explain variable interpolation if the file uses it>
# ---------------------------------------------------------------------------
```

---

## Rule 3: Section separators for long files

Files with more than ~30 lines of code use visual separators between
logical sections:

```bash
# ----- STEP 1: Do the first thing -----
<code>

# ----- STEP 2: Do the next thing -----
<code>
```

Or for major sections:

```bash
# =====================================================================
# STEP 1: Validate prerequisites
# =====================================================================
<code>
```

Or for inline grouping within YAML:

```yaml
  # ----- etcd on rishi-1 -----
  etcd-rishi-1:
    ...

  # ----- etcd on rishi-2 (identical config, different server) -----
  etcd-rishi-2:
    ...
```

---

## Rule 4: Required documentation files

Every service MUST have these documentation files. They are copied from
the template — update them for your service's specifics.

### DEEP-DIVE.md (the first thing to read)

Explains the entire service **visually** for someone who has never seen
the code. Must include:

1. **"What happens when a user visits the URL"** — step-by-step request
   flow from browser to database and back, with ASCII diagrams
2. **"The files, one by one"** — every file in the repo explained in
   plain English, with what each config value means
3. **Key architectural decisions** — WHY things are built this way
   (not just what they do)
4. **Diagrams** — ASCII art showing:
   - Request flow (browser → Cloudflare → Caddy → app → HAProxy → DB)
   - Deploy flow (git push → CI → canary → rollback)
   - Database HA (leader + replicas + failover)
   - Network topology (which containers talk to which)
5. **Glossary** — every technical term used in the project, defined in
   one sentence

### READING-ORDER.md (the second thing to read)

A numbered list of EVERY file in the repo, in the order they should be
read. Grouped into steps (Step 1: big picture, Step 2: config, Step 3:
app code, etc.). Each step explains what you'll understand after reading
those files.

Rules:
- Every file in the repo must appear somewhere in the reading order
- Group related files into steps (3-6 files per step)
- Each step builds on the previous one — never reference something that
  hasn't been introduced yet
- End with a "Quick reference: what's in each directory" section showing
  the full file tree with one-line descriptions

### CLAUDE.md (architecture reference)

The "cheat sheet" for the project. Must include:
- What this repo is (one paragraph)
- Architecture diagram (ASCII)
- Server list with IPs and roles
- Config files (what each one contains)
- Deploy flow (step by step)
- Database HA components
- Backup schedule and retention
- Migration rules
- Security posture summary
- File structure table (path → purpose)
- GitHub Secrets list
- Quick reference commands

### RUNBOOK.md (incident playbooks)

Step-by-step guides for every common incident. Each playbook has:
- **Symptoms** — what the user sees
- **Cause** — why it happened
- **Impact** — how bad is it
- **Steps** — numbered, with exact commands to copy-paste
- **Prevention** — how to stop it from happening again

Required playbooks for any service with a database:
1. Database leader flapping
2. Database replica recovery
3. Reverse proxy down (Caddy)
4. etcd cluster degraded
5. Backup failure
6. Database restore
7. Failed deploy
8. Database read-only after failover

### TEMPLATE.md (how to create a service from this template)

Only exists in the template repo itself (not in services created from it).

### SECURITY.md (threat model)

Must document:
- What's protected and how
- What's NOT protected yet (deferred TODOs)
- Attack surface analysis
- Secret management approach

### MIGRATIONS.md (database schema change rules)

Must document:
- How to add a migration
- The expand-contract pattern
- What "backward-compatible" means
- Examples of safe vs unsafe migrations

---

## Rule 5: Comments explain "WHY" blocks

Whenever there's a non-obvious design decision, add a **WHY** block:

```python
# WHY LAZY INITIALIZATION?
# When the Docker container starts, Python imports all files. If we
# tried to connect to the database here and it wasn't ready yet,
# the ENTIRE APP would crash before it even started.
```

```yaml
# WHY "TCP MODE"?
# PostgreSQL uses its own binary protocol (not HTTP). HAProxy doesn't
# need to understand the data — it just forwards raw bytes.
```

```bash
# WHY BEFORE, NOT AFTER?
# If migrations ran after the new app starts, there's a window where
# the new code expects columns that don't exist yet → app crashes.
```

Common WHY questions to answer:
- WHY this approach instead of the obvious alternative?
- WHY this specific number/timeout/retry count?
- WHY is this here and not somewhere else?
- WHY do we need this at all?

---

## Rule 6: No assumed knowledge

Never assume the reader knows:
- What a specific Linux command does (explain every flag)
- What a Docker concept means (volumes, networks, services, stacks)
- What a database term means (WAL, replication, failover, quorum)
- What a networking concept means (TCP, DNS, TLS, ports, overlay)
- What a CI/CD concept means (workflow, job, step, secret, artifact)
- What a Python/programming concept means (decorator, context manager, pool)

Every technical term must be explained **the first time it appears in each
file**. Don't say "see file X" — explain it again in this file. The reader
might be reading this file first.

---

## Rule 7: Test documentation

Every test file gets a module docstring explaining:
- What is being tested
- Why these tests matter (what breaks if the tested code is wrong)
- What mocking approach is used and why

Every test function gets a docstring explaining:
- The scenario being tested (in plain English)
- What the expected behavior is

```python
def test_retry_on_read_only_transaction(self):
    """
    ReadOnlySqlTransaction triggers retry.

    This is the FAILOVER case: the app still has a connection to the
    old leader, which is now a read-only replica. The retry gets a
    fresh connection that goes through HAProxy to the new leader.
    """
```

---

## Rule 8: Commit messages

Commit messages explain the "why" of the change, not just the "what":

```
# BAD
update deploy.yml

# GOOD
fix: infra-health.yml silently passed on degraded Patroni state

Previously, "degraded" (1 leader but <2 replicas) was treated as a
warning and did NOT exit 1. Uptime Kuma was told "up" even with 2
failed replicas. Now degraded = failure + auto-reinit.
```

---

## Checklist for new services

When creating a new service from the template, verify:

- [ ] Every code file has line-by-line comments
- [ ] Every file has a header block
- [ ] DEEP-DIVE.md is updated for the new service's request flow
- [ ] READING-ORDER.md lists all files in correct reading order
- [ ] CLAUDE.md has correct architecture, server list, and commands
- [ ] RUNBOOK.md playbooks are updated for the service's specifics
- [ ] SECURITY.md documents the service's specific security concerns
- [ ] MIGRATIONS.md has the service's migration rules
- [ ] All technical terms are explained on first use in each file
- [ ] All WHY decisions are documented
- [ ] All tests have docstrings
- [ ] README.md has a one-paragraph description

---

## Why these rules exist

Rishi has ADHD. When reading code:
- **Skipping ahead is dangerous** — hence READING-ORDER.md with strict ordering
- **Context switches are expensive** — hence self-contained explanations
  in every file (don't say "see other file")
- **Working memory is limited** — hence header blocks that summarize what
  the file does before any code appears
- **Motivation comes from understanding** — hence explaining WHY (not just
  what), so every decision feels intentional and logical
- **2-3 hours per day** — the documentation must be good enough that Rishi
  can pick up where he left off without re-reading everything

These rules are non-negotiable. Every file, every line, every time.
