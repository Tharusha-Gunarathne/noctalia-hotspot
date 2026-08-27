# noctalia-hotspot

A [Noctalia](https://noctalia.dev) plugin for a declarative NixOS access point
that runs *alongside* the existing Wi-Fi connection.

Unlike the community `cleboost/hotspot` plugin, this one does not drive
NetworkManager. It wraps `hostapd` + `dnsmasq` on a virtual `ap0` interface, so
the station connection is never torn down. The access point borrows the
station's channel, which single-radio Intel adapters require.

The plugin is the front end only. The CLI tools it calls come from the NixOS
module described under [NixOS module](#nixos-module).

## Contents

```
hotspot/            the plugin itself
  plugin.toml       manifest: settings, widget, shortcut, panel, service
  service.luau      polls hotspot-status --json, drives start/stop via sudo
  widget.luau       bar widget
  shortcut.luau     Control Center toggle
  panel.luau        status, uplink, client list
  translations/     en.json
```

See [`hotspot/README.md`](hotspot/README.md) for settings, IPC and usage.

## Install

### Nix (flake input)

```nix
# flake.nix
inputs.noctaliaHotspot = {
  url = "github:tharusha-gunarathne/noctalia-hotspot";
  flake = false;
};
```

```nix
# a NixOS/home-manager module
home.file.".local/share/noctalia/plugins/hotspot" = {
  source = "${inputs.noctaliaHotspot}/hotspot";
  recursive = true;
};
```

`flake = false` keeps this repo a plain source tree: no `flake.nix`, no
`flake.lock`, and no transitive `nixpkgs` to diverge from a binary cache.

Then enable **Hotspot** in Settings → Plugins.

### Manually

```sh
git clone https://github.com/tharusha-gunarathne/noctalia-hotspot
cp -r noctalia-hotspot/hotspot ~/.local/share/noctalia/plugins/hotspot
```

## NixOS module

The plugin needs `start-hotspot`, `stop-hotspot`, `hotspot-reset` and
`hotspot-status` on `PATH`, with the first three authorised NOPASSWD. All four
are produced by `modules/features/services/hotspot.nix` in the companion NixOS
configuration.

`hotspot-status --json` is the contract between the two halves:

```json
{
  "available": true,
  "active": true,
  "ssid": "MyHotspot",
  "ap_interface": "ap0",
  "sta_interface": "wlan0",
  "channel": 36,
  "gateway": "10.42.0.1",
  "uplink": { "connected": true, "ssid": "HomeNet", "channel": 36 },
  "clients": [{ "mac": "3c:22:...", "ip": "10.42.0.23", "signal": -45 }],
  "error": ""
}
```

It is read-only and unprivileged, so the poll loop never touches sudo.

## Development

Point the input at a working copy instead of GitHub:

```sh
sudo nixos-rebuild switch --flake 'path:.#nixos' \
  --override-input noctaliaHotspot path:/home/tharusha-gunarathne/dev/noctalia-hotspot
```

Pull in upstream changes once pushed:

```sh
nix flake update noctaliaHotspot
```

Check syntax before committing:

```sh
luau-compile --binary hotspot/*.luau
```

## Conventions

- Colours are palette role tokens (`primary`, `tertiary`, `error`,
  `surface_variant/0.35`), never hex, so the UI tracks theme and light/dark
  changes with no plugin involvement.
- User-visible strings live in `translations/en.json`; nothing is hardcoded in
  the Luau.
- The plugin makes no network requests and writes nothing to disk. Settings
  persist to Noctalia's state dir, so the plugin directory can be read-only —
  which it is, under Nix.

## Licence

MIT. See [LICENSE](LICENSE).
