# Compile opencv-python-headless from source with FIPS-safe flags.
#
# The PyPI opencv-python-headless wheel is auditwheel-repaired to sideload a
# private OpenSSL 1.1.1k inside `opencv_python_headless.libs/`. That bundled
# OpenSSL is EOL, not FIPS-validated, and — if FIPS mode is activated in a way
# that propagates to every libcrypto loaded in the process — triggers a
# `FATAL FIPS SELFTEST FAILURE` at container startup.
#
# Building with `WITH_OPENSSL=OFF` and `WITH_FFMPEG=OFF` removes the bundled
# OpenSSL (closes the FIPS failure mode) and the bundled ffmpeg (closes the
# ffmpeg CVEs) at the cost of video IO and cv2.HTTPS, neither of which docling
# uses — cv2 is only exercised for image decode/encode/resize on raw bytes.
#
# We build on the Chainguard python-fips `-dev` image so the builder and runtime
# share the same Wolfi distro — cv2 links against the same libpng/libjpeg/libtiff
# sonames the runtime image ships, and we avoid mirroring Debian's image-codec
# libs under a fabricated multiarch path. The `-dev` image ships gcc/g++/make/
# pkg-config; we add cmake and the codec dev headers via apk. (apk fetches over
# HTTPS to virtualapk.cgr.dev — works in CI runners; a corporate MITM proxy
# like Zscaler will break the TLS handshake locally.)
ARG PYTHON_MAJOR=3
ARG PYTHON_MINOR=13
ARG PYTHON_PATCH=14
ARG PYTHON_REVISION=r3
ARG PYTHON_VERSION=${PYTHON_MAJOR}.${PYTHON_MINOR}.${PYTHON_PATCH}-${PYTHON_REVISION}
FROM nexus.int.onebrief.tools/cgr.dev/onebrief.com/python-fips:${PYTHON_VERSION}-dev AS opencv-builder
USER 0
# Install the packages the cv2 compile link-checks against. Keep this line
# stable — adding packages here invalidates the `pip wheel` layer below and
# triggers a ~20-min OpenCV recompile. TIFF dev libs are intentionally omitted
# because Wolfi's libtiff is built with --enable-jpeg12 which expects symbols
# (jpeg12_write_raw_data) from a 12-bit-capable libjpeg that Wolfi doesn't
# ship in the standard libjpeg.so.8 — we sidestep by disabling TIFF in cv2.
RUN apk update && apk add --no-cache \
        cmake \
        libpng-dev libjpeg-turbo-dev zlib-dev libwebp-dev
# Pin to the newest opencv-python-headless that publishes an sdist. The project
# ships later releases as prebuilt wheels only (no sdist), so `pip wheel
# --no-binary` can't resolve them. Bump when a newer sdist is available.
# Latest wheel-only version uv.lock tracks is 4.13.0.92; the drift from 4.12 to
# 4.13 is minor and cv2 API is stable — docling's imdecode/imencode/resize path
# is unaffected.
ARG OPENCV_HEADLESS_VERSION=4.12.0.88
ENV ENABLE_HEADLESS=1 \
    ENABLE_CONTRIB=0 \
    CMAKE_ARGS="-DWITH_FFMPEG=OFF -DWITH_OPENSSL=OFF -DWITH_GSTREAMER=OFF \
                -DWITH_GTK=OFF -DWITH_QT=OFF -DWITH_V4L=OFF -DWITH_1394=OFF \
                -DWITH_ANDROID_MEDIANDK=OFF \
                -DWITH_TIFF=OFF -DWITH_JPEG2000=OFF -DWITH_OPENEXR=OFF \
                -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF \
                -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF"
RUN pip install --no-cache-dir --upgrade pip wheel setuptools
RUN pip wheel --no-binary opencv-python-headless \
        "opencv-python-headless==${OPENCV_HEADLESS_VERSION}" \
        -w /out

FROM nexus.int.onebrief.tools/cgr.dev/onebrief.com/python-fips:${PYTHON_VERSION}-dev AS build
ARG TARGETARCH
ENV UV_COMPILE_BYTECODE=0 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=0

WORKDIR /app

COPY ./pyproject.toml ./uv.lock ./
COPY --from=opencv-builder /out/opencv_python_headless-*.whl /tmp/

RUN /usr/bin/python -m pip install --no-cache-dir uv

# Create a virtual environment
RUN /usr/bin/python -m uv venv /app/.venv

# Install dependencies using lockfile for pinned versions (deps only — source not yet present).
# We swap the PyPI opencv-python-headless wheel for our FIPS-clean rebuild (see opencv-builder
# stage above), and pin cryptography + pillow to CVE-patched versions. rapidocr stays in as our
# OCR engine: ONNX-based, no cysignals, FIPS-safe.
#
# Arch split: amd64 uses CUDA (cu128 torch group + onnxruntime-gpu); arm64 is
# CPU-only because onnxruntime-gpu publishes no aarch64 wheels and the realistic
# arm64 deploy targets (Graviton/Ampere) have no NVIDIA GPUs anyway.
RUN --mount=type=cache,target=/root/.cache/uv \
    if [ "$TARGETARCH" = "arm64" ]; then \
        TORCH_GROUP=cpu; ORT_PKG=onnxruntime; \
    else \
        TORCH_GROUP=cu128; ORT_PKG=onnxruntime-gpu; \
    fi \
    && /usr/bin/python -m uv sync --frozen --python /app/.venv/bin/python --group "$TORCH_GROUP" --no-group dev --no-group pypi --no-install-project \
    && /usr/bin/python -m uv pip uninstall --python /app/.venv/bin/python opencv-python opencv-python-headless \
    && /usr/bin/python -m uv pip install --python /app/.venv/bin/python /tmp/opencv_python_headless-*.whl \
    && /usr/bin/python -m uv pip install --python /app/.venv/bin/python "${ORT_PKG}>=1.19.0" \
    && /usr/bin/python -m uv pip install --python /app/.venv/bin/python "cryptography>=46.0.5" "pillow>=12.3.0"

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

ARG PYTHON_MAJOR
ARG PYTHON_MINOR
RUN SITE=/app/.venv/lib/python${PYTHON_MAJOR}.${PYTHON_MINOR}/site-packages && \
    mkdir -p "$SITE/torch" "$SITE/triton" "$SITE/nvidia/cudnn" "$SITE/nvidia/cublas"

FROM build AS venv-rest
ARG PYTHON_MAJOR
ARG PYTHON_MINOR
RUN SITE=/app/.venv/lib/python${PYTHON_MAJOR}.${PYTHON_MINOR}/site-packages && \
    rm -rf "$SITE/torch" "$SITE/triton" "$SITE/nvidia"

FROM build AS nvidia-rest
ARG PYTHON_MAJOR
ARG PYTHON_MINOR
RUN SITE=/app/.venv/lib/python${PYTHON_MAJOR}.${PYTHON_MINOR}/site-packages && \
    rm -rf "$SITE/nvidia/cudnn" "$SITE/nvidia/cublas"

# Multistage release build

FROM nexus.int.onebrief.tools/cgr.dev/onebrief.com/python-fips:${PYTHON_VERSION} AS release

WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:${PATH}"

# Copy the image-codec runtime libraries cv2.abi3.so was linked against in the
# opencv-builder stage. Both stages are Wolfi (Chainguard) so sonames match
# natively — `/usr/lib` is already in ld.so's default search path, no
# LD_LIBRARY_PATH workaround needed. TIFF/JPEG2000/OpenEXR support is compiled
# out of cv2 (see CMAKE_ARGS above), so libtiff/liblzma/libzstd are not copied.
# libsharpyuv is included — webp pulls it in transitively.
COPY --from=opencv-builder /usr/lib/libjpeg.so.8* /usr/lib/
COPY --from=opencv-builder /usr/lib/libpng16.so.16* /usr/lib/
COPY --from=opencv-builder /usr/lib/libwebp.so.7* /usr/lib/
COPY --from=opencv-builder /usr/lib/libwebpdemux.so.2* /usr/lib/
COPY --from=opencv-builder /usr/lib/libwebpmux.so.3* /usr/lib/
COPY --from=opencv-builder /usr/lib/libsharpyuv.so.0* /usr/lib/

# Copy venv + docling source + model weights from build stage. OCR uses rapidocr
# (ONNX-based) — picked over tesserocr because tesserocr pulls in cysignals and
# trips OpenSSL's FIPS self-test in FIPS-enforced environments (FATAL FIPS
# SELFTEST FAILURE at startup).
ARG PYTHON_MAJOR
ARG PYTHON_MINOR
ARG SITE=/app/.venv/lib/python${PYTHON_MAJOR}.${PYTHON_MINOR}/site-packages
COPY --from=venv-rest --chown=65532:65532 /app/.venv /app/.venv
COPY --from=build --chown=65532:65532 ${SITE}/torch ${SITE}/torch
COPY --from=build --chown=65532:65532 ${SITE}/triton ${SITE}/triton
COPY --from=nvidia-rest --chown=65532:65532 ${SITE}/nvidia ${SITE}/nvidia
COPY --from=build --chown=65532:65532 ${SITE}/nvidia/cudnn ${SITE}/nvidia/cudnn
COPY --from=build --chown=65532:65532 ${SITE}/nvidia/cublas ${SITE}/nvidia/cublas
COPY --from=build --chown=65532:65532 /app/docling_serve /app/docling_serve
COPY --from=build --chown=65532:65532 /app/pyproject.toml /app/uv.lock /app/README.md /app/
COPY --from=build --chown=65532:65532 /app/.cache/docling/models /app/.cache/docling/models
ENV \
    DOCLING_SERVE_ARTIFACTS_PATH=/app/.cache/docling/models

USER nonroot

# Smoke test: fail the build if the app can't be imported/assembled in the final
# runtime image. Catches import-time crashes (missing/renamed distributions like
# docling vs docling-slim, bad merge resolutions, missing runtime .so libs) before
# the image is ever pushed or deployed. Runs as nonroot to mirror runtime.
RUN ["/app/.venv/bin/python", "-c", "import docling_serve.app; from docling_serve.app import create_app; create_app()"]

ENTRYPOINT ["docling-serve", "run"]
