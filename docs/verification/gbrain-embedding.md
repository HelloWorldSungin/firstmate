# GBrain embedding endpoint verification

This record captures evidence from the active user-level embedding service described in [`gbrain-endpoints.md`](../gbrain-endpoints.md).

## 2026-08-04

Host `research` exposed four RTX 5060 Ti GPUs with driver 570.207 and compute capability 12.0.
The verified deployment ran Ollama v0.32.5 with `CUDA_VISIBLE_DEVICES=0`.
The tracked handoff unit now pins `CUDA_VISIBLE_DEVICES=GPU-d8875f51-293f-a66f-71c2-b6da16c568d0`, but that revision has not been installed or rerun through the recovery checks below.
The service used model `snowflake-arctic-embed2:568m` with Ollama digest `5de93a84837d0ff00da872e90830df5d973f616cbf1e5c198731ab19dd7b776b`.
The underlying F16 GGUF blob SHA-256 was `8c625c9569c3c799f5f9595b5a141f91d224233055608189d66746347c14e613`.
The endpoint probe returned `model: snowflake-arctic-embed2:568m` and `dimensions: 1024`.

```sh
systemctl --user daemon-reload
systemctl --user restart gbrain-embedding.service
/home/sungin/.local/gbrain-endpoints/bin/check-embedding.sh
systemctl --user kill --signal=KILL --kill-who=main gbrain-embedding.service
/home/sungin/.local/gbrain-endpoints/bin/check-embedding.sh
loginctl show-user sungin --property=Linger --value
systemctl --user is-enabled gbrain-embedding.service
```

After the full restart, the service remained enabled and active.
After the deliberate main-process crash, its PID changed from `1975522` to `2013311` and `NRestarts` increased from `0` to `1`.
The linger query returned `yes`, and the enablement query returned `enabled`.
`nvidia-smi` showed the embedding runner on GPU UUID `GPU-d8875f51-293f-a66f-71c2-b6da16c568d0` using 782 MiB.
`ss -ltnp` showed the public endpoint listening only on `127.0.0.1:11434`.
The service journal recorded the probes as loopback `POST /v1/embeddings` requests and no outbound inference request.
