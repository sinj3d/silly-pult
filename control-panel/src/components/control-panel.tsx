"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  defaultSettings,
  emptyDashboard,
  type FocusWindow,
  type NotificationEvent,
  type OverviewResponse,
  type Settings,
} from "@/lib/types";

const weekdays = [
  { label: "S", value: 1 },
  { label: "M", value: 2 },
  { label: "T", value: 3 },
  { label: "W", value: 4 },
  { label: "T", value: 5 },
  { label: "F", value: 6 },
  { label: "S", value: 7 },
];

function minutesToTime(value: number) {
  const hours = Math.floor(value / 60)
    .toString()
    .padStart(2, "0");
  const minutes = (value % 60).toString().padStart(2, "0");
  return `${hours}:${minutes}`;
}

function timeToMinutes(value: string) {
  const [hours = "0", minutes = "0"] = value.split(":");
  return Number(hours) * 60 + Number(minutes);
}

function classificationTone(event: NotificationEvent) {
  switch (event.classification) {
    case "allowed":
      return "text-emerald-200";
    case "ignored":
      return "text-amber-200";
    case "distraction":
      return "text-rose-200";
    default:
      return "text-slate-300";
  }
}

export function ControlPanel() {
  const [overview, setOverview] = useState<OverviewResponse>({
    available: false,
    managed: false,
    helperUrl: "http://127.0.0.1:42424",
    logs: [],
    settings: defaultSettings,
    events: [],
    dashboard: emptyDashboard,
  });
  const [settings, setSettings] = useState<Settings>(defaultSettings);
  const [dirty, setDirty] = useState(false);
  const [actionState, setActionState] = useState<string>("idle");
  const [error, setError] = useState<string>("");

  const refreshOverview = useCallback(async () => {
    const response = await fetch("/api/overview", { cache: "no-store" });
    const payload = (await response.json()) as OverviewResponse;
    setOverview(payload);
    setSettings((current) => (dirty ? current : payload.settings));
  }, [dirty]);

  useEffect(() => {
    void refreshOverview();
    const timer = window.setInterval(() => {
      void refreshOverview();
    }, 3000);

    return () => window.clearInterval(timer);
  }, [refreshOverview]);

  const eventSummary = useMemo(() => {
    if (overview.events.length === 0) {
      return "No events yet";
    }

    return `${overview.events.length} recent events`;
  }, [overview.events.length]);

  async function lifecycle(action: "start" | "stop") {
    setActionState(action);
    setError("");

    try {
      const response = await fetch("/api/helper/lifecycle", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action }),
      });

      const payload = (await response.json()) as { overview: OverviewResponse };
      setOverview(payload.overview);
      if (!dirty) {
        setSettings(payload.overview.settings);
      }
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : "Lifecycle action failed",
      );
    } finally {
      setActionState("idle");
    }
  }

  async function saveSettings() {
    setActionState("save");
    setError("");

    try {
      const response = await fetch("/api/settings", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ settings }),
      });

      if (!response.ok) {
        throw new Error("Could not save settings");
      }

      await refreshOverview();
      setDirty(false);
    } catch (caughtError) {
      setError(
        caughtError instanceof Error ? caughtError.message : "Save failed",
      );
    } finally {
      setActionState("idle");
    }
  }

  async function sendTest(variant: "allowed-work" | "ignored-nonwork") {
    setActionState(variant);
    setError("");

    try {
      const response = await fetch("/api/test-notification", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ variant }),
      });

      if (!response.ok) {
        throw new Error("Could not send test notification");
      }

      await refreshOverview();
    } catch (caughtError) {
      setError(
        caughtError instanceof Error ? caughtError.message : "Test failed",
      );
    } finally {
      setActionState("idle");
    }
  }

  function updateWindow(windowId: string, updater: (window: FocusWindow) => FocusWindow) {
    setDirty(true);
    setSettings((current) => ({
      ...current,
      focusWindows: current.focusWindows.map((window) =>
        window.id === windowId ? updater(window) : window,
      ),
    }));
  }

  function addWindow() {
    setDirty(true);
    setSettings((current) => ({
      ...current,
      focusWindows: [
        ...current.focusWindows,
        {
          id: crypto.randomUUID(),
          label: "New Window",
          enabled: true,
          daysOfWeek: [2, 3, 4, 5, 6],
          startMinutes: 9 * 60,
          endMinutes: 17 * 60,
        },
      ],
    }));
  }

  function removeWindow(windowId: string) {
    setDirty(true);
    setSettings((current) => ({
      ...current,
      focusWindows: current.focusWindows.filter((window) => window.id !== windowId),
    }));
  }

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-7xl flex-col gap-6 px-4 py-6 sm:px-8">
      <section className="grid gap-4 rounded-[2rem] border border-white/10 bg-slate-950/90 p-6 shadow-[0_30px_90px_rgba(15,23,42,0.45)] backdrop-blur sm:grid-cols-[1.5fr_1fr]">
        <div className="space-y-4">
          <p className="text-xs uppercase tracking-[0.35em] text-cyan-300/80">
            SillyPlut Control Panel
          </p>
          <h1 className="max-w-2xl text-4xl font-semibold tracking-tight text-white sm:text-5xl">
            Route real macOS notifications and Chrome distractions into catapult
            events.
          </h1>
          <p className="max-w-2xl text-sm leading-7 text-slate-300">
            The helper uses best-effort macOS system-log capture for live
            notifications. Test notifications still emit a visible macOS toast,
            then mirror into the same rules pipeline so the demo stays reliable.
          </p>
        </div>
        <div className="grid gap-3 rounded-[1.5rem] border border-cyan-400/20 bg-cyan-400/8 p-4 text-sm text-cyan-50">
          <div>
            <div className="text-xs uppercase tracking-[0.24em] text-cyan-200/70">
              Helper
            </div>
            <div className="mt-1 text-lg font-medium">
              {overview.available ? "Online" : "Offline"}
            </div>
            <div className="text-cyan-100/70">{overview.helperUrl}</div>
          </div>
          <div className="grid grid-cols-2 gap-3">
            <button
              className="rounded-full bg-cyan-300 px-4 py-2 font-medium text-slate-950 transition hover:bg-cyan-200 disabled:cursor-not-allowed disabled:opacity-60"
              disabled={actionState !== "idle"}
              onClick={() => lifecycle("start")}
              type="button"
            >
              {actionState === "start" ? "Starting..." : "Start Helper"}
            </button>
            <button
              className="rounded-full border border-white/15 px-4 py-2 font-medium text-white transition hover:bg-white/8 disabled:cursor-not-allowed disabled:opacity-60"
              disabled={actionState !== "idle"}
              onClick={() => lifecycle("stop")}
              type="button"
            >
              {actionState === "stop" ? "Stopping..." : "Stop Helper"}
            </button>
          </div>
          <div className="grid gap-2 text-xs text-cyan-100/75">
            <div>
              Focus mode:{" "}
              {overview.dashboard.focusModeActive ? "active now" : "inactive"}
            </div>
            <div>
              Capture: {overview.status?.captureMode ?? "best_effort_system_log"}
            </div>
            <div>Chrome domain: {overview.status?.currentBrowserDomain ?? "none"}</div>
          </div>
        </div>
      </section>

      {error ? (
        <div className="rounded-2xl border border-rose-400/30 bg-rose-400/10 px-4 py-3 text-sm text-rose-100">
          {error}
        </div>
      ) : null}

      <section className="grid gap-4 md:grid-cols-4">
        {[
          {
            label: "Detected",
            value: overview.dashboard.totalNotifications,
            accent: "from-cyan-400/50 to-cyan-300/0",
          },
          {
            label: "Focused / Allowed",
            value: overview.dashboard.focusedNotifications,
            accent: "from-emerald-400/50 to-emerald-300/0",
          },
          {
            label: "Ignored",
            value: overview.dashboard.ignoredNotifications,
            accent: "from-amber-400/50 to-amber-300/0",
          },
          {
            label: "Distractions",
            value: overview.dashboard.distractionEvents,
            accent: "from-rose-400/50 to-rose-300/0",
          },
        ].map((card) => (
          <article
            className="relative overflow-hidden rounded-[1.6rem] border border-white/8 bg-slate-900 p-5 text-white"
            key={card.label}
          >
            <div
              className={`pointer-events-none absolute inset-0 bg-linear-to-br ${card.accent}`}
            />
            <div className="relative">
              <div className="text-xs uppercase tracking-[0.25em] text-slate-300">
                {card.label}
              </div>
              <div className="mt-4 text-4xl font-semibold">{card.value}</div>
            </div>
          </article>
        ))}
      </section>

      <section className="grid gap-4 lg:grid-cols-[1.25fr_0.75fr]">
        <article className="rounded-[1.8rem] border border-white/8 bg-slate-900 px-5 py-4 text-white">
          <div className="flex items-center justify-between gap-4">
            <div>
              <div className="text-xs uppercase tracking-[0.3em] text-slate-400">
                Event Log
              </div>
              <h2 className="mt-2 text-2xl font-semibold">{eventSummary}</h2>
            </div>
            <div className="text-right text-sm text-slate-400">
              <div>
                Distraction rate: {(overview.dashboard.distractionRate * 100).toFixed(0)}%
              </div>
              <div>
                Last activation: {overview.status?.lastActivationResult ?? "none"}
              </div>
            </div>
          </div>

          <div className="mt-4 grid gap-3">
            {overview.events.length === 0 ? (
              <div className="rounded-2xl border border-dashed border-white/10 px-4 py-6 text-sm text-slate-400">
                Start the helper and send a test notification to populate the
                timeline.
              </div>
            ) : null}

            {overview.events.map((event) => (
              <div
                className="grid gap-2 rounded-2xl border border-white/6 bg-white/3 px-4 py-3"
                key={event.id}
              >
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <div className="font-medium text-white">{event.sourceApp}</div>
                  <div className={`text-sm ${classificationTone(event)}`}>
                    {event.classification} / {event.actionTaken}
                  </div>
                </div>
                <div className="text-sm text-slate-300">
                  {event.title ?? "Notification captured"}
                </div>
                <div className="flex flex-wrap items-center gap-3 text-xs text-slate-400">
                  <span>{new Date(event.receivedAt).toLocaleString()}</span>
                  <span>{event.triggerReason}</span>
                  {event.isTest ? <span>test</span> : null}
                  {event.metadata.bundleID ? <span>{event.metadata.bundleID}</span> : null}
                  {event.metadata.domain ? <span>{event.metadata.domain}</span> : null}
                </div>
              </div>
            ))}
          </div>
        </article>

        <article className="grid gap-4 rounded-[1.8rem] border border-white/8 bg-slate-900 p-5 text-white">
          <div>
            <div className="text-xs uppercase tracking-[0.3em] text-slate-400">
              Demo Tools
            </div>
            <h2 className="mt-2 text-2xl font-semibold">Test the pipeline</h2>
          </div>

          <div className="grid gap-3">
            <button
              className="rounded-[1.2rem] bg-emerald-300 px-4 py-3 text-left font-medium text-slate-950 transition hover:bg-emerald-200 disabled:cursor-not-allowed disabled:opacity-60"
              disabled={!overview.available || actionState !== "idle"}
              onClick={() => sendTest("allowed-work")}
              type="button"
            >
              Send allowed work notification
            </button>
            <button
              className="rounded-[1.2rem] bg-amber-300 px-4 py-3 text-left font-medium text-slate-950 transition hover:bg-amber-200 disabled:cursor-not-allowed disabled:opacity-60"
              disabled={!overview.available || actionState !== "idle"}
              onClick={() => sendTest("ignored-nonwork")}
              type="button"
            >
              Send ignored non-work notification
            </button>
          </div>

          <div className="rounded-[1.4rem] border border-white/8 bg-slate-950/70 px-4 py-3 text-sm text-slate-300">
            <div className="font-medium text-white">Helper state</div>
            <div className="mt-2 grid gap-1">
              <div>Notification monitor: {overview.status?.notificationMonitorRunning ? "running" : "stopped"}</div>
              <div>Firmware busy: {overview.status?.firmwareBusy ? "yes" : "no"}</div>
              <div>Last detected: {overview.status?.lastDetectedAt ? new Date(overview.status.lastDetectedAt).toLocaleString() : "none"}</div>
            </div>
          </div>

          <div className="rounded-[1.4rem] border border-white/8 bg-slate-950/70 px-4 py-3 text-sm text-slate-300">
            <div className="font-medium text-white">Managed helper logs</div>
            <div className="mt-2 grid max-h-56 gap-2 overflow-y-auto text-xs leading-5">
              {overview.logs.length === 0 ? (
                <div className="text-slate-500">No local process logs yet.</div>
              ) : null}
              {overview.logs.map((line, index) => (
                <pre className="whitespace-pre-wrap text-slate-300" key={`${line}-${index}`}>
                  {line}
                </pre>
              ))}
            </div>
          </div>
        </article>
      </section>

      <section className="grid gap-4 rounded-[1.8rem] border border-white/8 bg-slate-900 p-5 text-white">
        <div className="flex flex-wrap items-center justify-between gap-4">
          <div>
            <div className="text-xs uppercase tracking-[0.3em] text-slate-400">
              Rules
            </div>
            <h2 className="mt-2 text-2xl font-semibold">Focus and distraction configuration</h2>
          </div>
          <button
            className="rounded-full bg-white px-4 py-2 text-sm font-medium text-slate-950 transition hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-60"
            disabled={!overview.available || actionState !== "idle"}
            onClick={saveSettings}
            type="button"
          >
            {actionState === "save" ? "Saving..." : dirty ? "Save changes" : "Settings saved"}
          </button>
        </div>

        <div className="grid gap-4 xl:grid-cols-[1.1fr_0.9fr]">
          <div className="grid gap-4">
            <label className="grid gap-2 text-sm text-slate-300">
              Work app allowlist
              <textarea
                className="min-h-28 rounded-[1.2rem] border border-white/10 bg-slate-950/70 px-4 py-3 text-sm text-white outline-none transition focus:border-cyan-300"
                onChange={(event) => {
                  setDirty(true);
                  setSettings((current) => ({
                    ...current,
                    workAppAllowlist: event.target.value
                      .split("\n")
                      .map((value) => value.trim())
                      .filter(Boolean),
                  }));
                }}
                value={settings.workAppAllowlist.join("\n")}
              />
            </label>

            <label className="grid gap-2 text-sm text-slate-300">
              Chrome distraction denylist
              <textarea
                className="min-h-28 rounded-[1.2rem] border border-white/10 bg-slate-950/70 px-4 py-3 text-sm text-white outline-none transition focus:border-cyan-300"
                onChange={(event) => {
                  setDirty(true);
                  setSettings((current) => ({
                    ...current,
                    distractionDomainDenylist: event.target.value
                      .split("\n")
                      .map((value) => value.trim())
                      .filter(Boolean),
                  }));
                }}
                value={settings.distractionDomainDenylist.join("\n")}
              />
            </label>
          </div>

          <div className="grid gap-4">
            <div className="grid gap-4 rounded-[1.4rem] border border-white/8 bg-slate-950/70 p-4">
              <label className="grid gap-2 text-sm text-slate-300">
                Cooldown seconds
                <input
                  className="rounded-xl border border-white/10 bg-slate-900 px-3 py-2 text-white outline-none transition focus:border-cyan-300"
                  min={1}
                  onChange={(event) => {
                    setDirty(true);
                    setSettings((current) => ({
                      ...current,
                      cooldownSeconds: Number(event.target.value),
                    }));
                  }}
                  type="number"
                  value={settings.cooldownSeconds}
                />
              </label>
              <label className="grid gap-2 text-sm text-slate-300">
                Distraction threshold seconds
                <input
                  className="rounded-xl border border-white/10 bg-slate-900 px-3 py-2 text-white outline-none transition focus:border-cyan-300"
                  min={5}
                  onChange={(event) => {
                    setDirty(true);
                    setSettings((current) => ({
                      ...current,
                      distractionThresholdSeconds: Number(event.target.value),
                    }));
                  }}
                  type="number"
                  value={settings.distractionThresholdSeconds}
                />
              </label>
            </div>

            <div className="rounded-[1.4rem] border border-white/8 bg-slate-950/70 p-4">
              <div className="flex items-center justify-between gap-4">
                <div>
                  <div className="text-sm font-medium text-white">Focus windows</div>
                  <div className="text-xs text-slate-400">
                    Notifications always fire outside focus. During focus, only
                    allowlisted work apps and denylisted distractions can trigger.
                  </div>
                </div>
                <button
                  className="rounded-full border border-white/12 px-3 py-1 text-sm text-white transition hover:bg-white/8"
                  onClick={addWindow}
                  type="button"
                >
                  Add window
                </button>
              </div>

              <div className="mt-4 grid gap-3">
                {settings.focusWindows.map((window) => (
                  <div
                    className="grid gap-3 rounded-[1.2rem] border border-white/10 bg-slate-900 p-4"
                    key={window.id}
                  >
                    <div className="grid gap-3 sm:grid-cols-[1fr_auto]">
                      <label className="grid gap-2 text-sm text-slate-300">
                        Label
                        <input
                          className="rounded-xl border border-white/10 bg-slate-950 px-3 py-2 text-white outline-none transition focus:border-cyan-300"
                          onChange={(event) =>
                            updateWindow(window.id, (current) => ({
                              ...current,
                              label: event.target.value,
                            }))
                          }
                          value={window.label}
                        />
                      </label>
                      <button
                        className="self-end rounded-full border border-rose-300/30 px-3 py-2 text-sm text-rose-200 transition hover:bg-rose-300/10"
                        onClick={() => removeWindow(window.id)}
                        type="button"
                      >
                        Remove
                      </button>
                    </div>

                    <div className="grid gap-3 sm:grid-cols-3">
                      <label className="grid gap-2 text-sm text-slate-300">
                        Start
                        <input
                          className="rounded-xl border border-white/10 bg-slate-950 px-3 py-2 text-white outline-none transition focus:border-cyan-300"
                          onChange={(event) =>
                            updateWindow(window.id, (current) => ({
                              ...current,
                              startMinutes: timeToMinutes(event.target.value),
                            }))
                          }
                          type="time"
                          value={minutesToTime(window.startMinutes)}
                        />
                      </label>
                      <label className="grid gap-2 text-sm text-slate-300">
                        End
                        <input
                          className="rounded-xl border border-white/10 bg-slate-950 px-3 py-2 text-white outline-none transition focus:border-cyan-300"
                          onChange={(event) =>
                            updateWindow(window.id, (current) => ({
                              ...current,
                              endMinutes: timeToMinutes(event.target.value),
                            }))
                          }
                          type="time"
                          value={minutesToTime(window.endMinutes)}
                        />
                      </label>
                      <label className="flex items-end gap-2 text-sm text-slate-300">
                        <input
                          checked={window.enabled}
                          className="mt-1 h-4 w-4 accent-cyan-300"
                          onChange={(event) =>
                            updateWindow(window.id, (current) => ({
                              ...current,
                              enabled: event.target.checked,
                            }))
                          }
                          type="checkbox"
                        />
                        Enabled
                      </label>
                    </div>

                    <div className="flex flex-wrap gap-2">
                      {weekdays.map((day) => {
                        const active = window.daysOfWeek.includes(day.value);
                        return (
                          <button
                            className={`flex h-10 w-10 items-center justify-center rounded-full text-sm font-medium transition ${
                              active
                                ? "bg-cyan-300 text-slate-950"
                                : "border border-white/10 bg-slate-950 text-slate-300 hover:bg-white/6"
                            }`}
                            key={`${window.id}-${day.value}`}
                            onClick={() =>
                              updateWindow(window.id, (current) => ({
                                ...current,
                                daysOfWeek: active
                                  ? current.daysOfWeek.filter((value) => value !== day.value)
                                  : [...current.daysOfWeek, day.value].sort((left, right) => left - right),
                              }))
                            }
                            type="button"
                          >
                            {day.label}
                          </button>
                        );
                      })}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      </section>
    </main>
  );
}
