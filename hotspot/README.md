# Hotspot

Start and stop the declarative NixOS AP+STA hotspot from the bar, inspect the
uplink and connected devices in a panel, and control it over IPC.

Unlike the community `cleboost/hotspot` plugin, this one does **not** drive
NetworkManager. It wraps the CLI tools produced by
`modules/features/services/hotspot.nix`, which run `hostapd` + `dnsmasq` on a
virtual `ap0` interface alongside the existing station connection. The Wi-Fi
connection is never torn down.

## Plugin

| Field | Value |
| --- | --- |
| ID | `tharusha-gunarathne/hotspot` |
| Entries | Bar widget: `toggle`; shortcut: `cc-toggle`; panel: `panel`; service: `hotspot` |

## Requirements

`start-hotspot`, `stop-hotspot`, `hotspot-reset` and `hotspot-status` on
`PATH`, with the first three authorised NOPASSWD in `security.sudo.extraRules`.
All of this comes from the `hotspot` NixOS module; there is nothing to install
by hand.

The access point borrows the station interface's channel, so the hotspot can
only be started while the machine is connected to Wi-Fi. The plugin surfaces
this as a first-class state rather than letting the start attempt fail.

## Usage

1. Add the `toggle` widget to a bar and/or the `cc-toggle` shortcut in
   Settings → Control Center.
2. Left-click the bar widget to open the panel.
3. Right-click the bar widget, or click the Control Center shortcut, to start
   or stop. Middle-click forces a refresh.

```sh
noctalia msg panel-toggle tharusha-gunarathne/hotspot:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `ssid` | `string` | *(empty)* | Network name override. Empty uses the value from `.env.local`. |
| `password` | `string` | *(empty)* | Password override. Empty uses the value from `.env.local`. |
| `open_network` | `bool` | `false` | Start an open network. Overrides `password`. |
| `ap_interface` | `string` | `ap0` | Virtual AP interface, matching `apIface` in `hotspot.nix`. |
| `refresh_interval` | `int` | `5` | Seconds between status refreshes. |

Leaving `ssid` and `password` empty is the recommended configuration. The
credentials then stay in `.env.local` and never reach Noctalia's config or a
process command line.

An open network is never implicit. If `[hotspot].password` in `.env.local` is
empty and no password override is set here, starting the hotspot fails with a
clear message instead of broadcasting unencrypted — turn on `open_network` to
do that deliberately.

## IPC

```sh
noctalia msg plugin tharusha-gunarathne/hotspot:hotspot all enable
noctalia msg plugin tharusha-gunarathne/hotspot:hotspot all disable
noctalia msg plugin tharusha-gunarathne/hotspot:hotspot all toggle
noctalia msg plugin tharusha-gunarathne/hotspot:hotspot all reset
noctalia msg plugin tharusha-gunarathne/hotspot:hotspot all refresh
```

`enable`, `disable`, `toggle` and `reset` change state. `refresh` and `status`
re-read without changing anything. IPC events take no payload.

## Notes

- All state comes from one call to `hotspot-status --json`, which is read-only
  and unprivileged, so the poll loop never touches sudo.
- Mutations go through `sudo -n`, which fails loudly instead of prompting; the
  plugin translates that failure into an actionable message.
- Every colour is a palette role token, so the panel restyles itself when the
  theme or light/dark mode changes.
- The plugin makes no network requests and writes nothing to disk.
