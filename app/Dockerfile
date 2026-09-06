# Multi-stage so the runtime image carries no build toolchain.
#
# databricks-sql-connector pulls pyarrow and thrift, which need a compiler on
# some platforms. Building in one stage and copying the installed packages into
# a clean image keeps the result small and removes gcc from anything that faces
# the network.
FROM python:3.12-slim AS build

WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir -r requirements.txt

# --- runtime --------------------------------------------------------------
FROM python:3.12-slim

# Non-root. Container Apps does not require it, but a process that never needs
# to write outside its own directory should not be able to.
RUN useradd --create-home --uid 10001 app
USER app
WORKDIR /home/app

COPY --from=build /opt/venv /opt/venv
COPY --chown=app:app src/ ./src/

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Container Apps injects the port it wants; defaulting keeps `docker run` working
# locally without extra flags.
ENV PORT=8000
EXPOSE 8000

# Single worker deliberately. Container Apps scales by adding REPLICAS, not by
# adding processes inside one container - so a second worker just doubles idle
# memory and confuses the autoscaler's per-replica concurrency signal.
CMD ["sh", "-c", "uvicorn src.main:app --host 0.0.0.0 --port ${PORT} --workers 1"]
