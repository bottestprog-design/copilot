# THIRD-PARTY NOTICES

LocalAI Creative Studio is a local integration and orchestration layer. It does not bundle ComfyUI, Ollama, model weights, custom nodes, browser engines, or third-party model executables.

## Workflow sources and model licenses

- **Wan 2.2 TI2V 5B**: the included text-to-video and image-to-video API graphs are adapted from the official ComfyUI Wan 2.2 example workflow. Wan 2.2 model weights are released under Apache 2.0. Upstream: https://github.com/Wan-Video/Wan2.2 and https://github.com/comfyanonymous/ComfyUI_examples/tree/master/wan22.
- **FLUX.2 Klein 4B**: the included API graph is based on the official ComfyUI Hub workflow. The 4B model variant is Apache 2.0; other FLUX variants may have different terms. Upstream: https://github.com/black-forest-labs/flux2 and https://comfy.org/hub/workflows/flux-2-klein-4b-text-to-image-814fd547d86e/.
- **Qwen-Image-2512**: the included API graph follows the official ComfyUI Hub workflow. The model is Apache 2.0. Upstream: https://huggingface.co/Qwen/Qwen-Image-2512 and https://comfy.org/hub/workflows/qwen-image-2512-7c0c712700e0/.
- **Qwen-Image 2.1**: the included API graph is based on the Comfy-Org benchmark API graph. Its model card/license uses the Qwen Research License, which is non-commercial; do not use it commercially unless you have separate permission. Upstream: https://github.com/Comfy-Org/workflow_templates/blob/main/benchmarks/image_qwen_image_2_1_t2i.json.
- **SDXL Standard**: the included graph is a basic generic ComfyUI API graph. The user supplies a compatible checkpoint and is responsible for its license.

A workflow graph does not grant rights to model weights, LoRAs, embeddings, custom nodes, or generated material. Review the exact upstream license and any third-party terms before commercial use or redistribution. Model names and trademarks belong to their respective owners.

## Python runtime

When no compatible 64-bit CPython 3.11-3.14 runtime with pip, venv, SSL and SQLite is available, setup downloads the official CPython 3.14.10 Windows x64 installer from python.org. The installer is not bundled. The URL and SHA-256 are pinned in `scripts/INSTALL-DESKTOP-APP.ps1`; setup verifies both the exact SHA-256 and a valid Authenticode signature from the Python Software Foundation before executing the installer. Python is installed per-user in a product-specific directory without modifying the global PATH or installing a system-wide launcher.

## Runtime dependencies

Python dependencies are pinned in `requirements.txt`. Their upstream licenses and notices are distributed by their respective maintainers via PyPI/package metadata. This project does not relicense those packages.
