# Linux Agent Activity Events

The Linux agent can report meaningful server lifecycle events to the GSP Panel activity log. It does not send routine XML-RPC chatter, file reads, status polls with no state change, or every local agent log line.

## Configuration

Set these values in `Cfg/Config.pm` under the selected install directory:

```perl
agent_event_url => 'https://panel.example.com/agent_event_receiver.php',
remote_server_id => '1',
```

If `agent_event_url` is empty, the agent attempts to derive it from `web_api_url`. The `key` value must match the Panel remote server encryption key because it is used to sign event payloads.

Default new install path:

```text
/home/gameserver/GSP/Cfg/Config.pm
```

## Authentication

Events are JSON POST requests signed with HMAC-SHA256:

- `X-GSP-Agent-Id`: Panel `remote_server_id`
- `X-GSP-Agent-Timestamp`: Unix timestamp
- `X-GSP-Agent-Signature`: `sha256=` plus HMAC of `timestamp.body`

The Panel validates the signature, remote server identity, event type, severity, and `home_id` ownership before writing the activity log.

## Offline Queue

If the Panel is unavailable, the Linux agent appends events to:

```text
events/pending-events.jsonl
```

The queue is retried after later successful event deliveries and rotates when it exceeds 1 MB. Server start, stop, and restart operations do not wait on Panel event delivery.

## Lifecycle Detection

The agent uses existing runtime evidence:

- screen/session status
- tracked PID metadata
- process existence
- required game/query/RCON port validation
- short-lived status hints such as `STARTING`, `STOPPING`, and `STOPPED`

It does not create or read `SERVER_STOPPED` marker files.

## Reported Events

The Linux agent reports confirmed start and stop outcomes, unresponsive process states, missing/restored port transitions, unexpected `ONLINE -> OFFLINE` transitions, and scheduled restart sequences when the scheduler invokes restart actions.

External kills, including a companion bot terminating a server process, are recorded after status polling observes the validated state change.
