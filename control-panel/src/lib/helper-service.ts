import {
  helperBaseUrl,
  isManagedHelperRunning,
  managedHelperLogs,
  probeHelper,
} from "@/lib/helper-manager";
import {
  defaultSettings,
  emptyDashboard,
  type DashboardSnapshot,
  type HelperStatus,
  type NotificationEvent,
  type OverviewResponse,
  type Settings,
} from "@/lib/types";

async function fetchHelperJson<T>(pathname: string, init?: RequestInit) {
  const response = await fetch(`${helperBaseUrl()}${pathname}`, {
    ...init,
    cache: "no-store",
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });

  if (!response.ok) {
    throw new Error(`helper request failed: ${pathname}`);
  }

  return (await response.json()) as T;
}

export async function readOverview(): Promise<OverviewResponse> {
  const available = await probeHelper();
  const managed = isManagedHelperRunning();

  if (!available) {
    return {
      available: false,
      managed,
      helperUrl: helperBaseUrl(),
      logs: managedHelperLogs(),
      settings: defaultSettings,
      events: [],
      dashboard: emptyDashboard,
    };
  }

  const [status, dashboard, settings, events] = await Promise.all([
    fetchHelperJson<HelperStatus>("/api/status"),
    fetchHelperJson<DashboardSnapshot>("/api/dashboard"),
    fetchHelperJson<Settings>("/api/settings"),
    fetchHelperJson<NotificationEvent[]>("/api/events?limit=25"),
  ]);

  return {
    available: true,
    managed,
    helperUrl: helperBaseUrl(),
    logs: managedHelperLogs(),
    status,
    dashboard,
    settings,
    events,
  };
}

export async function writeSettings(settings: Settings) {
  return fetchHelperJson<Settings>("/api/settings", {
    method: "PUT",
    body: JSON.stringify({ settings }),
  });
}

export async function sendTestNotification(variant: "allowed-work" | "ignored-nonwork") {
  return fetchHelperJson<NotificationEvent>("/api/test-notification", {
    method: "POST",
    body: JSON.stringify({ variant }),
  });
}
