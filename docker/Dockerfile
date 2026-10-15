FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
ARG LLAMA_BUILD=b11576
ARG LLAMA_SHA256=edd02e5852516be9edaffce3c64e2c96b6d040ee3ead6f11483c1570a0e013fd
ARG CUDART_SHA256=023ad10d5e6ade3724b36c75a47d99172fb31661c787015eeb1dc7dbd736ae21
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl libgomp1 libssl3t64 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; mkdir -p /tmp/download /opt/llama; \
    cd /tmp/download; \
    curl -fSL --retry 5 -o llama.tgz "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_BUILD}/llama-${LLAMA_BUILD}-bin-ubuntu-cuda-13.4-x64.tar.gz"; \
    echo "${LLAMA_SHA256}  llama.tgz" | sha256sum -c -; \
    curl -fSL --retry 5 -o cudart.tgz "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_BUILD}/cudart-llama-${LLAMA_BUILD}-bin-ubuntu-cuda-13.4-x64.tar.gz"; \
    echo "${CUDART_SHA256}  cudart.tgz" | sha256sum -c -; \
    tar -xzf llama.tgz -C /opt/llama --strip-components=1; \
    tar -xzf cudart.tgz -C /opt/llama --strip-components=1; \
    rm -rf /tmp/download
ENV LD_LIBRARY_PATH=/opt/llama
COPY inference-entrypoint.sh /usr/local/bin/inference-entrypoint
RUN chmod 755 /usr/local/bin/inference-entrypoint
ENTRYPOINT ["/usr/local/bin/inference-entrypoint"]
