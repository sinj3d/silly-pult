# SillyPult Control Panel

Next.js dashboard for starting the local helper, viewing helper and firmware
state, editing settings, and sending test notifications through the normal
notification pipeline.

## Development

Run the panel from the repo root:

```bash
npm run dev:panel
```

The panel talks to the local helper at `http://127.0.0.1:42424` by default.
When you use the built-in "Start Helper" action, the spawned helper process
inherits these firmware settings from the panel server environment:

```bash
export SILLYPULT_FIRMWARE_HOST=192.168.1.50
export SILLYPULT_FIRMWARE_PORT=80
export SILLYPULT_FIRMWARE_TIMEOUT_SECONDS=30
```

If `SILLYPULT_FIRMWARE_HOST` is unset, the dashboard will show the firmware
target as `unconfigured` and catapult activations will fail until the static
device IP is configured.
