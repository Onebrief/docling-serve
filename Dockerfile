FROM nexus.int.onebrief.tools/cgr.dev/onebrief.com/python-fips:3.13.13-dev AS build
ENV UV_COMPILE_BYTECODE=0 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=0

WORKDIR /app

COPY ./pyproject.toml ./uv.lock ./

RUN /usr/bin/python -m pip install --no-cache-dir uv

# Create a virtual environment
RUN /usr/bin/python -m uv venv /app/.venv

# Install dependencies using lockfile for pinned versions (deps only — source not yet present).
# We swap opencv-python (which pulls GUI libs) for opencv-python-headless, and pin
# cryptography + pillow to CVE-patched versions. rapidocr stays in as our OCR engine:
# it's ONNX-based (no cysignals, FIPS-safe) and doesn't need an external binary.
RUN --mount=type=cache,target=/root/.cache/uv \
    /usr/bin/python -m uv sync --frozen --python /app/.venv/bin/python --group cu128 --no-group dev --no-group pypi --no-install-project \
    && /usr/bin/python -m uv pip uninstall --python /app/.venv/bin/python opencv-python opencv-python-headless \
    && /usr/bin/python -m uv pip install --python /app/.venv/bin/python opencv-python-headless \
    && /usr/bin/python -m uv pip install --python /app/.venv/bin/python "onnxruntime-gpu>=1.19.0" \
    && /usr/bin/python -m uv pip install --python /app/.venv/bin/python "cryptography>=46.0.5" "pillow>=12.1.1"

# Copy project source and install the docling_serve package itself (cheap vs. the deps layer above)
COPY ./docling_serve ./docling_serve
COPY ./README.md ./
RUN --mount=type=cache,target=/root/.cache/uv \
    /usr/bin/python -m uv pip install --python /app/.venv/bin/python --no-deps -e .

# Download models in build stage (has shell available)
ARG MODELS_LIST="layout tableformer rapidocr"
ENV DOCLING_SERVE_ARTIFACTS_PATH=/app/.cache/docling/models
RUN HF_HUB_DOWNLOAD_TIMEOUT="90" \
    HF_HUB_ETAG_TIMEOUT="90" \
    /app/.venv/bin/docling-tools models download -o "${DOCLING_SERVE_ARTIFACTS_PATH}" ${MODELS_LIST}

# Multistage release build

FROM nexus.int.onebrief.tools/cgr.dev/onebrief.com/python-fips:3.13.13 AS release

WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:${PATH}"

# Copy venv + docling source + model weights from build stage. OCR uses rapidocr
# (ONNX-based) — picked over tesserocr because tesserocr pulls in cysignals and
# trips OpenSSL's FIPS self-test in FIPS-enforced environments (FATAL FIPS
# SELFTEST FAILURE at startup). rapidocr needs no external binaries or external
# image sources, so the release stage is pure Chainguard FIPS.
COPY --from=build --chown=65532:65532 /app/ /app/
ENV \
    DOCLING_SERVE_ARTIFACTS_PATH=/app/.cache/docling/models

USER nonroot

ENTRYPOINT ["docling-serve", "run"]
