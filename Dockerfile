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
FROM nexus.int.onebrief.tools/cgr.dev/onebrief.com/python-fips:3.13.13-r3-dev AS opencv-builder
USER 0
# Install the packages the cv2 compile link-checks against. Keep this line
# stable — adding packages here invalidates the `pip wheel` layer below and
# triggers a ~20-min OpenCV recompile. `tiff-dev` (no `lib` prefix) is the
# Wolfi name; everything else keeps the conventional `lib*-dev` naming.
RUN apk update && apk add --no-cache \
        cmake \
        libpng-dev libjpeg-turbo-dev tiff-dev zlib-dev libwebp-dev
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
                -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF \
                -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF"
RUN pip install --no-cache-dir --upgrade pip wheel setuptools
RUN pip wheel --no-binary opencv-python-headless \
        "opencv-python-headless==${OPENCV_HEADLESS_VERSION}" \
        -w /out

FROM nexus.int.onebrief.tools/cgr.dev/onebrief.com/python-fips:3.13.13-r3-dev AS build
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
RUN --mount=type=cache,target=/root/.cache/uv \
    /usr/bin/python -m uv sync --frozen --python /app/.venv/bin/python --group cu128 --no-group dev --no-group pypi --no-install-project \
    && /usr/bin/python -m uv pip uninstall --python /app/.venv/bin/python opencv-python opencv-python-headless \
    && /usr/bin/python -m uv pip install --python /app/.venv/bin/python /tmp/opencv_python_headless-*.whl \
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

FROM nexus.int.onebrief.tools/cgr.dev/onebrief.com/python-fips:3.13.13-r3 AS release

WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:${PATH}"

# Copy the image-codec runtime libraries cv2.abi3.so was linked against in the
# opencv-builder stage. Both stages are Wolfi (Chainguard) so sonames match
# natively — `/usr/lib` is already in ld.so's default search path, no
# LD_LIBRARY_PATH workaround needed. libjbig/libdeflate/libLerc are dropped:
# Wolfi's tiff 4.7.1 doesn't depend on them, so cv2 doesn't expect them
# at load time. libsharpyuv is added — webp pulls it in transitively.
COPY --from=opencv-builder /usr/lib/libjpeg.so.8* /usr/lib/
COPY --from=opencv-builder /usr/lib/libpng16.so.16* /usr/lib/
COPY --from=opencv-builder /usr/lib/libtiff.so.6* /usr/lib/
COPY --from=opencv-builder /usr/lib/libwebp.so.7* /usr/lib/
COPY --from=opencv-builder /usr/lib/libwebpdemux.so.2* /usr/lib/
COPY --from=opencv-builder /usr/lib/libwebpmux.so.3* /usr/lib/
COPY --from=opencv-builder /usr/lib/libsharpyuv.so.0* /usr/lib/
COPY --from=opencv-builder /usr/lib/liblzma.so.5* /usr/lib/
COPY --from=opencv-builder /usr/lib/libzstd.so.1* /usr/lib/

# Copy venv + docling source + model weights from build stage. OCR uses rapidocr
# (ONNX-based) — picked over tesserocr because tesserocr pulls in cysignals and
# trips OpenSSL's FIPS self-test in FIPS-enforced environments (FATAL FIPS
# SELFTEST FAILURE at startup).
COPY --from=build --chown=65532:65532 /app/ /app/
ENV \
    DOCLING_SERVE_ARTIFACTS_PATH=/app/.cache/docling/models

USER nonroot

ENTRYPOINT ["docling-serve", "run"]
