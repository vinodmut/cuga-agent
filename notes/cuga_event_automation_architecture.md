# Event-Driven CUGA Architecture Notes

## Question

CUGA needs event-driven capabilities: schedules, polling, webhooks, SaaS events, and invocation of CUGA agents. The MVP proposal currently describes a single CUGA daemon that owns cron, pull, push, dispatch, per-agent inboxes, and invocation.

The design question is whether CUGA should build all event automation itself, or rely on an existing automation/orchestration layer such as Zapier, an open-source equivalent, Kestra, or NemoClaw.

## Short Recommendation

Use separate layers:

```text
Kestra = event automation and declarative flows
CUGA = intent, memory, routing, agent dispatch, tool policy
NemoClaw = governed/sandboxed runtime for running CUGA safely
```

The strongest architecture is:

```text
Slack / GitHub / Gmail / schedule / webhook / HTTP poll
        |
        v
Kestra flow
        |
        v
CUGA POST /events
        |
        v
CUGA dispatcher -> per-agent inbox -> invoker -> agent/tools
        |
        v
Slack / GitHub / DB / files / web / APIs
```

If using NemoClaw:

```text
Slack / GitHub / Gmail / schedule / webhook / HTTP poll
        |
        v
Kestra flow
        |
        v
CUGA running inside NemoClaw / OpenShell
        |
        v
CUGA dispatcher -> agent -> tools
```

## Why Not Build All Event Handling In CUGA?

The MVP daemon can absolutely implement cron, polling, push ingress, state-diffing, retries, and dispatch. That is a reasonable narrow MVP.

But the moment the system needs a UI, headless execution, declarative config, programmatic generation, logs, retries, backfills, and external integrations, CUGA starts rebuilding a workflow engine.

CUGA should own the agent-specific semantics:

- Standing intent registration
- Normalized event schema
- Idempotency and thread routing
- Memory/context
- Agent invocation
- Tool/action policy
- Human-in-the-loop decisions
- Semantic filtering such as "only alert after two failures"

The automation layer should own transport and trigger mechanics:

- Cron schedules
- Webhook endpoints
- Polling loops
- SaaS connector auth
- Retry behavior
- Execution logs
- Flow UI
- Declarative deployment

## Zapier-Like Options

| Tool | Fit | Notes |
|---|---|---|
| Activepieces | Best open-source Zapier-like UX | Good for no-code automation and connectors. Less ideal if declarative flow generation is the main requirement. |
| n8n | Very practical and mature | Strong UI and JSON workflow export/import. Source-available rather than OSI open source. |
| Windmill | Strong developer-first option | Good for workflows as code, scripts, Git sync, and internal tooling. |
| Node-RED | Lightweight event-flow runtime | JSON flows and headless operation, but less polished as a SaaS automation product. |
| Automatisch | Zapier-like self-hosted tool | Smaller ecosystem. |
| Huginn | Conceptually close to event agents | Older stack, less modern product polish. |
| Trigger.dev | Great durable TypeScript jobs | Better for app-side jobs than broad no-code event automation. |
| Kestra | Best declarative orchestration fit | YAML flows, UI, headless runtime, schedules, webhooks, polling, API/Terraform/CLI deployment. |

Given the requirements of UI + headless + programmatic generation + declarative config, Kestra is the best fit.

## CUGA + Kestra Boundary

CUGA should expose one stable event ingestion API:

```http
POST /events
Authorization: Bearer <token>
Content-Type: application/json
```

Recommended event shape:

```json
{
  "source": "kestra",
  "subscription_id": "sub_prod_healthz",
  "event_type": "http.health_check",
  "idempotency_key": "kestra:prod_healthz_monitor:{{ execution.id }}",
  "target_agent": "server_monitor",
  "thread_key": "prod-api-healthz",
  "payload": {}
}
```

CUGA's registry should remain the product-level source of truth:

```text
subscription_id
provider = kestra
provider_flow_id
provider_flow_version
target_agent
source_spec_hash
status
created_at
updated_at
```

## Provider-Neutral CUGA Spec

CUGA should compile user intent into a neutral spec first:

```yaml
id: prod_health_monitor
trigger:
  kind: schedule
  interval: 2m
source:
  type: http
  url: https://prod-api.acme.com/healthz
condition:
  failure_count: 2
target:
  agent: server_monitor
  thread_key: prod-api-healthz
deliver:
  type: cuga_event
```

Then render provider-specific output:

```text
CUGA AutomationSpec
        |
        v
Kestra YAML / Windmill flow / n8n JSON / Activepieces flow
```

This avoids baking Kestra concepts into CUGA's core model.

## Example Kestra Flow: Daily Standup Prompt

Kestra handles cron. CUGA handles agent invocation and Slack posting behavior.

```yaml
id: daily_standup_prompt
namespace: cuga.generated

triggers:
  - id: weekday_930
    type: io.kestra.plugin.core.trigger.Schedule
    cron: "30 9 * * 1-5"

tasks:
  - id: invoke_cuga
    type: io.kestra.plugin.core.http.Request
    uri: "{{ secret('CUGA_EVENTS_URL') }}"
    method: POST
    contentType: application/json
    headers:
      Authorization: "Bearer {{ secret('CUGA_EVENTS_TOKEN') }}"
    body: |
      {
        "source": "kestra",
        "subscription_id": "sub_daily_standup_prompt",
        "event_type": "cron.fire",
        "idempotency_key": "kestra:daily_standup_prompt:{{ execution.id }}",
        "target_agent": "standup_poster",
        "thread_key": "slack:eng-standup",
        "payload": {
          "trigger_time": "{{ trigger.date }}",
          "outbound_channel": "slack://acme-ws/#eng-standup"
        }
      }
```

## Example Kestra Flow: Webhook to CUGA

An external system posts to Kestra. Kestra normalizes and forwards to CUGA.

```yaml
id: inbound_slack_dm
namespace: cuga.generated

triggers:
  - id: webhook
    type: io.kestra.plugin.core.trigger.Webhook
    key: "{{ secret('SLACK_DM_WEBHOOK_KEY') }}"

tasks:
  - id: invoke_cuga
    type: io.kestra.plugin.core.http.Request
    uri: "{{ secret('CUGA_EVENTS_URL') }}"
    method: POST
    contentType: application/json
    headers:
      Authorization: "Bearer {{ secret('CUGA_EVENTS_TOKEN') }}"
    body: |
      {
        "source": "kestra",
        "subscription_id": "sub_slack_dm_triage",
        "event_type": "slack.message.im",
        "idempotency_key": "kestra:inbound_slack_dm:{{ execution.id }}",
        "target_agent": "dm_triage",
        "thread_key": "slack-dm",
        "payload": {
          "body": {{ trigger.body | json }},
          "headers": {{ trigger.headers | json }}
        }
      }
```

## Example Kestra Flow: HTTP Health Monitor

For the MVP, keep the "two consecutive failures" state in CUGA. Kestra polls and forwards observations. CUGA decides when to alert.

```yaml
id: prod_healthz_monitor
namespace: cuga.generated

triggers:
  - id: every_2_minutes
    type: io.kestra.plugin.core.trigger.Schedule
    cron: "*/2 * * * *"

tasks:
  - id: health_check
    type: io.kestra.plugin.core.http.Request
    uri: https://prod-api.acme.com/healthz
    method: GET

  - id: invoke_cuga
    type: io.kestra.plugin.core.http.Request
    uri: "{{ secret('CUGA_EVENTS_URL') }}"
    method: POST
    contentType: application/json
    headers:
      Authorization: "Bearer {{ secret('CUGA_EVENTS_TOKEN') }}"
    body: |
      {
        "source": "kestra",
        "subscription_id": "sub_prod_healthz_monitor",
        "event_type": "http.health_check",
        "idempotency_key": "kestra:prod_healthz_monitor:{{ execution.id }}",
        "target_agent": "server_monitor",
        "thread_key": "prod-api-healthz",
        "payload": {
          "url": "https://prod-api.acme.com/healthz",
          "status_code": {{ outputs.health_check.code }},
          "response_body": {{ outputs.health_check.body | json }}
        }
      }
```

## Programmatic Deployment

CUGA should generate flow YAML and deploy it headlessly:

```text
User intent
  -> CUGA AutomationSpec
  -> Kestra YAML flow
  -> kestractl flows deploy ./flows --namespace cuga.generated --override
  -> save provider_flow_id in CUGA registry
```

For infrastructure-managed deployments, Terraform can own Kestra flows as resources. For product-generated user automations, CUGA can call the Kestra API or shell out to `kestractl` from a controlled backend worker.

## What About Adding CUGA To NemoClaw?

NemoClaw should be treated as a governed agent runtime, not as the primary automation engine.

Use NemoClaw to run CUGA more safely:

```text
NemoClaw sandbox
  - cuga-api
  - cuga-invoker
  - cuga-registry.sqlite or external DB
  - tool adapters
  - model routing
  - credential and network policy
```

This gives CUGA:

- Sandboxed long-running agent execution
- Controlled network/tool access
- Local or routed model inference
- Auditable execution environment
- Safer always-on behavior

## Does NemoClaw Replace Kestra?

Not fully.

NemoClaw can handle some messaging-channel ingress, such as Slack-like message delivery into an always-on agent runtime. That may cover cases like:

```text
Slack DM -> CUGA agent
```

But CUGA's MVP needs more than messaging ingress:

- Cron schedules
- Polling Slack history
- Polling stocks/APIs/health endpoints
- Webhooks from arbitrary systems
- Declarative automation definitions
- UI for building automations
- Headless automation deployment
- Event-level retries and logs

Those are Kestra-shaped responsibilities.

If Kestra is removed, CUGA must implement the event engine itself:

```text
NemoClaw sandbox
  - CUGA daemon
      - Slack/message ingress
      - cron scheduler
      - poller tasks
      - webhook server
      - state/dedupe
      - dispatcher
      - invoker
```

That is viable for a narrow MVP, but it means rebuilding the automation control plane.

## Practical MVP Path

1. Keep CUGA's `/events` API, dispatcher, inboxes, invoker, and registry.
2. Use Kestra for cron, webhooks, polling, retries, and UI/declarative flows.
3. Generate Kestra YAML from CUGA's provider-neutral `AutomationSpec`.
4. Run CUGA normally first.
5. Package CUGA inside NemoClaw/OpenShell once sandboxing and governance become important.
6. Later, optionally build a custom Kestra task such as `io.cuga.kestra.InvokeAgent` to replace raw HTTP Request tasks.

## Final Layering

```text
Kestra creates and runs the automation.
CUGA understands and executes the intent.
NemoClaw governs the agent runtime.
```

That division keeps each system doing the thing it is strongest at.

## Kestra-To-CUGA Smoke Test

The repo includes a real boundary smoke test:

```bash
CUGA_EVENTS_TOKEN=dev-smoke-token \
CUGA_EVENTS_URL=http://host.docker.internal:7860/events \
./scripts/smoke_kestra_to_cuga.sh --start-kestra
```

What it does:

1. Starts Kestra in Docker, unless an existing Kestra URL is supplied.
2. Deploys `deployment/kestra/cuga_event_smoke.yaml`.
3. Executes the Kestra flow.
4. Verifies the Kestra execution reaches a terminal success state after its HTTP task receives a 2xx response from CUGA.

The flow sends this normalized event shape to CUGA:

```json
{
  "source": "kestra",
  "subscription_id": "sub_smoke_kestra_to_cuga",
  "event_type": "slack.message.posted",
  "idempotency_key": "kestra:cuga_event_smoke:{{ execution.id }}",
  "target_agent": "cuga-default",
  "thread_key": "slack:T_SMOKE:C_SMOKE:{{ execution.id }}",
  "payload": {
    "team": "T_SMOKE",
    "channel": "C_SMOKE",
    "user": "U_SMOKE",
    "text": "Smoke test message from Kestra to CUGA"
  }
}
```

For an already-running Kestra:

```bash
KESTRA_URL=http://127.0.0.1:8080 \
CUGA_EVENTS_URL=http://127.0.0.1:7860/events \
CUGA_EVENTS_TOKEN=dev-smoke-token \
./scripts/smoke_kestra_to_cuga.sh
```

This smoke test intentionally depends on a real CUGA `/events` endpoint. Until that endpoint exists, the Kestra execution should fail with an HTTP error, which is the correct signal that the event ingress slice is not implemented yet.
