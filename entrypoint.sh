#!/bin/bash
set -e

PREF_FILE="/opt/monitor/mqtt_preferences"

if [ ! -f "$PREF_FILE" ]; then
  echo "[entrypoint] Generating mqtt_preferences from env"

  cat > "$PREF_FILE" <<EOF
mqtt_address ${MQTT_ADDRESS:-127.0.0.1}
mqtt_port ${MQTT_PORT:-1883}
mqtt_username ${MQTT_USERNAME:-homeassistant}
mqtt_password ${MQTT_PASSWORD:-homeassistant}
mqtt_publisher_identity ${MQTT_PUBLISHER_IDENTITY:-$(hostname)}
mqtt_topic_prefix ${MQTT_TOPIC_PREFIX:-presence/ble/raw}
EOF
fi

exec ./monitor.sh
