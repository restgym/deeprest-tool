#!/usr/bin/env bash
# Entrypoint of the tool container in RESTgym:
# 1. configures RestTestGen for the API under test (API, HOST, PORT, and the specification mounted by RESTgym);
# 2. starts Ollama in the container and loads the model on the GPU (LlmParameterValueProvider reaches it at
#    127.0.0.1:11434). If the model does not start, the container exits with an error, and RESTgym executes the run again;
# 3. runs DeepREST (entrypoint.sh) in a loop: DeepREST stops after its request budget (50 * operations^2) or after the
#    training steps of PPO, while RESTgym stops the container at the end of the time budget.
set -Eeuo pipefail
cd /app

# API directory of RestTestGen (apis/$API/): the specification and the address of the API
mkdir -p "apis/$API/specifications"
cp "/specifications/$API-openapi.json" "apis/$API/specifications/openapi.json"
echo "host: http://$HOST:$PORT" > "apis/$API/api-config.yml"
printf 'apiUnderTest: %s\nstrategyClassName: DeepRestStrategy\n' "$API" > rtg-config.yml

ollama serve > /tmp/ollama.log 2>&1 &
SERVER_PID=$!
READY=false
for ((attempt=0; attempt<120; attempt++)); do
  kill -0 "$SERVER_PID" 2>/dev/null || { echo 'Ollama exited before readiness:' >&2; cat /tmp/ollama.log >&2; exit 1; }
  if ollama list >/dev/null 2>&1; then READY=true; break; fi
  sleep 1
done
[ "$READY" = true ] || { echo 'Ollama startup timed out.' >&2; exit 1; }

# Name of the model for LlmParameterValueProvider (qwen3-8b): qwen3:8b with as many threads as the CPUs of the container.
# By default, llama.cpp uses a thread per physical core of the machine (e.g., 64), which the CPU limit of the container
# (e.g., 8 CPUs) throttles: generation is about 4 times slower, although the model runs on the GPU
THREADS=$(nproc)
read -r QUOTA PERIOD < /sys/fs/cgroup/cpu.max 2>/dev/null || QUOTA=max
if [ "$QUOTA" != max ]; then THREADS=$(( (QUOTA + PERIOD - 1) / PERIOD )); fi
printf 'FROM qwen3:8b\nPARAMETER num_thread %s\n' "$THREADS" > /tmp/Modelfile
ollama create qwen3-8b -f /tmp/Modelfile > /dev/null

# Load the model (a request without a prompt loads it without generating), and check that it is on the GPU
THREADS="$THREADS" python - <<'EOF'
import json, os, sys, time
from urllib.request import Request, urlopen

MODEL = 'qwen3-8b'

def call(path, payload=None, timeout=10):
    data = None if payload is None else json.dumps(payload).encode()
    with urlopen(Request('http://127.0.0.1:11434' + path, data=data, headers={'Content-Type': 'application/json'}),
                 timeout=timeout) as response:
        return json.load(response)

start = time.time()
call('/api/generate', {'model': MODEL, 'keep_alive': -1}, timeout=600)
loaded = next((m for m in call('/api/ps').get('models', []) if m.get('name', '').split(':')[0] == MODEL), None)
if not loaded:
    sys.exit(f'The model {MODEL} is not loaded.')
on_gpu = loaded.get('size_vram', 0)
print(f"Model {MODEL} loaded in {time.time() - start:.1f} s: {on_gpu / 2**30:.1f} of {loaded.get('size', 0) / 2**30:.1f} GiB "
      f"on the GPU, context {loaded.get('context_length')}, {os.environ['THREADS']} threads", flush=True)
if on_gpu <= 0:
    print('WARNING: the model is not on the GPU (no GPU assigned to the container?): it runs on the CPU.', flush=True)
EOF

while true; do
  ./entrypoint.sh || true
  echo 'DeepREST stopped: starting it again.'
  sleep 1
done
