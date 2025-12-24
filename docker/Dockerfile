FROM debian:12-slim
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bluetooth bluez bluez-hcidump bc curl procps mosquitto-clients ca-certificates tini \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/monitor
COPY . /opt/monitor

RUN chmod +x /opt/monitor/monitor.sh

ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["./monitor.sh"]
