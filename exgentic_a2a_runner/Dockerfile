FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        curl \
        jq \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

WORKDIR /app

# Copy dependency manifests first so the venv layer is cached independently
# of source changes.
COPY pyproject.toml uv.lock ./

# Pre-install all dependencies into the project venv so evaluate-benchmark.sh
# never needs to run `uv sync` at runtime.
RUN uv sync --frozen --no-dev --python 3.12

# Copy the rest of the source (scripts, lib, Python package, authbridge, etc.)
COPY . .

# Make all shell scripts executable
RUN find /app -name "*.sh" -exec chmod +x {} \;

ENV PATH="/app/.venv/bin:$PATH"

ENTRYPOINT ["/app/deploy-and-evaluate.sh"]
