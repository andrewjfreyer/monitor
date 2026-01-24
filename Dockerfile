FROM debian:bookworm-slim

# Install required packages
RUN apt-get update && apt-get install -y \
    bluetooth \
    bluez \
    bluez-tools \
    bc \
    mosquitto-clients \
    git \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /monitor

# Copy application files
COPY monitor.sh /monitor/
COPY support/ /monitor/support/
COPY README.md /monitor/

# Make the script executable
RUN chmod +x /monitor/monitor.sh

# Create volume mount points for configuration
VOLUME ["/config"]

# Set environment variables
ENV PREF_CONFIG_DIR=/config

# Create entrypoint script
RUN echo '#!/bin/bash\n\
# Ensure config directory exists\n\
mkdir -p /config\n\
\n\
# Create symbolic links for configuration files if they exist in /config\n\
for file in mqtt_preferences known_static_addresses known_static_beacons behavior_preferences; do\n\
    if [ -f "/config/$file" ]; then\n\
        ln -sf "/config/$file" "/monitor/$file"\n\
    fi\n\
done\n\
\n\
# Start monitor with passed arguments\n\
cd /monitor && exec bash monitor.sh "$@"\n\
' > /entrypoint.sh && chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

# Default arguments - can be overridden
CMD ["-tad", "-a", "-b"]
