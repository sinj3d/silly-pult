export type FocusWindow = {
  id: string;
  label: string;
  enabled: boolean;
  daysOfWeek: number[];
  startMinutes: number;
  endMinutes: number;
};

export type Settings = {
  focusWindows: FocusWindow[];
  workAppAllowlist: string[];
  distractionDomainDenylist: string[];
  cooldownSeconds: number;
  distractionThresholdSeconds: number;
};

export type NotificationEvent = {
  id: string;
  receivedAt: string;
  sourceApp: string;
  title?: string | null;
  body?: string | null;
  isTest: boolean;
  classification: "allowed" | "ignored" | "distraction" | "unknown";
  triggerReason: "notification" | "distraction";
  actionTaken:
    | "activated"
    | "ignored"
    | "suppressed_busy"
    | "suppressed_cooldown"
    | "failed";
  metadata: Record<string, string>;
};

export type DashboardSnapshot = {
  detectedNotifications: number;
  activatedNotifications: number;
  ignoredNotifications: number;
  focusFilteredNotifications: number;
  distractionEvents: number;
  distractionRate: number;
  focusModeActive: boolean;
  operatingMode: "all_notifications" | "focus_filtered";
};

export type HelperStatus = {
  helperStartedAt: string;
  notificationMonitorRunning: boolean;
  firmwareBusy: boolean;
  lastActivationResult?: NotificationEvent["actionTaken"] | null;
  lastDetectedAt?: string | null;
  currentBrowserDomain?: string | null;
  databasePath: string;
  helperPid: number;
  captureMode: string;
  operatingMode: "all_notifications" | "focus_filtered";
  firmwareTarget: string;
  lastError?: string | null;
};

export type OverviewResponse = {
  available: boolean;
  managed: boolean;
  helperUrl: string;
  logs: string[];
  settings: Settings;
  events: NotificationEvent[];
  dashboard: DashboardSnapshot;
  status?: HelperStatus;
};

export const defaultSettings: Settings = {
  focusWindows: [],
  workAppAllowlist: ["Slack", "Mail", "Calendar", "Messages", "Teams"],
  distractionDomainDenylist: [
    "instagram.com",
    "www.instagram.com",
    "coolmathgames.com",
    "www.coolmathgames.com",
  ],
  cooldownSeconds: 30,
  distractionThresholdSeconds: 20,
};

export const emptyDashboard: DashboardSnapshot = {
  detectedNotifications: 0,
  activatedNotifications: 0,
  ignoredNotifications: 0,
  focusFilteredNotifications: 0,
  distractionEvents: 0,
  distractionRate: 0,
  focusModeActive: false,
  operatingMode: "all_notifications",
};
