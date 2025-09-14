# ROCm Devcontainer Template

This repository provides a ready-to-use [Dev Container](https://containers.dev/) setup for AMD ROCm development.  
It is designed for **AMD Ryzen AI / ROCm >= 6.4** environments and supports both:

- **VS Code Remote - Containers**
- **`devcontainer` CLI** (no VS Code required)

## Features
- ROCm runtime (host GPU drivers required)
- Python 3 with [uv](https://github.com/astral-sh/uv) for fast virtualenv/package management
- Preinstalled: PyTorch (ROCm wheels), torchvision, torchaudio
- Preinstalled: [vLLM](https://github.com/vllm-project/vllm) for accelerated inference
- Example `setup.sh` script for quick verification

## Usage

### 1. Install prerequisites on host
- ROCm drivers (>= 6.4) — must be installed on the host OS.
- Docker + [devcontainer CLI](https://github.com/devcontainers/cli) (or VS Code with *Dev Containers* extension).

### 2. Clone this template
```bash
git clone https://github.com/<your-org>/rocm-devcontainer-template my-llm-project
cd my-llm-project
