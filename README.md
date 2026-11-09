# omarchy-openclaw

An [Omarchy](https://omarchy.org/) shell plugin for [OpenClaw](https://openclaw.ai/):
a native bar widget, a chat panel for your agents, and desktop notifications
when an agent finishes a task.

```
┌─ bar ──────────────────────────────────────────────────────────┐
│  …  󰚩 3   bluetooth   network   audio   power                  │
└────────────────────────────────────────────────────────────────┘

OpenClaw panel
┌────────────────────────────────────────────────────────────────┐
│  OpenClaw                         Gateway 2026.10.10 · 2 actifs │
│  AGENTS                  │  Main agent                       ■  │
│  ● Main agent      12:04 │  ┌──────────────────────────────┐   │
│  ● Ops             11:58 │  │ Bonjour, tu peux vérifier…   │   │
│                          │  └──────────────────────────────┘   │
│                          │  ┌──────────────────────────────┐   │
│                          │  │ Oui, tout est vert.          │   │
│                          │  └──────────────────────────────┘   │
│                          │  [ Message à OpenClaw… ]   Envoyer  │
└────────────────────────────────────────────────────────────────┘
```

## Features

- **One bar icon** with gateway status, active-run pulse, and unread badge.
- **Native Omarchy panel**: agent/session list, transcript, send, and stop.
- **Desktop notifications** through `omarchy notification send` when any agent
  finishes, with the agent name and a short preview.
- **One shared gateway connection** for every monitor: the plugin is a shell
  service, so the bridge runs once even when the bar exists on several outputs.
- **Uses your existing OpenClaw credentials**: gateway URL and token are read
  from `~/.openclaw/openclaw.json`; no copy/paste needed.
- **Reuses the OpenClaw device identity** from the local state database, so
  approving one device also unblocks the CLI.
- **No polling for chat**: `sessions.subscribe` and session message events drive
  the UI; a fallback refresh keeps it honest after reconnects.

## Requirements

- Omarchy with the Quickshell-based shell.
- OpenClaw installed locally (`openclaw` on `PATH`, or a standard
  `~/.openclaw/tools/.../openclaw` install), so the bridge can load the Gateway
  client and the device identity.
- Node.js **22.19+** (the bridge exits with a clear message otherwise).
- A running OpenClaw Gateway, local or remote.

## Install

### From GitHub

```bash
omarchy plugin add https://github.com/AlexandrLebegue/omarchy-openclaw --enable
```

The plugin needs its Gateway client dependency. Run once in the installed
directory:

```bash
cd ~/.config/omarchy/plugins/alexandrlebegue.openclaw
npm install --omit=dev
```

Then add it to the bar if it is not there yet:

```bash
omarchy plugin enable alexandrlebegue.openclaw --section right --after local.opencode-go
```

### From a checkout

```bash
git clone https://github.com/AlexandrLebegue/omarchy-openclaw.git
cd omarchy-openclaw
npm install --omit=dev
ln -sfn "$PWD" ~/.config/omarchy/plugins/alexandrlebegue.openclaw
omarchy plugin enable alexandrlebegue.openclaw --section right --after local.opencode-go
```

### First connection / pairing

On first connect the Gateway asks for a one-time device approval. The panel
shows the request ID and the exact command. Approve it on the Gateway host:

```bash
openclaw devices list
openclaw devices approve <requestId>
```

An already paired administrator can also approve it from **Devices** in the
OpenClaw Control UI or mobile app. Then press **Retry** in the panel. The
device token is stored in `~/.local/state/omarchy-openclaw/tokens.json` with
mode `0600`.

## Configuration

The plugin reads the remote gateway from `~/.openclaw/openclaw.json`:

```json
{
  "gateway": {
    "remote": {
      "url": "ws://192.168.1.57:18789",
      "token": "…"
    }
  }
}
```

Settings exposed in the Omarchy plugin settings:

| Setting | Default | Purpose |
| --- | --- | --- |
| `gatewayUrl` | empty | Override `gateway.remote.url`. |
| `gatewayToken` | empty | Override `gateway.remote.token`. Leave empty to use the OpenClaw config. |
| `notifications` | `true` | Notify when an agent finishes. |
| `notifyOnlyWhenClosed` | `false` | Suppress notifications while the panel is open. |
| `maxSessions` | `20` | Number of sessions fetched from the Gateway. |
| `refreshIntervalSec` | `60` | Fallback session refresh; events are the primary path. |
| `nodePath` | `/usr/bin/node` | Node.js binary used by the bridge. |

Per-widget overrides can also be set in `~/.config/omarchy/shell.json`:

```json
{
  "id": "alexandrlebegue.openclaw",
  "notifications": true,
  "maxSessions": 30
}
```

## How it works

| File | Role |
| --- | --- |
| `Service.qml` | One shell-level service per session. Owns the bridge process, connection state, sessions, transcript, unread counters, and notifications. |
| `bridge.mjs` | Node process. Connects to the Gateway with `@openclaw/gateway-client`, subscribes to `sessions.changed`, serves `chat.history` / `chat.send` / `chat.abort`, and prints JSON lines. |
| `Panel.qml` | Bar widget and `KeyboardPanel` chat UI. Binds to the shared service. |
| `TintedIcon.qml` | Masks the OpenClaw SVG with the theme foreground so it stays readable on every theme. |
| `i18n/` | English and French catalogs, following the Omarchy language setting. |

## Troubleshooting

**The bar icon is missing.** Confirm the plugin is enabled and placed:
`omarchy plugin list`, `omarchy bar get alexandrlebegue.openclaw notifications`.
Then restart the shell: `omarchy restart shell`.

**`Cannot find package '@openclaw/gateway-client'`.** Run `npm install --omit=dev`
in the plugin directory. The bridge also falls back to the client bundled with a
local OpenClaw install.

**`Aucun client Gateway OpenClaw trouvé`.** Install OpenClaw locally, set
`OPENCLAW_PACKAGE_ROOT`, or run `npm install`.

**`Token gateway refusé`.** Check `gateway.remote.token` in
`~/.openclaw/openclaw.json`, or set the `gatewayToken` plugin setting.

**Pairing is required.** The panel shows the current request ID. Approve it on
the Gateway host, then press **Retry**. Requests are per device: re-running
`openclaw devices list` shows the current ID if it changed.

Logs:

```bash
journalctl --user -b | grep -i openclaw
```

## Development

```bash
npm install
omarchy plugin validate .
omarchy restart shell
```

The shell hot-reloads plugin QML on save. A full restart is needed when the
manifest or the service entry point changes.

## License

MIT. See [LICENSE](LICENSE).
