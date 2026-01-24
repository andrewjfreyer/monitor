# Docker Installation Guide for Monitor

This guide will help you run the `monitor` Bluetooth presence detection system in a Docker container, with specific instructions for Unraid servers.

## Table of Contents
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Unraid Installation](#unraid-installation)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)

## Requirements

### Hardware
- Bluetooth adapter (built-in or USB)
- The host system must have Bluetooth support (most modern systems do)

### Software
- Docker
- Docker Compose (optional, but recommended)
- MQTT broker (like Mosquitto) accessible on your network

## Quick Start

### Using Docker Compose (Recommended)

1. **Clone the repository:**
   ```bash
   git clone https://github.com/andrewjfreyer/monitor.git
   cd monitor
   ```

2. **Create configuration files:**
   ```bash
   cd config
   cp mqtt_preferences.example mqtt_preferences
   cp known_static_addresses.example known_static_addresses
   cp behavior_preferences.example behavior_preferences
   ```

3. **Edit the configuration files:**
   - Edit `mqtt_preferences` to set your MQTT broker address, username, and password
   - Edit `known_static_addresses` to add your device MAC addresses
   - Optionally edit `behavior_preferences` for advanced settings

4. **Build and run:**
   ```bash
   cd ..
   docker-compose up -d
   ```

5. **View logs:**
   ```bash
   docker-compose logs -f monitor
   ```

### Using Docker CLI

1. **Build the image:**
   ```bash
   docker build -t monitor .
   ```

2. **Run the container:**
   ```bash
   docker run -d \
     --name monitor \
     --restart unless-stopped \
     --privileged \
     --network host \
     -v $(pwd)/config:/config \
     monitor -tad -a -b
   ```

## Unraid Installation

### Method 1: Docker Compose Manager (Recommended)

If you have the Docker Compose Manager plugin installed on Unraid:

1. **Navigate to Docker Compose Manager** in the Unraid web interface

2. **Add a new stack:**
   - Click "Add New Stack"
   - Name it "monitor"
   - Paste the contents of `docker-compose.yml`

3. **Configure the stack:**
   - Set the config volume path to a location on your Unraid array (e.g., `/mnt/user/appdata/monitor`)
   - Click "Compose Up"

### Method 2: Unraid Docker Template (Manual)

1. **Open the Unraid Docker tab** in the web interface

2. **Click "Add Container"**

3. **Configure the container with these settings:**

   | Setting | Value |
   |---------|-------|
   | Name | monitor |
   | Repository | (Build the image first, or use your own registry) |
   | Network Type | Host |
   | Privileged | Yes (required for Bluetooth access) |
   | Container Path | `/config` |
   | Host Path | `/mnt/user/appdata/monitor` |
   | Post Arguments | `-tad -a -b` (or customize as needed) |

4. **Create configuration files** in `/mnt/user/appdata/monitor/`:
   - Copy the example files from the `config/` directory
   - Edit them with your settings

5. **Start the container**

### Unraid-Specific Notes

- **Bluetooth USB Adapter:** If using a USB Bluetooth adapter, ensure it's assigned to the VM/Docker in Unraid settings
- **Built-in Bluetooth:** Most Unraid servers don't have built-in Bluetooth, so you'll need a USB adapter
- **Permissions:** The container runs in privileged mode to access Bluetooth hardware

## Configuration

### MQTT Settings (`mqtt_preferences`)

Edit this file to configure your MQTT broker connection:

```bash
mqtt_address=192.168.1.100    # Your MQTT broker IP
mqtt_user=youruser             # MQTT username
mqtt_password=yourpass         # MQTT password
mqtt_port=1883                 # MQTT port (default 1883)
mqtt_topicpath=monitor         # MQTT topic prefix
mqtt_publisher_identity=bedroom # Name for this monitor instance
```

### Known Devices (`known_static_addresses`)

Add your Bluetooth devices to monitor:

```bash
AA:BB:CC:DD:EE:FF MyPhone
11:22:33:44:55:66 MySmartwatch
```

To find your device's MAC address:
- Android: Settings → About Phone → Status → Bluetooth Address
- iPhone: More complex, see [this guide](https://github.com/andrewjfreyer/monitor/issues/236)

### Behavior Preferences (`behavior_preferences`)

Advanced settings for scan behavior. The defaults work well for most setups.

### Command Line Arguments

You can customize the container behavior by changing the command arguments:

| Argument | Description |
|----------|-------------|
| `-tad` | Triggered arrival and departure scanning (recommended for multiple nodes) |
| `-a` | Report all anonymous advertisements |
| `-b` | Enable beacon mode |
| `-r` | Send arrive/depart scan requests to other nodes |
| `-v` | Verbose logging |

Example in `docker-compose.yml`:
```yaml
command: ["-b", "-tad", "-v"]
```

## Verifying Bluetooth Access

To verify the container can access Bluetooth:

```bash
# Enter the running container
docker exec -it monitor bash

# Check Bluetooth adapter
hciconfig

# You should see output like:
# hci0:   Type: Primary  Bus: USB
#         BD Address: XX:XX:XX:XX:XX:XX  ACL MTU: 1021:8  SCO MTU: 64:1
```

## Multiple Nodes

If you want to run multiple monitor instances (e.g., in different rooms):

1. **Create separate directories** for each instance:
   ```bash
   /mnt/user/appdata/monitor-bedroom
   /mnt/user/appdata/monitor-living-room
   /mnt/user/appdata/monitor-garage
   ```

2. **Configure each with:**
   - Same MQTT broker settings
   - Same devices in `known_static_addresses`
   - Different `mqtt_publisher_identity` (e.g., "bedroom", "living-room", "garage")
   - Use `-tad` flag for triggered-only scanning on secondary nodes
   - Use `-tr` flag on primary node to trigger scans on other nodes

3. **Primary node:** `-a -b -tr` (reports and triggers others)
4. **Secondary nodes:** `-tad -b` (only scan when triggered)

## Troubleshooting

### Container won't start
- Ensure Bluetooth is available on the host: `hciconfig`
- Check if the container has privileged mode enabled
- Verify network mode is set to `host`

### No devices detected
- Verify MAC addresses are correct in `known_static_addresses`
- Check that devices have Bluetooth enabled and are in range
- Review container logs: `docker logs monitor`

### MQTT connection issues
- Verify MQTT broker is accessible from the container
- Check MQTT credentials in `mqtt_preferences`
- Test MQTT connection: `mosquitto_pub -h YOUR_BROKER -t test -m "test"`

### Permission denied errors
- Ensure container is running in privileged mode
- Check that host has Bluetooth permissions

### High CPU usage
- Adjust scan filters in `behavior_preferences`
- Increase `PREF_MINIMUM_TIME_BETWEEN_SCANS`
- Reduce scan attempts in preferences

## Integration with Home Assistant

See the main [README.md](README.md) for Home Assistant integration examples. The MQTT topics follow this format:

```
monitor/[publisher_identity]/[device_alias]
```

Example automation:
```yaml
- platform: mqtt
  state_topic: 'monitor/bedroom/MyPhone'
  value_template: '{{ value_json.confidence }}'
  unit_of_measurement: '%'
  name: 'Phone in Bedroom'
```

## Support

For issues, questions, or feature requests, please visit:
- [GitHub Issues](https://github.com/andrewjfreyer/monitor/issues)
- [Main Documentation](README.md)
- [FAQ](support/README.md)
