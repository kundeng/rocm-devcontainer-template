# ROCm Devcontainer Template

This repository provides a ready-to-use [Dev Container](https://containers.dev/) setup for AMD ROCm development.

It is designed for AMD Ryzen AI / ROCm >= 6.4 environments and supports both:
- VS Code Dev Containers
- `devcontainer` CLI (no VS Code required)

## What's included
- ROCm base: `rocm/dev-ubuntu-24.04:<MM>-complete` (e.g. 6.4)
- Python 3 with [uv](https://github.com/astral-sh/uv) for fast virtualenv/package management
- PyTorch(ROCm) + torchvision + torchaudio
- [vLLM](https://github.com/vllm-project/vllm)
- `.devcontainer/setup.sh` sanity check

## Quick start

Ensure your host has:
- ROCm kernel drivers and device nodes available (e.g. `/dev/kfd`, `/dev/dri/*`)
- Docker
- Optional: VS Code + Dev Containers extension, or `devcontainer` CLI

Then bootstrap:
```bash
# Container-only: overwrite .devcontainer files (no host changes)
./bootstrap_devcontainer.sh --mode container

# Host ensure + container: install basics, docker, ensure drivers if missing, write .devcontainer
./bootstrap_devcontainer.sh --mode all
```

Open in VS Code and "Dev Containers: Reopen in Container" or use the CLI:
```bash
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash -lc 'python -c "import torch; print(torch.__version__)"'
```

## Script flags (simplified)

```text
--mode [all|host|container]      Scope: run host+container (all), host-only, or container-only (default: all)
--rocm_version [auto|latest|X.Y] ROCm series selection (default: auto; min enforced: 6.4)
--host_rocm [drivers|full|none]  Host ROCm target: drivers only (default), full userland, or none
--no_vscode                      Skip installing VS Code on the host
--workspace DIR                  Where to place .devcontainer (default: $PWD)
--reinstall                      Force reinstall drivers/ROCm even if present
```

Behavior is idempotent by default:
- Drivers: attempted only if missing (unless `--reinstall`).
- ROCm userland: install if missing or series mismatch; skip if matching (unless `--reinstall`).

## Passwordless sudo inside the devcontainer

The generated Dockerfile ensures the container user can use passwordless sudo:
- Installs `sudo` and adds the user to `sudo` group.
- Adds `%sudo ALL=(ALL) NOPASSWD:ALL` and an explicit user rule.

Use `sudo -n true` or `sudo su -` in the container; both should work without a password.

## GPU device access and groups

Access to `/dev/kfd` and `/dev/dri/*` requires the container user to be in the same group IDs as on the host. The script:
- Detects host `render` and `video` GIDs when possible, and
- Emits `--group-add=<GID>` in `devcontainer.json` runArgs. If detection fails, it falls back to `--group-add=render` and `--group-add=video`.

This avoids hardcoding group names in the Dockerfile and keeps the mapping by numeric GID, which is what matters for permissions.

## Pick a ROCm series

`--rocm_version auto` uses a sane default (currently 6.4.3) and enforces minimum `6.4`.
`--rocm_version latest` prefers the configured latest series.
`--rocm_version X.Y` pins to a series (e.g., `6.4`).

## Examples

```bash
# Use latest ROCm series, ensure full host ROCm, and write .devcontainer
./bootstrap_devcontainer.sh --mode all --rocm_version latest --host_rocm full

# Force reinstall drivers and ROCm userland
./bootstrap_devcontainer.sh --mode host --host_rocm full --reinstall

# Write devcontainer files into a different project directory
./bootstrap_devcontainer.sh --mode container --workspace /path/to/project
```

## Notes

- If kernel modules are updated during driver install, a reboot may be required.
- After being added to `docker/render/video` groups on the host, open a new shell for group membership to take effect.
