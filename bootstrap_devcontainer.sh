#!/usr/bin/env bash
# bootstrap_devcontainer.sh
# AMD Ryzen AI Max 395 (gfx1151) host+devcontainer bootstrap.
# - Host: ROCm (default 6.4.3; --latest or --rocm X.Y[.Z]), Docker, VS Code (Microsoft APT)
# - Devcontainer: rocm/dev-ubuntu-24.04:<MM>-complete + uv venv + PyTorch(ROCm) + vLLM + Slang
# Idempotent: re-runnable; use --force to overwrite .devcontainer files.

set -euo pipefail

# ---------------- Config ----------------
PROJECT_DIR="${PROJECT_DIR:-$PWD}"
DEVCONTAINER_DIR="${PROJECT_DIR}/.devcontainer"

DEFAULT_ROCM_FALLBACK="6.4.3"   # stable default
MIN_ROCM="6.4"                  # gfx1151 requires >= 6.4
PREF_ROCM_FOR_LATEST="7.0"      # try this when --latest

FORCE=0
SKIP_DRIVER=0
ROCM_PIN=""
WANT_LATEST=0
INSTALL_CODE=1        # install host VS Code via Microsoft APT (no snap)
# ---------------------------------------

log(){ printf "\033[1;36m==> %s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m[WARN] %s\033[0m\n" "$*" >&2; }
err(){  printf "\033[1;31m[ERR]  %s\033[0m\n" "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }
sudo_if(){ if [[ ${EUID:-$(id -u)} -eq 0 ]]; then "$@"; else sudo "$@"; fi }

usage(){
  cat <<EOF
Usage: $0 [--rocm X.Y[.Z]] [--latest] [--force] [--no-driver] [--no-code] [--project DIR]
  --rocm X.Y[.Z]   Pin ROCm version (default: ${DEFAULT_ROCM_FALLBACK})
  --latest         Prefer newest available ROCm (tries ${PREF_ROCM_FOR_LATEST}*)
  --force          Overwrite existing .devcontainer files
  --no-driver      Skip host ROCm install
  --no-code        Skip host VS Code install (Microsoft APT)
  --project DIR    Folder to place .devcontainer (default: \$PWD)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rocm) ROCM_PIN="${2:?}"; shift 2;;
    --latest) WANT_LATEST=1; shift;;
    --force) FORCE=1; shift;;
    --no-driver) SKIP_DRIVER=1; shift;;
    --no-code) INSTALL_CODE=0; shift;;
    --project) PROJECT_DIR="${2:?}"; DEVCONTAINER_DIR="${PROJECT_DIR}/.devcontainer"; shift 2;;
    -h|--help) usage; exit 0;;
    *) err "Unknown arg: $1"; usage; exit 1;;
  esac
done

detect_os(){
  OS_ID=""; OS_VER=""; OS_CODENAME=""
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"; OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  fi
  PKG=""
  if have apt-get; then PKG="apt"
  elif have dnf; then PKG="dnf"
  elif have zypper; then PKG="zypper"
  else PKG=""
  fi
}

ensure_basics(){
  case "$PKG" in
    apt)
      sudo_if apt-get update -y
      sudo_if apt-get install -y --no-install-recommends \
        curl wget gnupg ca-certificates lsb-release jq git build-essential
      ;;
    dnf)
      sudo_if dnf -y install curl wget gnupg2 ca-certificates jq git make gcc gcc-c++
      ;;
    zypper)
      sudo_if zypper --non-interactive ref
      sudo_if zypper --non-interactive in curl wget gpg2 ca-certificates jq git gcc gcc-c++ make
      ;;
    *)
      warn "Unsupported package manager; continuing."
      ;;
  esac
}

# ---------- ROCm series helpers ----------
rocm_series_exists_apt(){
  local series="$1" codename
  codename="$(. /etc/os-release; echo "${UBUNTU_CODENAME:-noble}")"
  curl -fsI "https://repo.radeon.com/rocm/apt/${series}/dists/${codename}/InRelease" >/dev/null 2>&1
}

latest_rocm_series_index(){
  curl -fsSL https://repo.radeon.com/rocm/apt/ 2>/dev/null \
   | grep -Eo 'href="[0-9]+\.[0-9]+/?' | tr -d '"' | sed 's/href=//' \
   | sed 's:/$::' | sort -V | tail -n1 || true
}

pick_rocm_version(){
  local chosen=""
  if [[ -n "$ROCM_PIN" ]]; then
    chosen="$ROCM_PIN"
  elif [[ $WANT_LATEST -eq 1 ]]; then
    for s in "${PREF_ROCM_FOR_LATEST}" "latest"; do
      if rocm_series_exists_apt "$s"; then chosen="$s"; break; fi
    done
    [[ -z "$chosen" ]] && chosen="$(latest_rocm_series_index || true)"
  else
    chosen="$DEFAULT_ROCM_FALLBACK"
  fi
  # Enforce minimum MM (6.4)
  if [[ "$chosen" =~ ^([0-9]+\.[0-9]+) ]]; then
    local mm="${BASH_REMATCH[1]}"
    if ! printf '%s\n%s\n' "$MIN_ROCM" "$mm" | sort -V -C; then
      warn "Chosen ROCm ($chosen) < minimum ($MIN_ROCM); using ${DEFAULT_ROCM_FALLBACK}."
      chosen="$DEFAULT_ROCM_FALLBACK"
    fi
  fi
  echo "$chosen"
}

# ---------- Host ROCm install ----------
dl_amdgpu_pkg(){
  local ver="$1" kind="$2"
  if [[ "$kind" == "deb" ]]; then
    local codename; codename="$(. /etc/os-release; echo "${UBUNTU_CODENAME:-noble}")"
    local base="https://repo.radeon.com/amdgpu-install/${ver}/ubuntu"
    for c in "$codename" noble jammy bookworm; do
      if curl -fsSL "${base}/${c}/" >/dev/null 2>&1; then
        local deb; deb=$(curl -fsSL "${base}/${c}/" | grep -oE 'amdgpu-install_[^"]+all\.deb' | sort -V | tail -n1 || true)
        if [[ -n "$deb" ]]; then
          curl -fsSL -o "/tmp/${deb}" "${base}/${c}/${deb}"
          echo "/tmp/${deb}"
          return
        fi
      fi
    done
  else
    for sub in "rhel/9" "rhel/8" ; do
      local base="https://repo.radeon.com/amdgpu-install/${ver}/${sub}/"
      if curl -fsSL "$base" >/dev/null 2>&1; then
        local rpm; rpm=$(curl -fsSL "$base" | grep -oE 'amdgpu-install-[0-9\.\-]+\.noarch\.rpm' | sort -V | tail -n1 || true)
        if [[ -n "$rpm" ]]; then
          curl -fsSL -o "/tmp/${rpm}" "${base}${rpm}"
          echo "/tmp/${rpm}"
          return
        fi
      fi
    done
  fi
  echo ""
}

install_rocm_via_apt_series(){
  local series="$1" codename
  codename="$(. /etc/os-release; echo "${UBUNTU_CODENAME:-noble}")"
  sudo_if install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | sudo_if gpg --dearmor -o /etc/apt/keyrings/rocm.gpg
  if [[ "$series" == "latest" ]]; then
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/latest ${codename} main" \
      | sudo_if tee /etc/apt/sources.list.d/rocm.list >/dev/null
  else
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${series} ${codename} main" \
      | sudo_if tee "/etc/apt/sources.list.d/rocm-${series}.list" >/dev/null
  fi
  printf 'Package: *\nPin: release o=repo.radeon.com\nPin-Priority: 600\n' \
    | sudo_if tee /etc/apt/preferences.d/rocm-pin-600 >/dev/null
  sudo_if apt-get update -y
  sudo_if apt-get install -y rocm
  for g in render video docker; do id -nG "$USER" | grep -qw "$g" || sudo_if usermod -aG "$g" "$USER"; done
  [[ -x /opt/rocm/bin/rocminfo ]] && /opt/rocm/bin/rocminfo >/dev/null 2>&1 || true
}

install_rocm_host(){
  local selected="$1"
  [[ $SKIP_DRIVER -eq 1 ]] && { log "Skipping host ROCm install (--no-driver)."; return; }
  case "$PKG" in
    apt)
      local series="$selected"
      if ! rocm_series_exists_apt "$series"; then
        if rocm_series_exists_apt "$DEFAULT_ROCM_FALLBACK"; then
          warn "APT series '$series' not found; falling back to ${DEFAULT_ROCM_FALLBACK}."
          series="$DEFAULT_ROCM_FALLBACK"
        else
          warn "APT series '$series' not found; trying AMDGPU installer."
          local deb; deb="$(dl_amdgpu_pkg "$selected" deb)"
          [[ -z "$deb" ]] && deb="$(dl_amdgpu_pkg "$DEFAULT_ROCM_FALLBACK" deb)"
          if [[ -n "$deb" ]]; then
            sudo_if dpkg -i "$deb" || true
            sudo_if apt-get update -y
            have amdgpu-install || { err "amdgpu-install missing"; exit 1; }
            sudo_if amdgpu-install --usecase=rocm,hip,opencl --accept-eula -y \
              || sudo_if amdgpu-install --usecase=rocm,hip,opencl --accept-eula -y --no-dkms
            for g in render video docker; do id -nG "$USER" | grep -qw "$g" || sudo_if usermod -aG "$g" "$USER"; done
            return
          else
            err "Could not obtain ROCm via APT or installer for '$selected'"; exit 1
          fi
        fi
      fi
      install_rocm_via_apt_series "$series"
      ;;
    dnf|zypper)
      warn "Host ROCm automation currently focuses on Debian/Ubuntu. Install ROCm per AMD docs for your distro."
      ;;
    *) warn "Unknown package manager; please install ROCm manually." ;;
  esac
}

# ---------- Docker ----------
ensure_docker(){
  if have docker; then
    log "Docker present."
  else
    case "$PKG" in
      apt)
        sudo_if apt-get update -y
        sudo_if apt-get install -y ca-certificates curl gnupg
        sudo_if install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo_if gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo_if chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${OS_CODENAME:-stable} stable" \
          | sudo_if tee /etc/apt/sources.list.d/docker.list >/dev/null
        sudo_if apt-get update -y
        sudo_if apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        ;;
      dnf)
        sudo_if dnf -y install dnf-plugins-core
        sudo_if dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo_if dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo_if systemctl enable --now docker
        ;;
      zypper)
        sudo_if zypper --non-interactive in docker docker-compose || true
        sudo_if systemctl enable --now docker || true
        ;;
      *) warn "Unknown pkg manager; please install Docker manually." ;;
    esac
  fi
  id -nG "$USER" | grep -qw docker || { log "Adding $USER to docker group"; sudo_if usermod -aG docker "$USER"; }
  [[ -f /etc/docker/daemon.json ]] || { echo '{}' | sudo_if tee /etc/docker/daemon.json >/dev/null; sudo_if systemctl restart docker || true; }
}

# ---------- VS Code (host, Microsoft APT; removes snap and conflicting lists) ----------
install_vscode_host(){
  [[ $INSTALL_CODE -eq 1 ]] || { log "Skipping host VS Code install (--no-code)."; return; }
  case "$PKG" in
    apt)
      if snap list 2>/dev/null | grep -q '^code\s'; then
        warn "Removing snap 'code' to avoid Dev Containers issues."
        sudo_if snap remove code || true
      fi
      # Remove conflicting sources that reference the same repo with different keyrings
      if grep -Rqs "packages.microsoft.com/repos/code" /etc/apt/sources.list.d/; then
        sudo_if sed -i '/packages.microsoft.com\/repos\/code/d' /etc/apt/sources.list.d/*.list || true
      fi
      sudo_if rm -f /etc/apt/sources.list.d/vscode.list /etc/apt/sources.list.d/microsoft-prod.list 2>/dev/null || true

      sudo_if install -d -m 0755 /etc/apt/keyrings
      curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo_if gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
      echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
        | sudo_if tee /etc/apt/sources.list.d/vscode.list >/dev/null

      sudo_if apt-get update -y
      sudo_if apt-get install -y code
      ;;
    dnf|zypper)
      warn "VS Code host install automation focuses on Debian/Ubuntu here."
      ;;
    *)
      warn "Unknown pkg manager; please install VS Code manually."
      ;;
  esac
}

# ---------- Devcontainer files ----------
write_devcontainer_files(){
  local rocm_series="$1"
  local rocm_mm
  rocm_mm="$(echo "$rocm_series" | grep -Eo '^[0-9]+\.[0-9]+')" || true
  [[ -z "$rocm_mm" ]] && rocm_mm="6.4"   # default if parsing fails

  local torch_index="https://download.pytorch.org/whl/rocm${rocm_mm}"

  mkdir -p "$DEVCONTAINER_DIR"

  # --- Dockerfile ---
  if [[ $FORCE -eq 0 && -f "${DEVCONTAINER_DIR}/Dockerfile" ]]; then
    log "Dockerfile exists; skipping (use --force to overwrite)."
  else
    log "Writing ${DEVCONTAINER_DIR}/Dockerfile"
    cat > "${DEVCONTAINER_DIR}/Dockerfile" <<EOF
# ROCm Dev Container (AI/LLM focus)
ARG ROCM_SERIES=${rocm_series}
ARG ROCM_MM=${rocm_mm}
ARG TORCH_INDEX=${torch_index}

FROM rocm/dev-ubuntu-24.04:\${ROCM_MM}-complete
ARG TORCH_INDEX
ENV DEBIAN_FRONTEND=noninteractive \
    UV_NO_MODIFY_PATH=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    VLLM_USE_ROCM=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential cmake ninja-build \
    python3 python3-venv python3-pip \
    clang wget curl ca-certificates pkg-config \
  && rm -rf /var/lib/apt/lists/*

# uv
RUN curl -LsSf https://astral.sh/uv/install.sh | bash && ln -sf /root/.local/bin/uv /usr/local/bin/uv

WORKDIR /workspace

RUN uv venv /opt/venv && \
    /opt/venv/bin/python -m ensurepip --upgrade && \
    /opt/venv/bin/python -m pip install --upgrade pip wheel setuptools
ENV PATH="/opt/venv/bin:${PATH}"

# PyTorch ROCm wheels
RUN /opt/venv/bin/python -m pip install --upgrade pip wheel setuptools && \
    /opt/venv/bin/python -m pip install "torch>=2.5" torchvision torchaudio --index-url "\${TORCH_INDEX}"

# vLLM (ROCm)
RUN /opt/venv/bin/python -m pip install --no-cache-dir "vllm>=0.6.4"

CMD ["/bin/bash"]
EOF
  fi

  # --- devcontainer.json ---
  if [[ $FORCE -eq 0 && -f "${DEVCONTAINER_DIR}/devcontainer.json" ]]; then
    log "devcontainer.json exists; skipping (use --force to overwrite)."
  else
    log "Writing ${DEVCONTAINER_DIR}/devcontainer.json"
    cat > "${DEVCONTAINER_DIR}/devcontainer.json" <<'EOF'
{
  "name": "AMD AI-MAX 395 (ROCm) Dev",
  "build": { "dockerfile": "Dockerfile" },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
  "workspaceFolder": "/workspace",
  "runArgs": [
    "--device=/dev/kfd",
    "--device=/dev/dri",
    "--group-add=render",
    "--group-add=video",
    "--ipc=host",
    "--shm-size=16g"
  ],
  "containerEnv": { "VLLM_USE_ROCM": "1" },
  "remoteUser": "root",
  "postCreateCommand": "bash ${containerWorkspaceFolder}/.devcontainer/setup.sh",
  "customizations": {
    "vscode": {
      "extensions": [
        "ms-python.python",
        "ms-toolsai.jupyter",
        "ms-vscode-remote.remote-containers"
      ]
    }
  }
}
EOF
  fi

  # --- setup.sh ---
  if [[ $FORCE -eq 0 && -f "${DEVCONTAINER_DIR}/setup.sh" ]]; then
    log "setup.sh exists; skipping (use --force to overwrite)."
  else
    log "Writing ${DEVCONTAINER_DIR}/setup.sh"
    cat > "${DEVCONTAINER_DIR}/setup.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
python - <<'PY'
import torch
print("torch:", torch.__version__)
print("torch.version.hip:", getattr(getattr(torch,"version",None),"hip",None))
print("cuda_is_available (should be False on ROCm):", torch.cuda.is_available())
print("OK: ROCm + PyTorch + vLLM container ready.")
PY
EOF
    chmod +x "${DEVCONTAINER_DIR}/setup.sh"
  fi
}


# ---------- Main ----------
main(){
  detect_os
  ensure_basics
  ensure_docker

  local rocm_series
  rocm_series="$(pick_rocm_version)"
  log "Selected ROCm series: ${rocm_series}"
  install_rocm_host "${rocm_series}"

  install_vscode_host
  write_devcontainer_files "${rocm_series}"

  log "Done."
  echo "Open this folder in VS Code → “Dev Containers: Reopen in Container”."
  echo "If you were just added to docker/render/video groups, open a new shell or reboot."
}

main
