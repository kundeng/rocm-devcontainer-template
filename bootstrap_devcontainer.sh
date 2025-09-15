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
# By default, ensure kernel drivers/device nodes and group membership are handled.
# The script will attempt to install kernel drivers by default when missing.
# Full ROCm userland on the host is opt-in via --install-host-rocm.
INSTALL_DRIVERS=1
INSTALL_HOST_ROCM=0
ROCM_PIN=""
WANT_LATEST=0
INSTALL_CODE=1        # install host VS Code via Microsoft APT (no snap)
DEVCONTAINER_ONLY=0  # when set, only write .devcontainer files and skip host changes
# ---------------------------------------

log(){ printf "\033[1;36m==> %s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m[WARN] %s\033[0m\n" "$*" >&2; }
err(){  printf "\033[1;31m[ERR]  %s\033[0m\n" "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }
sudo_if(){ if [[ ${EUID:-$(id -u)} -eq 0 ]]; then "$@"; else sudo "$@"; fi }

usage(){
  cat <<EOF
Usage: $0 [options]

Options:
  --rocm X.Y[.Z]       Pin ROCm version (default: ${DEFAULT_ROCM_FALLBACK})
  --latest             Use the latest available ROCm series
  --force              Overwrite any existing .devcontainer files
  --devcontainer-only  Only write .devcontainer files; skip host package/driver changes
  --install-host-rocm  Install full ROCm userland on the host (opt-in)
  --no-install-drivers Do not attempt to install kernel GPU drivers (default: install if missing)
  --no-code            Skip installing VS Code on the host
  --project DIR        Folder to place .devcontainer (default: \$PWD)
  -h, --help           Show this help and exit

Examples:
  $0                     # generate .devcontainer using defaults
  $0 --force --rocm 6.4  # regenerate for ROCm 6.4 and overwrite files
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --rocm) ROCM_PIN="${2:?}"; shift 2;;
  --latest) WANT_LATEST=1; shift;;
  --force) FORCE=1; shift;;
  --devcontainer-only) DEVCONTAINER_ONLY=1; shift;;
  --install-host-rocm) INSTALL_HOST_ROCM=1; shift;;
  --no-install-drivers) INSTALL_DRIVERS=0; shift;;
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

# Normalize Microsoft apt source files to avoid conflicting Signed-By values.
sanitize_microsoft_sources(){
  # Normalize in-place any Signed-By entries that reference Microsoft packages so
  # adding the canonical keyring later does not conflict. This edits files under
  # /etc/apt/sources.list.d/ in-place and is less invasive than removing files.
  for f in /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -q "packages.microsoft.com" "$f" 2>/dev/null; then
      sudo_if sed -i 's@Signed-By=[^ ]*@Signed-By=/etc/apt/keyrings/microsoft.gpg@g' "$f" || true
    fi
  done
}

ensure_basics(){
  case "$PKG" in
    apt)
      # Normalize any existing Microsoft apt source Signed-By entries to avoid
      # "Conflicting values set for option Signed-By" errors when adding keys.
      sanitize_microsoft_sources || true
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
  curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | sudo_if gpg --batch --yes --dearmor -o /etc/apt/keyrings/rocm.gpg
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
  # Note: this function can perform a full ROCm userland install. Driver-only installs
  # are handled by `install_drivers_only()` which calls into the same helpers where possible.
  # If ROCm already appears installed in /opt/rocm and rocminfo runs, skip installation.
  if [[ -x "/opt/rocm/bin/rocminfo" ]]; then
    set +e
    /opt/rocm/bin/rocminfo >/dev/null 2>&1
    local rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      log "ROCm appears installed on host (/opt/rocm); skipping host install."
      return
    else
      warn "Found /opt/rocm/bin/rocminfo but it failed to run; proceeding with install."
    fi
  fi
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

# Attempt to install only kernel drivers/device nodes (without full ROCm userland).
install_drivers_only(){
  local series="$1"
  case "$PKG" in
    apt)
      log "Attempting to install kernel drivers (amdgpu/kfd) via AMD packages."
      # Try the lightweight amdgpu-install path if available
      local deb; deb="$(dl_amdgpu_pkg "$series" deb || true)"
      if [[ -n "$deb" ]]; then
        sudo_if dpkg -i "$deb" || true
        sudo_if apt-get update -y
        if have amdgpu-install; then
          sudo_if amdgpu-install --usecase=hip,opencl --accept-eula -y || true
          for g in render video docker; do id -nG "$USER" | grep -qw "$g" || sudo_if usermod -aG "$g" "$USER"; done
          log "Driver install attempted; please reboot if kernel modules were updated."
          return
        fi
      fi
      warn "Driver installer not available; please follow AMD docs to install kernel drivers for your distro."
      ;;
    *) warn "Driver install automated steps focus on Debian/Ubuntu. Install drivers per AMD docs for your distro." ;;
  esac
}

# Ensure kernel drivers/device nodes exist and add user to required groups.
ensure_host_drivers(){
  # Check kernel modules
  if lsmod | grep -q -E 'amdgpu|kfd|amdkfd'; then
    log "Kernel modules present: amdgpu/kfd"
  else
    warn "Kernel GPU drivers appear missing (amdgpu/kfd)."
    if [[ ${INSTALL_DRIVERS:-1} -eq 1 ]]; then
      log "Attempting to install drivers (use --no-install-drivers to opt out)."
      install_drivers_only "$1"
    else
      warn "Driver installation skipped (use --install-host-rocm or omit --no-install-drivers)."
    fi
  fi

  # Check device nodes
  if [[ -e /dev/kfd ]] || ls /dev/dri/* >/dev/null 2>&1; then
    log "GPU device nodes present."
  else
    warn "GPU device nodes (/dev/kfd or /dev/dri/*) not found. Containers won't see the GPU until drivers are installed and devices appear."
  fi

  # Ensure group membership
  for g in render video docker; do
    if id -nG "$USER" | grep -qw "$g"; then
      log "User is already in group $g"
    else
      log "Adding $USER to group $g"
      sudo_if usermod -aG "$g" "$USER" || warn "Failed to add $USER to $g; please add manually."
    fi
  done
}

# ---------- Docker ----------
ensure_docker(){
  if have docker; then
    log "Docker present."
  else
    case "$PKG" in
      apt)
        # Normalize any existing Microsoft apt source Signed-By entries first
        sanitize_microsoft_sources || true
        sudo_if apt-get update -y
        sudo_if apt-get install -y ca-certificates curl gnupg
        sudo_if install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo_if gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
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
      # Remove or normalize any existing Microsoft apt sources to prevent Signed-By conflicts
      sanitize_microsoft_sources || true
      sudo_if rm -f /etc/apt/sources.list.d/vscode.list /etc/apt/sources.list.d/microsoft-prod.list 2>/dev/null || true

      sudo_if install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo_if gpg --batch --yes --dearmor -o /etc/apt/keyrings/microsoft.gpg
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
  local host_uid="${2:-1000}"
  local host_gid="${3:-1000}"
  # overwrite controlled by global FORCE (pass --force on CLI)
  local rocm_mm
  rocm_mm="$(echo "$rocm_series" | grep -Eo '^[0-9]+\.[0-9]+')" || true
  [[ -z "$rocm_mm" ]] && rocm_mm="6.4"   # default if parsing fails

  local torch_index="https://download.pytorch.org/whl/rocm${rocm_mm}"

  mkdir -p "$DEVCONTAINER_DIR"

  # Detect if the base image already contains a user with host UID.
  local base_image="rocm/dev-ubuntu-24.04:${rocm_mm}-complete"
  local existing_user=""
  if have docker; then
    # Try to query /etc/passwd in the base image for the UID. If docker cannot pull it, ignore.
    set +e
    local out
    out=$(docker run --rm --entrypoint sh "${base_image}" -c "getent passwd ${host_uid} || true" 2>/dev/null || true)
    set -e
    if [[ -n "${out// }" ]]; then
      existing_user=$(echo "${out}" | head -n1 | cut -d: -f1)
      log "Base image already has UID ${host_uid} as user '${existing_user}' — will reuse it."
    else
      log "No existing user with UID ${host_uid} in base image; will create 'devuser'."
    fi
  else
    warn "Docker not available to inspect base image; defaulting to create 'devuser'."
  fi

  # Detect host render/video group IDs (used by /dev/kfd and /dev/dri)
  local render_gid=""
  local video_gid=""
  if getent group render >/dev/null 2>&1; then
    render_gid=$(getent group render | cut -d: -f3)
  fi
  if getent group video >/dev/null 2>&1; then
    video_gid=$(getent group video | cut -d: -f3)
  fi
  # Fallback: stat device nodes
  if [[ -z "$render_gid" && -e /dev/kfd ]]; then
    render_gid=$(stat -c '%g' /dev/kfd || true)
  fi
  if [[ -z "$video_gid" && -e /dev/dri/card0 ]]; then
    video_gid=$(stat -c '%g' /dev/dri/card0 || true)
  fi

  # --- Dockerfile ---
  if [[ $FORCE -eq 0 && -f "${DEVCONTAINER_DIR}/Dockerfile" ]]; then
    log "Dockerfile exists; skipping (use --force to overwrite)."
  else
    log "Writing ${DEVCONTAINER_DIR}/Dockerfile"
    if [[ -n "${existing_user}" ]]; then
      # Base image already has the UID — reuse that user; do not create devuser
  cat > "${DEVCONTAINER_DIR}/Dockerfile" <<EOF
# ROCm Dev Container (AI/LLM focus)
ARG ROCM_SERIES=${rocm_series}
ARG ROCM_MM=${rocm_mm}
ARG TORCH_INDEX=${torch_index}
ARG USER_UID=1000
ARG USER_GID=1000

FROM rocm/dev-ubuntu-24.04:\${ROCM_MM}-complete
ARG TORCH_INDEX
ARG USER_UID
ARG USER_GID
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
ENV PATH="/opt/venv/bin:\${PATH}"

# PyTorch ROCm wheels
RUN /opt/venv/bin/python -m pip install --upgrade pip wheel setuptools && \
    /opt/venv/bin/python -m pip install "torch>=2.5" torchvision torchaudio --index-url "\${TORCH_INDEX}"

# vLLM (ROCm)
RUN /opt/venv/bin/python -m pip install --no-cache-dir "vllm>=0.6.4"
# Ensure a group exists with the host GID and add the existing user to it
RUN groupadd --gid \${USER_GID} hostgroup || true \
 && usermod -aG hostgroup ${existing_user} || true

# Create render/video groups (if detected on host) and add the existing user to them
RUN if [ -n "${render_gid}" ]; then groupadd --gid ${render_gid} host_render || true && usermod -aG host_render ${existing_user} || true; fi \
 && if [ -n "${video_gid}" ]; then groupadd --gid ${video_gid} host_video || true && usermod -aG host_video ${existing_user} || true; fi

# Ensure the existing user can run sudo without a password (makes terminals usable)
RUN apt-get update -y && apt-get install -y sudo || true \
 && { echo "${existing_user} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-${existing_user} && chmod 0440 /etc/sudoers.d/99-${existing_user}; } || true

USER ${existing_user}
WORKDIR /workspace
CMD ["/bin/bash"]
EOF
    else
      # No existing user — create devuser matching host UID/GID
      cat > "${DEVCONTAINER_DIR}/Dockerfile" <<EOF
# ROCm Dev Container (AI/LLM focus)
ARG ROCM_SERIES=${rocm_series}
ARG ROCM_MM=${rocm_mm}
ARG TORCH_INDEX=${torch_index}
ARG USER_UID=1000
ARG USER_GID=1000

FROM rocm/dev-ubuntu-24.04:\${ROCM_MM}-complete
ARG TORCH_INDEX
ARG USER_UID
ARG USER_GID
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

# Create a non-root user that matches the host UID/GID so mounted volumes are writable
RUN groupadd --gid \${USER_GID} devuser \
 && useradd --uid \${USER_UID} --gid \${USER_GID} -m devuser \
 && apt-get update && apt-get install -y sudo \
 && echo 'devuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/devuser \
 && chmod 0440 /etc/sudoers.d/devuser

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

USER devuser
WORKDIR /workspace
CMD ["/bin/bash"]
EOF
    fi
  fi

  # --- devcontainer.json ---
  if [[ $FORCE -eq 0 && -f "${DEVCONTAINER_DIR}/devcontainer.json" ]]; then
    log "devcontainer.json exists; skipping (use --force to overwrite)."
  else
    log "Writing ${DEVCONTAINER_DIR}/devcontainer.json"
    # If we detected an existing user in the base image, use it; otherwise default to 'devuser'
    local remote_user
    remote_user="${existing_user:-devuser}"
  cat > "${DEVCONTAINER_DIR}/devcontainer.json" <<EOF
{
  "name": "AMD AI-MAX 395 (ROCm) Dev",
  "build": { "dockerfile": "Dockerfile", "args": { "USER_UID": ${host_uid}, "USER_GID": ${host_gid} } },
  "workspaceMount": "source=\${localWorkspaceFolder},target=/workspace,type=bind,consistency=cached",
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
  "remoteUser": "${remote_user}",
  "postCreateCommand": "bash \${containerWorkspaceFolder}/.devcontainer/setup.sh",
  "overrideCommand": true,
  "customizations": {
    "vscode": {
      "settings": {
        "terminal.integrated.shell.linux": "/bin/bash",
        "terminal.integrated.defaultProfile.linux": "bash"
      },
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
  if [[ ${DEVCONTAINER_ONLY:-0} -eq 0 ]]; then
    ensure_basics
    ensure_docker
  else
    log "DEVCONTAINER_ONLY=1; skipping host package/driver/Docker operations."
  fi

  local rocm_series
  rocm_series="$(pick_rocm_version)"
  log "Selected ROCm series: ${rocm_series}"
  # Ensure kernel drivers/device nodes/groups are present (non-invasive). Attempt to install drivers by default when missing.
  if [[ ${DEVCONTAINER_ONLY:-0} -eq 0 ]]; then
    ensure_host_drivers "${rocm_series}"
    if [[ ${INSTALL_HOST_ROCM:-0} -eq 1 ]]; then
      log "Full host ROCm install requested; attempting install."
      install_rocm_host "${rocm_series}"
    else
      log "Full host ROCm userland install skipped (use --install-host-rocm to opt in)."
    fi
  else
    log "DEVCONTAINER_ONLY=1; skipping host driver/ROCm install checks."
  fi

  if [[ ${DEVCONTAINER_ONLY:-0} -eq 0 ]]; then
    install_vscode_host
  else
    log "DEVCONTAINER_ONLY=1; skipping VS Code host install."
  fi
  # Detect host UID/GID to map container user to the host user for writable mounts
  HOST_UID=$(id -u)
  HOST_GID=$(id -g)
  log "Using host UID:GID = ${HOST_UID}:${HOST_GID} for container user mapping"
  # Generate devcontainer files; pass host UID/GID. Use --force to overwrite.
  write_devcontainer_files "${rocm_series}" "${HOST_UID}" "${HOST_GID}"

  log "Done."
  echo "Open this folder in VS Code → “Dev Containers: Reopen in Container”."
  echo "If you were just added to docker/render/video groups, open a new shell or reboot."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
