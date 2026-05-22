FROM python:3.12-slim-bookworm AS builder

ARG OPENCODE_VERSION=1.15.7
ARG CLAUDE_CODE_VERSION=2.1.148
ARG KUBECTL_VERSION=v1.32.0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    ripgrep \
    git \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-x64.tar.gz" \
    | tar xz -C /usr/local/bin/ \
    && opencode --version

RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version

RUN npm install -g @anthropic-ai/claude-code-linux-x64@${CLAUDE_CODE_VERSION} \
    && claude --version 2>&1

WORKDIR /opt/agents
COPY . .

RUN pip install --no-cache-dir -e ".[dev]"

RUN mkdir -p /root/.config/opencode

COPY opencode.pod.json /root/.config/opencode/opencode.json
COPY claude.pod.json /root/.claude.json

WORKDIR /workspace

ENV OPENCODE_AGENTS_DIR=/opt/agents

CMD ["sleep", "infinity"]
