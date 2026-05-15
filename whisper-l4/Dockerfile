# syntax=docker/dockerfile:1.7
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    LIBRARY_PATH=/usr/local/cuda/lib64/stubs:${LIBRARY_PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/lib64/stubs:${LD_LIBRARY_PATH}

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      ffmpeg \
      git \
      ninja-build \
      python3 \
      python3-pip \
      python3-venv && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git

WORKDIR /opt/whisper.cpp
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1
RUN cmake -S . -B build -G Ninja \
      -DGGML_CUDA=ON \
      -DCMAKE_CUDA_ARCHITECTURES=89 \
      -DGGML_NATIVE=OFF \
      -DWHISPER_BUILD_TESTS=OFF \
      -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --target whisper-cli -j"$(nproc)"

RUN mkdir -p /models && \
    /opt/whisper.cpp/models/download-ggml-model.sh large-v3-turbo && \
    mv /opt/whisper.cpp/models/ggml-large-v3-turbo.bin /models/ggml-large-v3-turbo.bin


FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:/opt/whisper.cpp/build/bin:${PATH} \
    LD_LIBRARY_PATH=/opt/whisper.cpp/build/src:/opt/whisper.cpp/build/ggml/src:/opt/whisper.cpp/build/ggml/src/ggml-cuda:/usr/local/cuda/lib64:${LD_LIBRARY_PATH} \
    WHISPER_MODEL_PATH=/models/ggml-large-v3-turbo.bin \
    WHISPER_BIN=/opt/whisper.cpp/build/bin/whisper-cli \
    WHISPER_THREADS=8 \
    WHISPER_USE_FA=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      ffmpeg \
      libgomp1 \
      python3 \
      python3-pip \
      python3-venv && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/whisper.cpp/build/bin \
    /opt/whisper.cpp/build/src \
    /opt/whisper.cpp/build/ggml/src/ggml-cuda \
    /models

COPY --from=builder /opt/whisper.cpp/build/bin/whisper-cli /opt/whisper.cpp/build/bin/whisper-cli
COPY --from=builder /opt/whisper.cpp/build/src/libwhisper.so* /opt/whisper.cpp/build/src/
COPY --from=builder /opt/whisper.cpp/build/ggml/src/libggml.so* /opt/whisper.cpp/build/ggml/src/
COPY --from=builder /opt/whisper.cpp/build/ggml/src/libggml-base.so* /opt/whisper.cpp/build/ggml/src/
COPY --from=builder /opt/whisper.cpp/build/ggml/src/libggml-cpu.so* /opt/whisper.cpp/build/ggml/src/
COPY --from=builder /opt/whisper.cpp/build/ggml/src/ggml-cuda/libggml-cuda.so* /opt/whisper.cpp/build/ggml/src/ggml-cuda/
COPY --from=builder /models/ggml-large-v3-turbo.bin /models/ggml-large-v3-turbo.bin

WORKDIR /app
COPY api/requirements.txt /app/requirements.txt
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir -r /app/requirements.txt

COPY api /app/api
COPY start.sh /app/start.sh

EXPOSE 8080
ENTRYPOINT ["/app/start.sh"]
