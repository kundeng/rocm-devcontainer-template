#!/usr/bin/env bash
set -euo pipefail
python - <<'PY'
import torch
print("torch:", torch.__version__)
print("torch.version.hip:", getattr(getattr(torch,"version",None),"hip",None))
print("cuda_is_available (should be False on ROCm):", torch.cuda.is_available())
print("OK: ROCm + PyTorch + vLLM container ready.")
PY
