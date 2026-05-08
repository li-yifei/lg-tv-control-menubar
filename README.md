# LG TV Control

Small macOS menu bar app and CLI for controlling an LG webOS TV.

The app talks to the TV directly from Swift over the webOS WebSocket API. Pairing credentials (client key, IP control keycode) are stored in macOS Keychain under the `com.lgtv-control` service. Non-secret config (host, MAC addresses) stays in a JSON file. `Pair / Re-pair` can trigger the TV authorization prompt and save or refresh the client key.

Default config path:

```sh
~/.config/lgtv-pairing.json
```

Secrets found in the JSON file are automatically migrated to Keychain on first load.

See `examples/lgtv-pairing.example.json` for the expected shape.

Build:

```sh
./build.sh
```

Run:

```sh
open "build/LG TV Control.app"
```

Install the CLI from Settings:

```sh
open "build/LG TV Control.app" --args --show-settings
```

The Settings window can install or uninstall `~/.local/bin/lgtv`. The build also writes a copy to `build/bin/lgtv` for manual installation:

```sh
mkdir -p ~/.local/bin
cp build/bin/lgtv ~/.local/bin/lgtv
```

CLI:

```sh
lgtv --help
lgtv status --json
lgtv volume set 12
lgtv volume up --steps 3
lgtv mute toggle
lgtv power on
lgtv input list
lgtv input switch HDMI_2
lgtv raw ssap://audio/getVolume --json
```

The CLI is a standalone terminal entry point. It reads `LG_TV_CONFIG` first, then the default config file. Individual commands can override it with `--config PATH`. Data commands write machine-readable output to stdout with `--json`; failures write to stderr and exit non-zero.

Supported controls:

- refresh current volume and mute state
- volume up
- volume down
- mute toggle
- set volume with a slider
- power on/off
- settings window for menu shortcuts and safety volume reminder
- App Intents for Shortcuts and Siri: power, volume, mute, and input switching
- structured CLI for third-party calls and Shortcuts shell actions

Release hygiene:

- Keep `build/`, `.build/`, and `.DS_Store` out of Git.
- Keep pairing JSON files and copied CLI binaries out of Git.
- Review `git grep` output before publishing.
