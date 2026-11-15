# Agent runtime image. Build: docker build -t agent-img docker/
# Based on Anthropic's reference devcontainer, adapted for headless runs.
#
# BASE_IMAGE picks the project toolchain; everything else (firewall, gh, Claude Code,
# user `agent`) is the same in every variant. Any Debian/Ubuntu-based image works.
# Default eclipse-temurin:25-jdk-noble → agent-img (JDK 25, so Gradle never downloads a toolchain).
# Normally bin/agent builds it: IMAGE=node:22-bookworm in agents/<repo>/repo.env (or an agent.env)
# → agent-img:node-22-bookworm, rebuilt when a file here changes. By hand:
#   docker build --build-arg BASE_IMAGE=node:22-bookworm -t agent-img:node-22-bookworm docker/
ARG BASE_IMAGE=eclipse-temurin:25-jdk-noble
FROM ${BASE_IMAGE}

ARG CLAUDE_CODE_VERSION=latest
ARG AGENT_UID=1000
ARG AGENT_GID=1000

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq unzip less procps \
      iptables ipset iproute2 dnsutils util-linux gnupg \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI from its official apt repo
RUN install -d -m 755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Non-root user; UID matches the host user so files in mounted logs/ stay owned by you
# (bin/agent passes `id -u`/`id -g`; by hand add --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g)).
# Base images may already have a user/group with that ID (`ubuntu`, `node`): remove it.
RUN test "${AGENT_UID}" -ne 0 -a "${AGENT_GID}" -ne 0 || { echo "AGENT_UID/AGENT_GID must not be 0" >&2; exit 1; } \
 && existing=$(getent passwd "${AGENT_UID}" | cut -d: -f1) \
 && if [ -n "$existing" ]; then userdel -r "$existing" 2>/dev/null || userdel "$existing"; fi \
 && existing=$(getent group "${AGENT_GID}" | cut -d: -f1) \
 && if [ -n "$existing" ]; then groupdel "$existing"; fi \
 && groupadd --gid "${AGENT_GID}" agent \
 && useradd --uid "${AGENT_UID}" --gid agent --create-home --shell /bin/bash agent \
 && install -d -o agent -g agent /logs

# Claude Code (native installer, no Node needed), installed as the agent user
USER agent
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"
USER root

# Mount points for optional cache volumes (CACHE_DIRS= in an agent config). A fresh named
# volume takes the owner of the directory it is mounted on; the container can't chown at
# run time, so every cache dir must exist here, owned by agent. Add yours to this list.
RUN install -d -o agent -g agent \
      /home/agent/.gradle /home/agent/.gradle/caches /home/agent/.gradle/wrapper \
      /home/agent/.m2 /home/agent/.m2/repository \
      /home/agent/.npm \
      /home/agent/.cache /home/agent/.cache/pip \
 && install -d /opt/agents-runner

ENV PATH=/home/agent/.local/bin:${PATH} \
    GIT_TERMINAL_PROMPT=0 \
    GH_PROMPT_DISABLED=1 \
    GH_NO_UPDATE_NOTIFIER=1 \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_TELEMETRY=1 \
    DISABLE_ERROR_REPORTING=1

COPY allowlist.txt /etc/agent-firewall/allowlist.txt
COPY --chmod=755 init-firewall.sh entrypoint.sh /usr/local/sbin/

WORKDIR /home/agent
# Starts as root only to apply the firewall; entrypoint drops to `agent`.
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
CMD ["bash"]
