# CUGA Kestra File Summary E2E

This runbook starts from no Docker containers and exercises:

```text
meeting transcript file -> Kestra scheduled file poller -> CUGA /events/meeting-summary -> markdown summary file
```

## 1. Start CUGA

In terminal 1:

```bash
dotenv -e .env -- uv run cuga start --host 0.0.0.0 demo
```

Keep this process running.

## 2. Start Kestra and deploy the flow

In terminal 2:

```bash
dotenv -e .env -- ./scripts/smoke_kestra_file_to_cuga_summary.sh --start-kestra --no-cleanup
```

This starts Kestra on:

```text
http://127.0.0.1:8081
```

Basic auth:

```text
admin@kestra.local
DevSmoke1234!
```

The script deploys:

```text
deployment/kestra/cuga_file_summary_smoke.yaml
```

## 3. Add a transcript

After Kestra is running, copy any `.txt` meeting transcript into the inbox:

```bash
cp /path/to/transcript.txt /private/tmp/cuga-kestra-file-summary-smoke/inbox/my-meeting.txt
```

Kestra polls once per minute.

## 4. Read the summary

After the next poll, read the generated summary:

```bash
cat /private/tmp/cuga-kestra-file-summary-smoke/outbox/my-meeting.summary.md
```

The original transcript should be moved to:

```text
/private/tmp/cuga-kestra-file-summary-smoke/processed/my-meeting.txt
```

## 5. Stop Kestra

When done:

```bash
docker rm -f cuga-kestra-file-summary-smoke
```

If other smoke containers are running and you want to remove all of them:

```bash
docker rm -f cuga-kestra-file-summary-smoke cuga-kestra-smoke redis-agent-probe
```
