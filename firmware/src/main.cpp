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
#define RELOAD_IN2          10
#define RELOAD_IN3          8
#define RELOAD_IN4          9

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

    Serial.println("[TEST] Spinning launch motor...");
    rotateLaunchMotor();
    Serial.println("[TEST] Launch motor done.");

    delay(500);

    // --- Manual slow-step test ---
    // Drives each coil one at a time, very slowly, so you can
    // see the LEDs cycle AND feel the shaft try to move.
    const int pins[] = { RELOAD_IN1, RELOAD_IN2, RELOAD_IN3, RELOAD_IN4 };
    for (int i = 0; i < 4; i++) {
        pinMode(pins[i], OUTPUT);
        digitalWrite(pins[i], LOW);
    }

    // Full-step sequence: energise one coil at a time
    // A → B → C → D → A → B → C → D  (2 full cycles, 8 steps)
    Serial.println("[TEST] Manual full-step test (slow, 500ms per step):");
    for (int cycle = 0; cycle < 2; cycle++) {
        for (int step = 0; step < 4; step++) {
            // Turn all off
            for (int i = 0; i < 4; i++) digitalWrite(pins[i], LOW);
            // Turn on just this coil
            digitalWrite(pins[step], HIGH);
            Serial.printf("  Step %d: IN%d ON\n", cycle * 4 + step, step + 1);
            delay(500);
        }
    }
    // All off
    for (int i = 0; i < 4; i++) digitalWrite(pins[i], LOW);
    Serial.println("[TEST] Manual test done.");

    delay(500);

    // Now try Stepper.h at very low speed
    Serial.println("[TEST] Stepper.step(200) at 2 RPM...");
    reloadMotor.setSpeed(2);
    reloadMotor.step(200);
    Serial.println("[TEST] Stepper test done.");

    // Restore speed
    reloadMotor.setSpeed(RELOAD_RPM);

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
