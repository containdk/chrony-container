FROM alpine:3.20

LABEL org.opencontainers.image.title="chrony-container" \
      org.opencontainers.image.description="Minimal and secure container image running Chrony (NTP daemon) with a read-only root filesystem." \
      org.opencontainers.image.url="https://github.com/containdk/chrony-container" \
      org.opencontainers.image.source="https://github.com/containdk/chrony-container" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Netic A/S"

RUN apk add --no-cache chrony

RUN mkdir -p /var/lib/chrony /run/chrony && \
    chown -R chrony:chrony /var/lib/chrony /run/chrony

COPY chrony.conf /etc/chrony/chrony.conf

EXPOSE 123/udp

# Run chronyd in foreground, logging to stdout (-d)
# -x: disable control of the system clock (crucial to prevent fighting host/hypervisor clocks)
# -u chrony: drop privileges to chrony user after binding to privileged port
ENTRYPOINT ["chronyd", "-d", "-x", "-u", "chrony"]
