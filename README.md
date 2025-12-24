# BLE Monitor (Containerized)

**BLE Monitor** is a **container-first Bluetooth Low Energy (BLE) presence signal publisher**.

It scans BLE advertisements and publishes **raw presence facts** to MQTT.
It does **not** perform automations, aggregation, or decision-making.

This project is designed to be consumed by **Home Assistant** (or any other system) where higher-level logic such as Wi-Fi correlation, Bayesian sensors, and `person` entities belong.

---

## 🔑 Core Principles

### 1. BLE Monitor is stateless

* No Home Assistant logic
* No automations
* No zone or presence fusion
* BLE is a **signal**, not a decision

### 2. MQTT is the contract

* Stable topic structure
* Idempotent, retained messages
* HA restarts must not break state recovery

### 3. Container-first

* No systemd
* No interactive setup
* All configuration via env vars or mounted files
* Designed to run unattended long-term

---

## 📡 MQTT Topic Contract

BLE Monitor publishes **raw facts only**.

```
presence/ble/raw/<node>/status            online | offline
presence/ble/raw/<node>/<device_id>       home | not_home
presence/ble/raw/<node>/<device_id>/rssi  <int>
```

### ❌ BLE Monitor will NOT publish

* `person.*`
* `device_tracker.*`
* `binary_sensor.*`
* Zone logic or presence fusion

---

## 🧩 What BLE Monitor Does (and Does Not Do)

### ✅ BLE Monitor

* Scans BLE advertisements
* Tracks device proximity
* Publishes raw presence + RSSI to MQTT

### ❌ BLE Monitor does NOT

* Decide “who is home”
* Handle Wi-Fi presence
* Define Home Assistant entities
* Trigger automations or notifications

Those responsibilities belong to **Home Assistant** (or downstream consumers).

---

## 🐳 Container Runtime Model

BLE Monitor runs as a **privileged container** using the **host Bluetooth stack (BlueZ + D-Bus)**.

Typical runtime requirements:

* Host Bluetooth hardware
* Access to `/run/dbus`
* Host networking
* MQTT broker reachable from the container

---

## 🚀 Quick Start (Local)

### Build the image

```bash
make build-latest
```

### Run the container

```bash
make run
```

### View logs

```bash
make logs
```

### Stop it

```bash
make stop
```

---

## 🔧 Configuration

### Environment Variables

| Variable                  | Description          | Default            |
| ------------------------- | -------------------- | ------------------ |
| `MQTT_ADDRESS`            | MQTT broker host     | `127.0.0.1`        |
| `MQTT_PORT`               | MQTT broker port     | `1883`             |
| `MQTT_USERNAME`           | MQTT username        | empty              |
| `MQTT_PASSWORD`           | MQTT password        | empty              |
| `MQTT_PUBLISHER_IDENTITY` | Node name (`<node>`) | hostname           |
| `MQTT_TOPIC_PREFIX`       | Topic prefix         | `presence/ble/raw` |

### MQTT Preferences File

The container expects a preferences file mounted at:

```
/opt/monitor/mqtt_preferences
```

This file is **not baked into the image** and should be mounted at runtime.

---

## 🛠 Makefile Targets

| Target              | Description                          |
| ------------------- | ------------------------------------ |
| `make build`        | Build image tagged `dev-<gitsha>`    |
| `make build-latest` | Build image tagged `dev-latest`      |
| `make build-all`    | Build both tags                      |
| `make run`          | Run container (host net, privileged) |
| `make stop`         | Stop container                       |
| `make logs`         | Tail logs                            |
| `make push`         | Push `dev-latest` to GHCR            |
| `make publish`      | Push both tags                       |
| `make info`         | Show image metadata                  |

---

## 📦 Image Registry

Images are published to **GitHub Container Registry (GHCR)**:

```
ghcr.io/bageera/ble-monitor
```

Tags:

* `dev-<shortsha>`
* `dev-latest`

Each image includes OCI metadata:

* source repository
* git revision
* build timestamp

---

## 🏗 Architecture (High-Level)

```
BLE Devices
   ↓
BLE Monitor (container)
   ↓  MQTT (raw facts)
MQTT Broker
   ↓
Home Assistant
   - binary_sensor
   - device_tracker
   - Wi-Fi correlation
   - Bayesian sensors
   - person entities
   - automations
```

---

## 🧭 Project Direction

This repository is intentionally focused on **one responsibility**:

> **Publish raw BLE presence facts over MQTT, reliably and predictably.**

Future evolution may include:

* Native Python BLE scanner (replacing shell scripts)
* Improved resolvable MAC handling
* Better beacon vs phone identity mapping

What will **not** be added:

* Home Assistant YAML
* Presence logic
* Automations
* UI configuration

---
## 🚢 Releases

Development images:
- `dev-<shortsha>`
- `dev-latest`

Release images (tagged):
- `vX.Y.Z`
- `latest`

To cut a release:
1. Merge `dev` → `main/master`
2. Tag a version:

```bash
make tag-release VERSION=v0.1.0


---

## 📜 License

MIT (inherited from upstream work).

