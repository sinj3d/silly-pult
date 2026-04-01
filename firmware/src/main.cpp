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
 *   Connects to an existing WiFi network and exposes a tiny HTTP
 *   server.  The backend sends POST /launch to trigger a
 *   launch-reload cycle.
 */

#include <Arduino.h>
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
#define RELOAD_IN2          8
#define RELOAD_IN3          9
#define RELOAD_IN4          10

// ──────────────────────────────────────────────
// Stepper Tuning
// ──────────────────────────────────────────────
// Launch motor – simple 360° CCW rotation
// For a typical 200-step/rev (1.8°) stepper:
#define LAUNCH_STEPS_PER_REV  250    // slightly over one revolution for extra throw
#define LAUNCH_STEP_DELAY_US  3000   // µs between steps (controls speed)

// Reload motor – 28BYJ-48 with ULN2003
// 2048 steps = 1 full output shaft revolution (with 64:1 gear ratio)
#define RELOAD_STEPS_PER_REV  2048
#define RELOAD_RPM            10     // speed in RPM
#define RELOAD_STEPS          2048   // steps to advance per reload (1 full rev)

// Delay between launch and reload (ms)
#define POST_LAUNCH_DELAY_MS  500

// ──────────────────────────────────────────────
// WiFi Credentials
// ──────────────────────────────────────────────
const char* WIFI_SSID     = "YOUR_SSID";
const char* WIFI_PASSWORD = "YOUR_PASSWORD";

// ──────────────────────────────────────────────
// Globals
// ──────────────────────────────────────────────
WebServer server(80);
volatile bool launchRequested = false;

// Stepper.h expects pins in the order: IN1, IN3, IN2, IN4
// (the library uses a different internal wiring sequence)
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
    Serial.println("[STEPPER] Reload motor initialised (Stepper.h, pins 17-8-9-10)");
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
// Motor test – spins both steppers once on boot
// ──────────────────────────────────────────────
void testSteppers() {
    Serial.println("[TEST] === Stepper Test Start ===");

    Serial.println("[TEST] Spinning launch motor 360° CCW...");
    rotateLaunchMotor();
    Serial.println("[TEST] Launch motor done.");

    delay(500);

    Serial.println("[TEST] Spinning reload motor one full revolution...");
    reloadMotor.step(RELOAD_STEPS);
    Serial.println("[TEST] Reload motor done.");

    Serial.println("[TEST] === Stepper Test Complete ===");
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
    reloadMotor.step(RELOAD_STEPS);

    Serial.println("[RELOAD] Reload complete – ready for next launch");
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

    if (launchRequested) {
        server.send(429, "application/json", "{\"error\":\"launch already in progress\"}");
        return;
    }

    launchRequested = true;
    server.send(200, "application/json", "{\"status\":\"launch triggered\"}");
    Serial.println("[HTTP] Launch request received");
}

void handleStatus() {
    bool ready = !launchRequested;

    String json = "{\"ready\":" + String(ready ? "true" : "false") + ","
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
    } else {
        Serial.println();
        Serial.println("[WIFI] Connection failed – check credentials");
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
    testSteppers();  // spin both motors once to verify wiring
    connectWiFi();

    // Register HTTP routes
    server.on("/",       HTTP_GET,  handleRoot);
    server.on("/launch", HTTP_POST, handleLaunch);
    server.on("/status", HTTP_GET,  handleStatus);
    server.onNotFound(handleNotFound);
    server.begin();
    Serial.println("[HTTP] Server started on port 80");
}

void loop() {
    server.handleClient();

    if (launchRequested) {
        executeLaunchCycle();
        launchRequested = false;
    }
}
