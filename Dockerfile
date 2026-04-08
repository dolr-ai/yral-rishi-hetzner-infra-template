FROM python:3.12-slim

# Create non-root user to run the app. Defense in depth: a code-execution
# bug in the app or any pip dep no longer hands the attacker root inside
# the container, which is the most common foothold for container escapes.
RUN groupadd --system --gid 1001 appuser && \
    useradd  --system --uid 1001 --gid appuser --create-home --shell /usr/sbin/nologin appuser

WORKDIR /app

# pip install runs as root (needed to write into site-packages),
# then we chown the result to appuser so the runtime user can read it.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=appuser:appuser app/ .
COPY --chown=appuser:appuser infra/ ./infra/

USER appuser

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
