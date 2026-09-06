# Trading Science Framework - Multi-stage Docker Build
#
# Stage 1: Builder - Install dependencies, compile
# Stage 2: Runtime - Minimal, non-root, read-only filesystem
#
# Build: docker build -t trading-science-framework:latest -f deployment/docker/Dockerfile .
# Run:   docker run --rm -it --env-file .env trading-science-framework:latest tsf --check-config

# ============================================================
# BUILD ARGUMENTS
# ============================================================
ARG PYTHON_VERSION=3.11-slim
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION

# ============================================================
# STAGE 1: BUILDER
# ============================================================
FROM python:${PYTHON_VERSION} AS builder

# Build metadata
LABEL org.opencontainers.image.title="Trading Science Framework" \
      org.opencontainers.image.description="Marco de Investigación Científica Aplicada al Trading" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.authors="Diego Alejandro Saenz Falcon" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/DiegoAlejandroSaenzFalcon/Trading-Ciencia" \
      org.opencontainers.image.documentation="https://diegoalejandrosaenzfalcon.github.io/Trading-Ciencia/"

# Install system dependencies for building
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    g++ \
    libatlas-base-dev \
    libffi-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Create virtual environment
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

# Upgrade pip and install build tools
RUN pip install --no-cache-dir --upgrade pip setuptools wheel

# Copy dependency files first (cache layer)
COPY pyproject.toml ./

# Install dependencies in virtual environment
RUN pip install --no-cache-dir -e ".[dev,notebooks,web,monitoring]"

# ============================================================
# STAGE 2: RUNTIME
# ============================================================
FROM python:${PYTHON_VERSION} AS runtime

# Runtime metadata
LABEL org.opencontainers.image.title="Trading Science Framework" \
      org.opencontainers.image.description="Marco de Investigación Científica Aplicada al Trading" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.authors="Diego Alejandro Saenz Falcon" \
      org.opencontainers.image.licenses="MIT"

# Install runtime-only system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libatlas-base-dev \
    libffi8 \
    libssl3 \
    ca-certificates \
    curl \
    tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Create non-root user
ARG UID=1000
ARG GID=1000
RUN groupadd -g ${GID} tsf && \
    useradd -u ${UID} -g ${GID} -m -s /bin/bash tsf

# Copy virtual environment from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Set working directory
WORKDIR /app

# Copy application code
COPY --chown=tsf:tsf tsf/ ./tsf/
COPY --chown=tsf:tsf config/ ./config/
COPY --chown=tsf:tsf deployment/scripts/ ./scripts/
COPY --chown=tsf:tsf pyproject.toml ./

# Create required directories with proper permissions
RUN mkdir -p \
    /app/data/raw \
    /app/data/pit \
    /app/data/audits \
    /app/data/manifests \
    /app/research/hypotheses \
    /app/research/pipelines \
    /app/research/backtests \
    /app/research/evidence \
    /app/research/adjudications \
    /app/research/artifacts \
    /app/strategies \
    /app/lessons \
    /app/governance \
    /app/logs \
    /app/monitoring \
    && chown -R tsf:tsf /app

# Switch to non-root user
USER tsf

# Environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TSF_ENV=production \
    TZ=UTC

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD python -c "from tsf.config import settings; print('OK')" || exit 1

# Default command
ENTRYPOINT ["tsf"]
CMD ["--help"]

# ============================================================
# STAGE 3: DEVELOPMENT (Optional - for local dev)
# ============================================================
FROM runtime AS development

USER root

# Install dev tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    vim \
    htop \
    && rm -rf /var/lib/apt/lists/*

# Install dev dependencies
RUN pip install --no-cache-dir -e ".[dev,notebooks,web,monitoring]"

# Install pre-commit
RUN pip install --no-cache-dir pre-commit

USER tsf

# Override entrypoint for development
ENTRYPOINT ["bash"]