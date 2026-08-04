# Local GBrain embedding endpoint

This operator reference owns the supported local embedding endpoint that GBrain story #6 consumes.
The matching user service and health check are in [`deploy/gbrain-endpoints/`](../deploy/gbrain-endpoints/).

## Endpoint contract

The endpoint is loopback-only at `http://127.0.0.1:11434/v1`.
Use model `snowflake-arctic-embed2:568m` with `POST /embeddings`.
The verified native vector width is 1024.
The service pins the process to GPU `GPU-d8875f51-293f-a66f-71c2-b6da16c568d0` through `CUDA_VISIBLE_DEVICES`.
The Ollama v0.32.5 archive SHA-256 is `f7d6bdbcf71b83aa8670c4e7dc4b6936c0952fcf8b114eaf6a11cbadb9684214`.
The pulled model is F16 and its Ollama digest is `5de93a84837d0ff00da872e90830df5d973f616cbf1e5c198731ab19dd7b776b`.
The underlying GGUF blob SHA-256 is `8c625c9569c3c799f5f9595b5a141f91d224233055608189d66746347c14e613`.

## Install and operate

Copy the tracked service and health-check files to their absolute paths under `/home/sungin/.local/gbrain-endpoints/` and `/home/sungin/.config/systemd/user/`.
The service requires `loginctl enable-linger sungin` so the user manager starts at boot without an interactive login.
Reload and enable the service with `systemctl --user daemon-reload` and `systemctl --user enable --now gbrain-embedding.service`.
Run the health check with `/home/sungin/.local/gbrain-endpoints/bin/check-embedding.sh`.

## GBrain #6 configuration and probe

During story #6, initialize a new PGLite brain with:

```sh
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  gbrain init --pglite \
  --embedding-model ollama:snowflake-arctic-embed2:568m \
  --embedding-dimensions 1024
```

For an existing PGLite brain, use the supported reinitialization path:

```sh
OLLAMA_BASE_URL=http://127.0.0.1:11434/v1 \
  gbrain reinit-pglite \
  --embedding-model ollama:snowflake-arctic-embed2:568m \
  --embedding-dimensions 1024
```

Reinitialization backs up and rebuilds the existing PGLite brain, so run it only as part of story #6.
GBrain does not persist the command-scoped `OLLAMA_BASE_URL` value during initialization or reinitialization.
Set `OLLAMA_BASE_URL=http://127.0.0.1:11434/v1` for every later GBrain command, including `import`, `embed`, and `search`.
Without it, GBrain falls back to `http://localhost:11434/v1`, which can miss this IPv4-only listener.
Verify the endpoint directly before initialization:

```sh
curl --fail --silent --show-error http://127.0.0.1:11434/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"snowflake-arctic-embed2:568m","input":"GBrain endpoint probe."}' \
  | jq '{model, dimensions: (.data[0].embedding | length)}'
```

The expected result identifies `snowflake-arctic-embed2:568m` and reports `dimensions: 1024`.
The endpoint is local and requires no API key.
The current service-recovery and local-network evidence is in [`verification/gbrain-embedding.md`](verification/gbrain-embedding.md).
