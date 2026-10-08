# Run CUGA with LiteLLM using `uvx`

This example passes all LiteLLM settings on the `uvx` command line. It was verified with the proxy model `Azure/gpt-4.1` on 2026-10-08.

## Start the CRM demo

Install `uv`, replace `YOUR_LITELLM_KEY` and `YOUR_LITELLM_HOST` below, then run the command. The base URL must include `/v1`. For the verified proxy, `Azure/gpt-4.1` is the ID returned by its `/models` endpoint; do not add an `openai/` prefix.

```bash
cd "$(mktemp -d)"

OPENAI_API_KEY='YOUR_LITELLM_KEY' \
OPENAI_BASE_URL='https://YOUR_LITELLM_HOST/v1' \
AGENT_SETTING_CONFIG=settings.openai.toml \
MODEL_NAME=Azure/gpt-4.1 \
uvx cuga
```

The inline `OPENAI_BASE_URL` setting makes the managed CRM demo send model requests to LiteLLM. `MODEL_NAME` selects the proxy's exact model ID. The temporary working directory isolates the demo files; `uvx` still uses its normal package cache.

`uvx cuga` with no arguments starts the CRM demo with email services off, which is all this example needs. `uvx cuga start demo_crm` gives you the full preset (email sink, email MCP) and every tuning flag.

## Verify a CRM task

While CUGA is running, send a request from another terminal:

```bash
curl -N --max-time 300 http://127.0.0.1:7860/stream \
  -H 'Content-Type: application/json' \
  -H 'X-Thread-ID: litellm-uvx-contact-check' \
  --data '{"query":"Using the CRM API, retrieve contact with ID 1. Report the contact full name and email address. Do not guess or use workspace files."}'
```

You can compare the answer with the CRM API directly:

```bash
curl -fsS http://127.0.0.1:8007/contacts/1
```

In the verified run, `/stream` returned HTTP 200 in about six seconds. CUGA called `crm_get_contact_contacts_contact_id_get(contact_id=1)` and answered John Smith, `john.smith@acmecorporation.gmail.com`, matching the direct CRM response. This confirms one complete lookup with this model and key.

Stop CUGA with Ctrl-C. The CRM, registry, and demo servers then stop; remove the temporary working directory when you no longer need its demo files.
