# ROCm Dev Container (AI/LLM focus)
ARG ROCM_SERIES=6.4.3
ARG ROCM_MM=6.4
ARG TORCH_INDEX=https://download.pytorch.org/whl/rocm6.4

FROM rocm/dev-ubuntu-24.04:${ROCM_MM}-complete
ARG TORCH_INDEX
ENV DEBIAN_FRONTEND=noninteractive     UV_NO_MODIFY_PATH=1     PIP_DISABLE_PIP_VERSION_CHECK=1     PYTHONDONTWRITEBYTECODE=1     VLLM_USE_ROCM=1

RUN apt-get update && apt-get install -y --no-install-recommends     git build-essential cmake ninja-build     python3 python3-venv python3-pip     clang wget curl ca-certificates pkg-config   && rm -rf /var/lib/apt/lists/*

# uv
RUN curl -LsSf https://astral.sh/uv/install.sh | bash && ln -sf /root/.local/bin/uv /usr/local/bin/uv

WORKDIR /workspace
RUN uv venv /opt/venv && \
    /opt/venv/bin/python -m ensurepip --upgrade && \
    /opt/venv/bin/python -m pip install --upgrade pip wheel setuptools
ENV PATH="/opt/venv/bin:${PATH}"

# PyTorch ROCm wheels
RUN /opt/venv/bin/python -m pip install --upgrade pip wheel setuptools &&     /opt/venv/bin/python -m pip install "torch>=2.5" torchvision torchaudio --index-url "${TORCH_INDEX}"

# vLLM (ROCm)
RUN /opt/venv/bin/python -m pip install --no-cache-dir "vllm>=0.6.4"

CMD ["/bin/bash"]
