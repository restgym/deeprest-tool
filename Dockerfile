# DeepREST for RESTgym, built from the sources of RestTestGen v25.12 as DeepREST.dockerfile does, with the LLM of the
# LLM parameter value provider (qwen3:8b, with thinking) served by Ollama inside the tool container, on the GPU that
# RESTgym assigns to the run: the network of a run has no access to the host nor to the internet.
# RESTgym builds this file from its root, with this repository at tools/deeprest/. It replaces the Dockerfile of
# RestTestGen, which builds RestTestGen alone (without the Python component of DeepREST).

# Stage 1: RestTestGen, built with Gradle (as in DeepREST.dockerfile)
FROM gradle:8.14-jdk17@sha256:daf223983fb0f4cca2d814a3f68443afda41835f8b1f86f0f3345242d6c43683 AS java-builder
WORKDIR /app
COPY tools/deeprest/build.gradle ./
COPY tools/deeprest/src/ ./src/
RUN gradle clean build -x test --no-daemon

# Stage 2: Ollama and the model, downloaded at build time. The manifest of the model, as Ollama saves it, is checked
# against its SHA-256: it lists the SHA-256 of the files of the model, which Ollama checks when it downloads them, and of
# the manifest in the registry (500a1f067a9f..., the ID shown by ollama list)
FROM ollama/ollama:0.40.3@sha256:44833c52df2a164cc1238a96ce100123c8e54082b85c5e235a9cb5a7adc55f27 AS ollama
ARG OLLAMA_MODEL=qwen3:8b
ARG OLLAMA_MODEL_MANIFEST_SHA256=b3d9ba7c899cfd112df2574c6a91458a70b724c5e4e50dfffd75574b2d1648e7
ENV OLLAMA_MODELS=/models
RUN ollama serve > /tmp/ollama.log 2>&1 & PID=$!; \
    for i in $(seq 1 60); do ollama list > /dev/null 2>&1 && break; sleep 1; done; \
    ollama pull "$OLLAMA_MODEL"; RC=$?; \
    kill $PID; wait $PID 2> /dev/null; \
    [ "$RC" = 0 ] || exit $RC; \
    echo "$OLLAMA_MODEL_MANIFEST_SHA256  /models/manifests/registry.ollama.ai/library/${OLLAMA_MODEL%%:*}/${OLLAMA_MODEL#*:}" \
        | sha256sum -c -

# Stage 3: runtime, with Python 3.12 and Stable Baselines 3 (the Python component of DeepREST) and Java 17 (RestTestGen),
# as in DeepREST.dockerfile
FROM python:3.12-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258

# Java 17 runtime from the Temurin image, instead of the Debian package openjdk-17-jre-headless, whose version moves
COPY --from=eclipse-temurin:17-jre@sha256:e04fa72be13b257a59fdec6dc14af78c8f80f035d3c1ed4e03e45552a231d4c8 /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk PATH=/opt/java/openjdk/bin:$PATH

WORKDIR /app

# Stable Baselines 3 (src/main/python/deeprest/requirements.txt) with the versions of all the packages it depends on
# (requirements-restgym.txt), and the CPU build of PyTorch: the PPO agent of DeepREST (MlpPolicy) runs on the CPU, as
# in DeepREST.dockerfile without a GPU; the GPU is for the LLM
COPY tools/deeprest/requirements-restgym.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu --extra-index-url https://pypi.org/simple \
        torch==2.14.1+cpu -c /tmp/requirements.txt \
    && pip install --no-cache-dir -r /tmp/requirements.txt \
    && pip check \
    && rm /tmp/requirements.txt

COPY --from=ollama /usr/bin/ollama /usr/bin/ollama
COPY --from=ollama /usr/lib/ollama /usr/lib/ollama
COPY --from=ollama /models /models
# Model service on the loopback of the tool container (LlmParameterValueProvider). One request at a time: RestTestGen
# asks the LLM sequentially. The context leaves room for the thinking of the model
ENV OLLAMA_HOST=127.0.0.1:11434 OLLAMA_MODELS=/models OLLAMA_KEEP_ALIVE=-1 OLLAMA_MAX_LOADED_MODELS=1 \
    OLLAMA_NUM_PARALLEL=1 OLLAMA_CONTEXT_LENGTH=32768 OLLAMA_NO_CLOUD=1 \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# RestTestGen and the Python component of DeepREST (as in DeepREST.dockerfile)
COPY --from=java-builder /app/build/libs/*-all.jar ./rtg.jar
COPY tools/deeprest/src/main/python/deeprest/ /app/
COPY tools/deeprest/restgym-entrypoint.sh /app/restgym-entrypoint.sh
RUN chmod +x entrypoint.sh restgym-entrypoint.sh && mkfifo /app/j2p /app/p2j

ENTRYPOINT ["/app/restgym-entrypoint.sh"]
