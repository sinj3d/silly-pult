/*
 * Silly-Pult Firmware
 * --------------------
 * Catapult controller for the Freenove ESP32-S3 WROOM.
 *
 * Two stepper motors:
 *   1. LAUNCH motor  – A4988/DRV8825 driver (STEP + DIR).
 *                       Simple 360° CCW rotation to fire the
 *                       spring-loaded arm via an intermittent gear.
 *   2. RELOAD motor  – 4-wire unipolar stepper (e.g. 28BYJ-48)
 *                       driven via Stepper.h through a ULN2003 board.
 *
 * Communication:
 *   Primary control path is WiFi HTTP.
 *   The backend sends POST /launch to trigger a launch-reload cycle and
 *   polls GET /status until ready becomes true again.
 *
 *   USB serial remains available for debug logs only.
 */

#include <Arduino.h>
#include <ESPmDNS.h>
#include <WiFi.h>
#include <WebServer.h>
#include <Stepper.h>

// ──────────────────────────────────────────────
// Pin Definitions  (avoid strapping pins 0,3,45,46)
// ──────────────────────────────────────────────
// Launch motor – A4988 / DRV8825 STEP+DIR driver
#define LAUNCH_STEP_PIN     7
#define LAUNCH_DIR_PIN      6
#define LAUNCH_ENABLE_PIN   15   // optional – wire to driver EN

// Reload motor – 4-wire unipolar stepper (IN1-IN4 on ULN2003)
#define RELOAD_IN1          17
#define RELOAD_IN2          10
#define RELOAD_IN3          8
#define RELOAD_IN4          9

// ──────────────────────────────────────────────
// Stepper Tuning
// ──────────────────────────────────────────────
// Launch motor – 360° CCW rotation (half-stepping: 400 steps = 360°)
#define LAUNCH_STEPS_PER_REV  400    // half-step: 0.9° per step × 400 = 360°
#define LAUNCH_STEP_DELAY_US  3000   // µs between steps (controls speed)

// Reload motor – 28BYJ-48 with ULN2003
// 2048 steps = 1 full output shaft revolution (with 64:1 gear ratio)
#define RELOAD_STEPS_PER_REV  2048
#define RELOAD_RPM            15     // speed in RPM (max ~20 before stalling)
#define RELOAD_STEPS          683  // steps to advance per reload (8 full revs)

// Delay between launch and reload (ms)
#define POST_LAUNCH_DELAY_MS  500

// ──────────────────────────────────────────────
// WiFi Credentials
// ──────────────────────────────────────────────
const char* WIFI_SSID     = "PotatoSpot";
const char* WIFI_PASSWORD = "password";
const char* MDNS_HOSTNAME = "sillypult";

// ──────────────────────────────────────────────
// Globals
// ──────────────────────────────────────────────
WebServer server(80);

enum LaunchState : uint8_t {
    IDLE = 0,
    RUNNING = 1,
};

volatile LaunchState launchState = IDLE;
TaskHandle_t launchTaskHandle = nullptr;
bool mdnsStarted = false;

// 28BYJ-48: Stepper.h pairs (pin1,pin3) and (pin2,pin4) internally,
// so pass IN1, IN3, IN2, IN4 to match adjacent coil activation
Stepper reloadMotor(RELOAD_STEPS_PER_REV, RELOAD_IN1, RELOAD_IN3, RELOAD_IN2, RELOAD_IN4);

// ──────────────────────────────────────────────
// Stepper helpers
// ──────────────────────────────────────────────
void initSteppers() {
    // --- Launch motor (A4988 / DRV8825) ---
    pinMode(LAUNCH_STEP_PIN, OUTPUT);
    pinMode(LAUNCH_DIR_PIN,  OUTPUT);
    pinMode(LAUNCH_ENABLE_PIN, OUTPUT);
    digitalWrite(LAUNCH_STEP_PIN, LOW);
    digitalWrite(LAUNCH_ENABLE_PIN, HIGH);  // HIGH = disabled on most drivers
    Serial.println("[STEPPER] Launch motor initialised (STEP/DIR)");

    // --- Reload motor (Stepper.h) ---
    reloadMotor.setSpeed(RELOAD_RPM);
    Serial.printf("[STEPPER] Reload motor initialised (Stepper.h, pins %d-%d-%d-%d, %d RPM)\n",
                  RELOAD_IN1, RELOAD_IN2, RELOAD_IN3, RELOAD_IN4, RELOAD_RPM);
}

/**
 * Step the reload motor in small chunks, yielding between each
 * chunk to prevent the ESP32 watchdog timer from resetting.
 */
void reloadStep(int totalSteps) {
    const int CHUNK = 128;  // steps per chunk
    int remaining = abs(totalSteps);
    int dir = (totalSteps >= 0) ? 1 : -1;

    while (remaining > 0) {
        int n = min(remaining, CHUNK);
        reloadMotor.step(n * dir);
        remaining -= n;
        yield();  // feed the watchdog
    }
}

/**
 * Rotate the launch motor exactly 360° counter-clockwise.
 * Uses simple GPIO bit-banging at a constant speed.
 */
void rotateLaunchMotor() {
    // Enable driver (LOW = enabled on A4988 / DRV8825)
    digitalWrite(LAUNCH_ENABLE_PIN, LOW);
    delay(2);  // let driver wake up

    // Set direction: LOW = counter-clockwise (flip if your wiring differs)
    digitalWrite(LAUNCH_DIR_PIN, LOW);

    // Step through one full revolution
    for (int i = 0; i < LAUNCH_STEPS_PER_REV; i++) {
        digitalWrite(LAUNCH_STEP_PIN, HIGH);
        delayMicroseconds(LAUNCH_STEP_DELAY_US);
        digitalWrite(LAUNCH_STEP_PIN, LOW);
        delayMicroseconds(LAUNCH_STEP_DELAY_US);
    }

    // Disable driver to save power / reduce heat
    digitalWrite(LAUNCH_ENABLE_PIN, HIGH);
}

// ──────────────────────────────────────────────
// Launch → Reload sequence
// ──────────────────────────────────────────────
void executeLaunchCycle() {
    Serial.println("[LAUNCH] Firing catapult – rotating 360° CCW...");

    rotateLaunchMotor();

    Serial.println("[LAUNCH] Launch complete – waiting before reload");
    delay(POST_LAUNCH_DELAY_MS);

    Serial.println("[RELOAD] Advancing next ball...");
    reloadStep(RELOAD_STEPS);

    Serial.println("[RELOAD] Reload complete – ready for next launch");
}

void stopMDNS() {
    if (!mdnsStarted) {
        return;
    }

    MDNS.end();
    mdnsStarted = false;
    Serial.println("[MDNS] Stopped");
}

void startMDNS() {
    if (WiFi.status() != WL_CONNECTED) {
        stopMDNS();
        return;
    }

    if (mdnsStarted) {
        return;
    }

    if (MDNS.begin(MDNS_HOSTNAME)) {
        MDNS.addService("http", "tcp", 80);
        mdnsStarted = true;
        Serial.printf("[MDNS] Registered as http://%s.local/\n", MDNS_HOSTNAME);
    } else {
        Serial.println("[MDNS] Registration failed");
    }
}

// ──────────────────────────────────────────────
// HTTP Handlers
// ──────────────────────────────────────────────
void handleRoot() {
    String html = "<!DOCTYPE html><html><body>"
                  "<h1>Silly-Pult</h1>"
                  "<p>POST <code>/launch</code> to fire the catapult.</p>"
                  "<p>GET  <code>/status</code> to check readiness.</p>"
                  "</body></html>";
    server.send(200, "text/html", html);
}

void handleLaunch() {
    if (server.method() != HTTP_POST) {
        server.send(405, "application/json", "{\"error\":\"POST only\"}");
        return;
    }

    if (launchState != IDLE || launchTaskHandle == nullptr) {
        server.send(429, "application/json", "{\"error\":\"launch already in progress\"}");
        return;
    }

    launchState = RUNNING;
    xTaskNotifyGive(launchTaskHandle);
    server.send(200, "application/json", "{\"status\":\"launch triggered\"}");
    Serial.println("[HTTP] Launch request received");
}

void handleStatus() {
    bool ready = launchState == IDLE;
    bool wifiConnected = WiFi.status() == WL_CONNECTED;

    String json = "{\"ready\":" + String(ready ? "true" : "false") + ","
                  "\"busy\":" + String(ready ? "false" : "true") + ","
                  "\"wifiConnected\":" + String(wifiConnected ? "true" : "false") + ","
                  "\"hostname\":\"" + String(MDNS_HOSTNAME) + ".local\","
                  "\"ip\":\"" + WiFi.localIP().toString() + "\"}";
    server.send(200, "application/json", json);
}

void handleNotFound() {
    server.send(404, "application/json", "{\"error\":\"not found\"}");
}

// ──────────────────────────────────────────────
// WiFi
// ──────────────────────────────────────────────
void connectWiFi() {
    Serial.printf("[WIFI] Connecting to %s", WIFI_SSID);
    WiFi.mode(WIFI_STA);
    WiFi.setHostname(MDNS_HOSTNAME);
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

    int retries = 0;
    while (WiFi.status() != WL_CONNECTED && retries < 40) {
        delay(500);
        Serial.print(".");
        retries++;
    }

    if (WiFi.status() == WL_CONNECTED) {
        Serial.println();
        Serial.printf("[WIFI] Connected!  IP: %s\n", WiFi.localIP().toString().c_str());
        startMDNS();
    } else {
        Serial.println();
        Serial.println("[WIFI] Connection failed – check credentials");
        stopMDNS();
    }
}

void maintainConnectivity() {
    if (WiFi.status() == WL_CONNECTED) {
        startMDNS();
        return;
    }

    stopMDNS();
    static unsigned long lastReconnectAttemptMs = 0;
    unsigned long now = millis();
    if (now - lastReconnectAttemptMs < 5000) {
        return;
    }

    lastReconnectAttemptMs = now;
    Serial.println("[WIFI] Reconnecting...");
    WiFi.disconnect();
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
}

void launchWorker(void* parameter) {
    (void)parameter;

    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        executeLaunchCycle();
        launchState = IDLE;
    }
}

// ──────────────────────────────────────────────
// Arduino entry points
// ──────────────────────────────────────────────
void setup() {
    Serial.begin(115200);
    delay(1000);  // let USB-CDC settle
    Serial.println();
    Serial.println("=== Silly-Pult Firmware ===");

    initSteppers();
    connectWiFi();

    // Register HTTP routes
    server.on("/",       HTTP_GET,  handleRoot);
    server.on("/launch", HTTP_POST, handleLaunch);
    server.on("/status", HTTP_GET,  handleStatus);
    server.onNotFound(handleNotFound);
    server.begin();
    Serial.println("[HTTP] Server started on port 80");

    xTaskCreatePinnedToCore(launchWorker, "launchWorker", 4096, nullptr, 1, &launchTaskHandle, 1);
}

void loop() {
    server.handleClient();
    maintainConnectivity();
    delay(2);
}
