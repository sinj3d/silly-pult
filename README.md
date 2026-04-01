# SillyPlut

SillyPlut is a local macOS MVP that routes Notification Center activity and
Chrome distraction signals into a catapult trigger pipeline.

## Components

- `control-panel/`: Next.js dashboard, settings editor, helper lifecycle UI, test tools
- `helper/`: Swift helper that captures notifications, stores state in SQLite, evaluates rules, and drives the host-side activation flow
- `chrome-extension/`: Chrome MV3 extension that posts active-domain updates to the helper
- `firmware/`: protocol contract stub for the embedded catapult controller

## Local development

Run the control panel:

```bash
npm run dev:panel
```

Run the helper directly:

```bash
npm run dev:helper
```

Helper tests:

```bash
npm run test:helper
```

Control panel lint/build:

```bash
npm run lint:panel
npm run build:panel
```

## Chrome extension

Load `chrome-extension/` as an unpacked extension in Chrome. It reports active
tab domains to `http://127.0.0.1:42424/api/browser-activity`, which the helper
uses for focus-mode distraction events.

## Notes

- Live macOS notification capture is best effort and currently keyed off
  `usernotificationsd` create events in the system log.
- Test notifications emit a macOS toast and also mirror into the same helper
  rules pipeline so the demo remains deterministic.
- Local helper data is stored in `.sillyplut-data/`.
