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

- **Official OpenClaw logo** in the bar, the panel header, and desktop
  notifications, tinted to the active Omarchy theme.
- **One bar icon** with gateway status, active-run pulse, and unread badge.
- **Native Omarchy panel**: agent/session list, transcript, send, and stop.
- **Agent identity**: the gateway's agent name and avatar (or emoji/initial
  fallback) are shown in the conversation list and chat header. The list puts
  the agent name first and the conversation preview underneath.
- **Transcript stays at the bottom**: opening a conversation starts on the
  latest message, new messages stay in view, and a themed scrollbar lives in
  its own gutter so it never overlaps the text.
- **Desktop notifications** through `omarchy notification send` when any agent
  finishes. The toast uses the agent's avatar/emoji (falling back to the
  OpenClaw logo), keeps the title as **OpenClaw**, and shows the agent reply
  underneath. Notifications are only shown while the panel is closed; clicking
  one opens the panel.
- **Full keyboard control**: Tab between agents, transcript, and composer;
  ↑/↓ to move between discussions; Enter to open one; `n` to toggle
  notifications; F1 for the shortcut sheet; `s` for settings.
- **Notification toggle** next to the settings gear, mirrored by the `n` key.
- **Main-conversation filter**: optionally show and notify only the main
  conversation of each agent.
- **One shared gateway connection** for every monitor: the plugin is a shell
  service, so the bridge runs once even when the bar exists on several outputs.
- **Uses your existing OpenClaw credentials**: gateway URL and token are read
  from `~/.openclaw/openclaw.json`; no copy/paste needed.
- **Reuses the OpenClaw device identity** from the local state database, so
  approving one device also unblocks the CLI.
- **No polling for chat**: `sessions.subscribe` and session message events drive
  the UI; a fallback refresh keeps it honest after reconnects.
- **English and French** catalogs, following Omarchy's language setting.

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

## Keyboard

Open the panel with a left click on the bar icon, or right click to open it
ready to type. The panel is fully usable without the mouse:

| Key | Action |
| --- | --- |
| `Tab` / `Shift+Tab` | Move between agents, transcript, and message composer |
| `↑` / `↓` | Move between discussions (the transcript follows) or scroll the transcript |
| `Enter` | Open the selected discussion and focus the composer |
| `i` | Focus the composer |
| `r` | Refresh sessions |
| `n` | Toggle desktop notifications |
| `x` | Stop the active agent |
| `s` or `,` | Open settings |
| `F1` or `?` | Open the shortcut sheet |
| `Esc` | Close settings/help, then the panel |

Settings can be changed with `↑`/`↓` and `Enter`; they are written back to
`~/.config/omarchy/shell.json` immediately.

### Global shortcut

Add this to `~/.config/hypr/bindings.lua` to open or close OpenClaw from
anywhere:

```lua
o.bind("SUPER + ALT + O", "OpenClaw", "omarchy-shell alexandrlebegue.openclaw toggle")
```

Then reload Hyprland (`hyprctl reload`). The shortcut sheet (`F1`) lists it.

## Configuration

The plugin reads the remote gateway from `~/.openclaw/openclaw.json` (use your
LAN, Tailscale, or loopback URL):

```json
{
  "gateway": {
    "remote": {
      "url": "ws://127.0.0.1:18789",
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
| `notifications` | `true` | Notify when an agent finishes (only while the panel is closed). |
| `mainConversationsOnly` | `false` | Show and notify only the main conversation of each agent. |
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
| `Service.qml` | One shell-level service per session. Owns the bridge process, connection state, sessions, transcript, unread counters, notifications, and the notification icon install. |
| `bridge.mjs` | Node process. Connects to the Gateway with `@openclaw/gateway-client`, subscribes to `sessions.changed`, serves `chat.history` / `chat.send` / `chat.abort`, and prints JSON lines. |
| `Panel.qml` | Bar widget and `KeyboardPanel` chat UI, plus the settings and shortcut overlays. Binds to the shared service. |
| `FocusCatcher.qml` | Keyboard dispatcher for Tab, arrows, Enter, F1, Escape, and the single-key actions. |
| `TintedIcon.qml` | Masks the official OpenClaw PNG with the theme foreground so it stays readable on every theme. |
| `install-icon.sh` | Installs the logo into the user hicolor icon theme so notifications can use `-i openclaw`. |
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

The MIT license covers the plugin code. The OpenClaw name and logo belong to
the OpenClaw project; the logo asset is included for identification only.
