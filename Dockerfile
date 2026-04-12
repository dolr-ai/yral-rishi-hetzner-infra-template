# ---------------------------------------------------------------------------
# Dockerfile — instructions for building the app's Docker image.
#
# WHAT IS A DOCKER IMAGE?
# A Docker image is a snapshot of a complete, runnable application: the
# operating system, Python, all libraries, and your code — packaged into
# a single file. You can think of it as a "template" for a container
# (a lightweight virtual machine).
#
# WHAT IS A CONTAINER?
# A container is a running instance of an image. It's isolated from the
# host system — it has its own filesystem, network, and processes.
# Containers start in milliseconds (unlike virtual machines which take minutes).
#
# HOW IS THIS FILE USED?
# CI runs: docker build -t ghcr.io/dolr-ai/yral-my-service:abc123 .
# This reads the Dockerfile, executes each instruction in order, and
# produces an image tagged with the git commit SHA (abc123).
#
# The image is then pushed to GHCR (GitHub Container Registry) and pulled
# by each server during deployment.
# ---------------------------------------------------------------------------

# START FROM an official Python 3.12 image.
# "slim" means a minimal version of Debian Linux with Python pre-installed.
# It's ~150MB (vs ~900MB for the full image). We don't need build tools.
FROM python:3.12-slim

# LABELS are metadata attached to the image. They don't affect how the
# container runs — they're for humans and tools to identify the image.
# OCI (Open Container Initiative) is the standard for container labels.
LABEL org.opencontainers.image.source="https://github.com/dolr-ai/yral-rishi-hetzner-infra-template"
LABEL org.opencontainers.image.description="dolr-ai service app image"

# CREATE A NON-ROOT USER called "appuser" (UID 1001, GID 1001).
#
# WHY? By default, containers run as root (the superuser with full permissions).
# If an attacker finds a bug in our code, they'd have root access inside the
# container — making it easier to escape to the host server.
#
# With a non-root user, the attacker can only read app files and write to /tmp.
# They can't install packages, modify system files, or access Docker sockets.
#
# groupadd: creates a system group named "appuser"
# useradd: creates a system user named "appuser" in that group
# --create-home: gives the user a home directory
# --shell /usr/sbin/nologin: the user can't open an interactive shell
RUN groupadd --system --gid 1001 appuser && \
    useradd  --system --uid 1001 --gid appuser --create-home --shell /usr/sbin/nologin appuser

# SET THE WORKING DIRECTORY to /app inside the container.
# All subsequent commands (COPY, RUN, CMD) run from this directory.
WORKDIR /app

# COPY requirements.txt into the container and install Python packages.
# We copy requirements.txt FIRST (before the app code) because Docker
# caches each layer. If requirements.txt hasn't changed, Docker reuses
# the cached layer and skips the slow "pip install" step — making builds
# much faster when only app code changes.
COPY requirements.txt .

# Install all Python packages listed in requirements.txt.
# --no-cache-dir: don't keep pip's download cache (saves ~50MB of disk).
RUN pip install --no-cache-dir -r requirements.txt

# COPY the application code into the container.
# --chown=appuser:appuser: make the files owned by our non-root user
# (not root). This way, the app can read its own files when running as appuser.
#
# app/ contains: main.py (web routes) and database.py (DB connection)
# infra/ contains: sentry.py, vault.py, uptime_kuma.py (integration helpers)
COPY --chown=appuser:appuser app/ .
COPY --chown=appuser:appuser infra/ ./infra/

# SWITCH to the non-root user for all runtime operations.
# Everything after this line runs as "appuser" (UID 1001), not root.
USER appuser

# DOCUMENT that the container listens on port 8000.
# This doesn't actually open the port — it's informational for humans
# and tools reading the Dockerfile.
EXPOSE 8000

# THE COMMAND that runs when the container starts.
# "uvicorn" is the web server.
# "main:app" means "in the file main.py, find the variable called app."
# "--host 0.0.0.0" means "listen on ALL network interfaces" (not just localhost).
# "--port 8000" means "listen on port 8000."
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
