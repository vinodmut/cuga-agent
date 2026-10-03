# Run CUGA with Ollama using `uvx`

This setup ran the PyPI release `cuga==0.3.2` with Ollama's `gpt-oss:20b` model from a new temporary working directory. It uses Ollama's OpenAI-compatible API, so no OpenAI account or API key is needed.

## Prerequisites

Install `uv` and Ollama. Start Ollama if it is not already running (`ollama serve` in another terminal), then download the model:

```bash
ollama pull gpt-oss:20b
```

## Start the CRM demo

Run this in a shell. The temporary directory keeps CUGA's demo files separate from an existing project; `uvx` uses its normal package cache.

```bash
cd "$(mktemp -d)"

AGENT_SETTING_CONFIG=settings.ollama.toml \
OPENAI_API_KEY=ollama \
OPENAI_BASE_URL=http://127.0.0.1:11434/v1 \
MODEL_NAME=gpt-oss:20b \
uvx --python 3.12 --from cuga==0.3.2 cuga start demo_crm --read-only --no-email
```

`OPENAI_API_KEY=ollama` is a placeholder accepted by the OpenAI client; Ollama ignores it. Keep `OPENAI_BASE_URL` in this command: the managed CRM demo can create an LLM from its saved configuration, and in `0.3.2` that path does not inherit the URL in `settings.ollama.toml`. Without the environment override, the test request went to OpenAI and returned HTTP 401. The `--read-only` flag prepares the demo workspace for read-only use, and `--no-email` disables the email services.

## Verify a full task

With CUGA still running, send this request from another terminal. The demo server uses HTTP on port 7860 unless SSL is configured.

```bash
curl -N --max-time 600 http://127.0.0.1:7860/stream \
  -H 'Content-Type: application/json' \
  --data '{"query":"Using the CRM API, retrieve contact with ID 1. Report the contact full name and email address. Do not guess or use workspace files."}'
```

On 2026-10-02, CUGA called `crm_get_contact_contacts_contact_id_get(contact_id=1)` and returned John Smith, `john.smith@acmecorporation.gmail.com`, matching a direct CRM API read. This verifies one complete CRM lookup with `gpt-oss:20b`; other Ollama models and tasks may behave differently.

Stop the demo with Ctrl-C in the terminal running `uvx`.
