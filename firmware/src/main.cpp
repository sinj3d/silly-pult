/*
 * Silly-Pult Firmware
 * --------------------
 * Catapult controller for the Freenove ESP32-S3 WROOM.
 *
 * Two stepper motors:
 *   1. LAUNCH motor  – simple 360° CCW rotation to fire the
 *                       spring-loaded arm via an intermittent gear
 *   2. RELOAD motor  – rotates to load the next ball
 *
 * Communication:
 *   Primary control path is USB serial. The backend writes:
 *     activate\n
 *   Firmware responds with:
 *     accepted
 *     busy
 *     complete
 *
 *   HTTP launch/status endpoints are still available for bench testing.
 *
 * Stepper drivers assumed: A4988 / DRV8825 style (STEP + DIR pins).
 */

#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include "FastAccelStepper.h"

// ──────────────────────────────────────────────
// Pin Definitions  (avoid strapping pins 0,3,45,46)
// ──────────────────────────────────────────────
#define LAUNCH_STEP_PIN   4
#define LAUNCH_DIR_PIN    5

#define RELOAD_STEP_PIN   6
#define RELOAD_DIR_PIN    7

#define LAUNCH_ENABLE_PIN 15   // optional – wire to driver EN
#define RELOAD_ENABLE_PIN 16   // optional – wire to driver EN

// ──────────────────────────────────────────────
// Stepper Tuning
// ──────────────────────────────────────────────
// Launch motor – simple 360° CCW rotation
// For a typical 200-step/rev (1.8°) stepper:
#define LAUNCH_STEPS_PER_REV  200    // full steps for one revolution
#define LAUNCH_STEP_DELAY_US  3000   // µs between steps (controls speed)
                                      // 3000 µs → ~167 steps/sec → ~1 rev/sec

// Reload motor – slower rotation to feed next ball
#define RELOAD_SPEED_HZ       1000   // steps / sec
#define RELOAD_ACCEL          2000   // steps / sec²
#define RELOAD_STEPS          400    // steps for one ball advance

// Delay between launch and reload (ms)
#define POST_LAUNCH_DELAY_MS  500

// ──────────────────────────────────────────────
// WiFi Credentials
// ──────────────────────────────────────────────
// Station mode – connect to an existing network
const char* WIFI_SSID     = "YOUR_SSID";
const char* WIFI_PASSWORD = "YOUR_PASSWORD";

// ──────────────────────────────────────────────
// Globals
// ──────────────────────────────────────────────
// FastAccelStepper is still used for the reload motor
FastAccelStepperEngine engine = FastAccelStepperEngine();
FastAccelStepper *reloadStepper = nullptr;

WebServer server(80);

volatile bool launchRequested = false;
String serialCommandBuffer = "";

// ──────────────────────────────────────────────
// Stepper helpers
// ──────────────────────────────────────────────
void initSteppers() {
    // --- Launch motor (manual GPIO control) ---
    pinMode(LAUNCH_STEP_PIN, OUTPUT);
    pinMode(LAUNCH_DIR_PIN,  OUTPUT);
    pinMode(LAUNCH_ENABLE_PIN, OUTPUT);
    digitalWrite(LAUNCH_STEP_PIN, LOW);
    digitalWrite(LAUNCH_ENABLE_PIN, HIGH);  // HIGH = disabled on most drivers
    Serial.println("[STEPPER] Launch motor initialised (simple rotation)");

    // --- Reload motor (FastAccelStepper) ---
    engine.init();
    reloadStepper = engine.stepperConnectToPin(RELOAD_STEP_PIN);
    if (reloadStepper) {
        reloadStepper->setDirectionPin(RELOAD_DIR_PIN);
        reloadStepper->setEnablePin(RELOAD_ENABLE_PIN);
        reloadStepper->setAutoEnable(true);
        reloadStepper->setSpeedInHz(RELOAD_SPEED_HZ);
        reloadStepper->setAcceleration(RELOAD_ACCEL);
        Serial.println("[STEPPER] Reload motor initialised");
    } else {
        Serial.println("[STEPPER] ERROR – could not attach reload motor");
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
    if (reloadStepper) {
        reloadStepper->move(RELOAD_STEPS);

        while (reloadStepper->isRunning()) {
            delay(1);
        }
    }

    Serial.println("[RELOAD] Reload complete – ready for next launch");
    Serial.println("complete");
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
    bool ready = !launchRequested
                 && reloadStepper && !reloadStepper->isRunning();

    String json = "{\"ready\":" + String(ready ? "true" : "false") + ","
                  "\"ip\":\"" + WiFi.localIP().toString() + "\"}";
    server.send(200, "application/json", json);
}

void handleNotFound() {
    server.send(404, "application/json", "{\"error\":\"not found\"}");
}

// ──────────────────────────────────────────────
// Serial Command Handling
// ──────────────────────────────────────────────
void handleSerialCommand(String command) {
    command.trim();
    if (command.length() == 0) {
        return;
    }

    if (command == "activate") {
        if (launchRequested) {
            Serial.println("busy");
            Serial.println("[SERIAL] Host activate rejected because launch is already in progress");
            return;
        }

        launchRequested = true;
        Serial.println("accepted");
        Serial.println("[SERIAL] Host activate accepted");
        return;
    }

    if (command == "status") {
        bool ready = !launchRequested
                     && reloadStepper && !reloadStepper->isRunning();
        Serial.println(ready ? "ready" : "busy");
        Serial.printf("[SERIAL] Host status requested -> %s\n", ready ? "ready" : "busy");
        return;
    }

    Serial.printf("[SERIAL] Unknown command: %s\n", command.c_str());
}

void processSerialCommands() {
    while (Serial.available() > 0) {
        char incoming = static_cast<char>(Serial.read());

        if (incoming == '\r') {
            continue;
        }

        if (incoming == '\n') {
            handleSerialCommand(serialCommandBuffer);
            serialCommandBuffer = "";
            continue;
        }

        serialCommandBuffer += incoming;
    }
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
    processSerialCommands();

    if (launchRequested) {
        executeLaunchCycle();
        launchRequested = false;
    }
}
