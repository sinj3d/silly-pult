import { ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { copyFile, mkdir, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";

type ManagedHelperState = {
  process?: ChildProcessWithoutNullStreams;
  logs: string[];
  exitCode?: number | null;
};

declare global {
  var __SILLYPULT_HELPER_STATE__: ManagedHelperState | undefined;
}

const helperUrl =
  process.env.SILLYPULT_HELPER_URL ??
  process.env.SILLYPLUT_HELPER_URL ??
  "http://127.0.0.1:42424";
const helperPort = Number(new URL(helperUrl).port || 42424);

function getState(): ManagedHelperState {
  if (!global.__SILLYPULT_HELPER_STATE__) {
    global.__SILLYPULT_HELPER_STATE__ = { logs: [] };
  }

  return global.__SILLYPULT_HELPER_STATE__;
}

function appendLog(line: string) {
  const state = getState();
  state.logs = [line, ...state.logs].slice(0, 50);
}

function helperWorkingDirectory() {
  return path.resolve(process.cwd(), "../helper");
}

function helperDatabasePath() {
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "SillyPult",
    "sillypult.sqlite3",
  );
}

function legacyHelperDatabasePath() {
  return path.resolve(process.cwd(), "../.sillyplut-data/sillyplut.sqlite3");
}

function legacyAppSupportDatabasePath() {
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "SillyPlut",
    "sillyplut.sqlite3",
  );
}

async function fileExists(targetPath: string) {
  try {
    await stat(targetPath);
    return true;
  } catch {
    return false;
  }
}

async function migrateLegacyDatabaseIfNeeded() {
  const targetPath = helperDatabasePath();

  await mkdir(path.dirname(targetPath), { recursive: true });

  if (await fileExists(targetPath)) {
    return;
  }

  const legacyCandidates = [
    legacyAppSupportDatabasePath(),
    legacyHelperDatabasePath(),
  ];

  for (const legacyPath of legacyCandidates) {
    if (!(await fileExists(legacyPath))) {
      continue;
    }

    await copyFile(legacyPath, targetPath);
    appendLog(`migrated helper database from ${legacyPath}`);
    return;
  }
}

export function managedHelperLogs() {
  return getState().logs;
}

export function helperBaseUrl() {
  return helperUrl;
}

export function isManagedHelperRunning() {
  const state = getState();
  return Boolean(state.process && state.exitCode == null);
}

export async function probeHelper() {
  try {
    const response = await fetch(`${helperUrl}/api/status`, {
      cache: "no-store",
    });
    return response.ok;
  } catch {
    return false;
  }
}

export async function startHelper() {
  if (await probeHelper()) {
    appendLog("helper already responding on localhost");
    return true;
  }

  const state = getState();
  if (state.process && state.exitCode == null) {
    return waitForHealthy();
  }

  await migrateLegacyDatabaseIfNeeded();

  const child = spawn("swift", ["run", "SillyPultHelper"], {
    cwd: helperWorkingDirectory(),
    env: {
      ...process.env,
      SILLYPULT_HELPER_PORT: String(helperPort),
      SILLYPULT_DB_PATH: helperDatabasePath(),
    },
    stdio: "pipe",
  });

  state.process = child;
  state.exitCode = null;

  child.stdout.on("data", (chunk) => {
    appendLog(String(chunk).trim());
  });

  child.stderr.on("data", (chunk) => {
    appendLog(String(chunk).trim());
  });

  child.on("exit", (code) => {
    state.exitCode = code;
    state.process = undefined;
    appendLog(`helper exited with code ${code ?? "unknown"}`);
  });

  appendLog("starting helper via swift run");
  return waitForHealthy();
}

export async function stopHelper() {
  const state = getState();
  if (state.process && state.exitCode == null) {
    state.process.kill("SIGTERM");
    await delay(500);
  }
}

async function waitForHealthy() {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    if (await probeHelper()) {
      appendLog("helper is healthy");
      return true;
    }
    await delay(500);
  }

  appendLog("helper failed to become healthy in time");
  return false;
}
