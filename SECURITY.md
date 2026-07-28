# Security

## Do not commit secrets

Never commit API keys, tokens, passwords, or private hostnames into this repository.

- Server auth: `LLAMA_API_KEY` / `--api-key` (see `.env.example`)
- Hugging Face: `HF_TOKEN` / `--hf-token`
- Local overrides: `.env`, `*.env`, `credentials.json`, `*.key` — all gitignored

If you accidentally commit a secret, **rotate the credential immediately** and consider rewriting git history (`git filter-repo` / BFG) before the next public push.

## Local paths

Operator-specific paths (`MODELS_DIR`, `GODZILLA_ROOT`, calibration trees, benchmark harnesses) belong in your environment or a private copy of `docs/LOCAL-SETUP.example.md` — not in committed scripts with real drive letters.

## Reporting

For security issues in this fork, open a private advisory on GitHub or contact the maintainer listed in `README.md`.
