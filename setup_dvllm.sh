#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

OLLAMA_MODEL="${1:-mistral-nemo}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
DVLA_PORT="${DVLA_PORT:-8501}"
REPO_URL="https://github.com/ReversecLabs/damn-vulnerable-llm-agent.git"
SCRIPT_DIR="$(pwd)"
REPO_DIR="${SCRIPT_DIR}/damn-vulnerable-llm-agent"

say() { printf "\033[1;32m[*]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[!]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[x]\033[0m %s\n" "$*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

_docker() {
  if groups "$USER" | grep -q '\bdocker\b'; then
    docker "$@"
  else
    sudo docker "$@"
  fi
}

ID=""; VERSION_CODENAME=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  ID="${ID:-}"; VERSION_CODENAME="${VERSION_CODENAME:-}"
fi

say "Installing base tools (curl, git, jq)..."
if need_cmd apt-get; then
  sudo apt-get update -y
  sudo apt-get install -y curl git jq ca-certificates gnupg lsb-release
elif need_cmd dnf; then
  sudo dnf -y install curl git jq ca-certificates gnupg2
elif need_cmd yum; then
  sudo yum -y install curl git jq ca-certificates gnupg2
elif need_cmd pacman; then
  sudo pacman -Sy --noconfirm curl git jq ca-certificates
else
  warn "Unknown package manager; assuming curl/git/jq exist."
fi

if ! need_cmd docker; then
  say "Docker not found, installing..."
  if need_cmd apt-get; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME:-$(lsb_release -cs)} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
  elif need_cmd dnf; then
    sudo dnf -y install dnf-plugins-core
    sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
    sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
  elif need_cmd yum; then
    sudo yum -y install yum-utils
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker
  elif need_cmd pacman; then
    sudo pacman -Sy --noconfirm docker docker-compose
    sudo systemctl enable --now docker
  else
    warn "Falling back to Docker convenience script."
    curl -fsSL https://get.docker.com | sh
    sudo systemctl enable --now docker
  fi
else
  say "Docker already installed."
fi

if ! docker compose version >/dev/null 2>&1; then
  warn "Docker Compose v2 plugin missing; installing CLI plugin to /usr/local/lib/docker/cli-plugins"
  sudo mkdir -p /usr/local/lib/docker/cli-plugins
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH_DL="x86_64" ;;
    aarch64|arm64) ARCH_DL="aarch64" ;;
    *) ARCH_DL="x86_64"; warn "Unknown arch $ARCH; defaulting to x86_64";;
  esac
  sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${ARCH_DL}" -o /usr/local/lib/docker/cli-plugins/docker-compose
  sudo chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

say "Docker: $(_docker --version || true)"
say "Compose: $(_docker compose version || true)"

if ! groups "$USER" | grep -q '\bdocker\b'; then
  sudo usermod -aG docker "$USER" || true
fi

if [ -d "$REPO_DIR/.git" ]; then
  say "Updating repo in $REPO_DIR ..."
  git -C "$REPO_DIR" pull --rebase || true
else
  say "Cloning repo to $REPO_DIR ..."
  git clone "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"

say "Writing Dockerfile ..."
cat > Dockerfile <<'EOF'
FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential curl git \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN python -m pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir -r requirements.txt \
 && pip install --no-cache-dir 'litellm[proxy]' backoff

COPY . .

ENV PYTHONUNBUFFERED=1
EXPOSE 8501

CMD ["python", "-m", "streamlit", "run", "main.py", "--server.port=8501", "--server.address=0.0.0.0"]
EOF

say "Creating .env ..."
cat > .env <<EOF
model_name="ollama-${OLLAMA_MODEL}"
OLLAMA_HOST=http://ollama:${OLLAMA_PORT}
EOF
sed -n '1,40p' .env || true

if [ -f "llm-config.yaml" ]; then
  say "Configuring llm-config.yaml ..."
  if grep -q '^default_model:' llm-config.yaml; then
    sed -i "s/^default_model:.*/default_model: ollama-${OLLAMA_MODEL}/" llm-config.yaml
  else
    sed -i "1s;^;default_model: ollama-${OLLAMA_MODEL}\n;" llm-config.yaml
  fi
else
  say "Creating minimal llm-config.yaml ..."
  cat > llm-config.yaml <<EOF
default_model: ollama-${OLLAMA_MODEL}
models:
  - model_name: ollama-${OLLAMA_MODEL}
    model: "ollama/${OLLAMA_MODEL}"
EOF
fi
sed -n '1,20p' llm-config.yaml || true

say "Writing docker-compose.yml ..."
cat > docker-compose.yml <<EOF
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "${OLLAMA_PORT}:11434"
    volumes:
      - ollama-data:/root/.ollama
    healthcheck:
      test: ["CMD", "ollama", "ps"]
      interval: 10s
      timeout: 5s
      retries: 12

  dvla:
    build: .
    container_name: dvla
    environment:
      MODEL_BACKEND: ollama
      MODEL_NAME: ${OLLAMA_MODEL}
      OLLAMA_HOST: http://ollama:11434
      OLLAMA_BASE_URL: http://ollama:11434
      OLLAMA_API_BASE: http://ollama:11434
      LITELLM_OLLAMA_BASE_URL: http://ollama:11434
      LITELLM_OLLAMA_API_BASE: http://ollama:11434
      LITELLM_LOG: DEBUG
      LITELLM_DEBUG: "True"
    depends_on:
      ollama:
        condition: service_healthy
    ports:
      - "${DVLA_PORT}:8501"

volumes:
  ollama-data:
EOF

_docker compose config >/dev/null
say "Compose file validated."

say "Starting Ollama ..."
_docker compose up -d ollama

say "Waiting for Ollama API on http://localhost:${OLLAMA_PORT} ..."
MAX_WAIT=240; ELAPSED=0
until curl -fsS "http://localhost:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1; do
  sleep 3; ELAPSED=$((ELAPSED+3))
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    err "Ollama did not become ready in ${MAX_WAIT}s. Check: docker logs ollama"
    exit 1
  fi
done
say "Ollama is online."

say "Pulling model: ${OLLAMA_MODEL} (this may take a while)..."
_docker exec ollama ollama pull "${OLLAMA_MODEL}" || true
say "Available models:"
_docker exec ollama ollama list || true

say "Building & starting DVLA ..."
_docker compose up -d --build dvla

say "Waiting for DVLA web UI on http://localhost:${DVLA_PORT} ..."
MAX_WAIT=180; ELAPSED=0
until curl -fsS "http://localhost:${DVLA_PORT}" >/dev/null 2>&1; do
  sleep 3; ELAPSED=$((ELAPSED+3))
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    warn "DVLA not reachable yet. Check: docker logs -f dvla"
    break
  fi
done

echo
say "Setup complete!"
echo "  Ollama API : http://localhost:${OLLAMA_PORT}"
echo "  DVLA UI    : http://localhost:${DVLA_PORT}"
echo
echo "Health Check:"
echo "  $ docker $(groups "$USER" | grep -q docker && echo "" || echo "sudo ")exec ollama ollama run ${OLLAMA_MODEL} 'Say ready in one word.'"
echo "  $ docker $(groups "$USER" | grep -q docker && echo "" || echo "sudo ")logs -f dvla"
echo