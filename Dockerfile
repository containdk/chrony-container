# =========================================================
# STAGE 1: Compile Statically-Linked Chrony
# =========================================================
FROM alpine:3.20 AS builder

# Install build dependencies, headers, and static libraries
RUN apk add --no-cache \
    curl \
    build-base \
    libcap-dev \
    libcap-static \
    libseccomp-dev \
    libseccomp-static \
    nettle-dev \
    nettle-static \
    linux-headers

# Install the chrony alpine package simply to initialize the standard chrony user/group
RUN apk add --no-cache chrony

# Download and extract Chrony source code
ENV CHRONY_VERSION=4.5
RUN curl -s https://chrony-project.org/releases/chrony-${CHRONY_VERSION}.tar.gz | tar xz

# Configure and compile Chrony statically with seccomp sandbox filtering
RUN cd chrony-${CHRONY_VERSION} && \
    LDFLAGS="-static" ./configure \
      --prefix=/usr \
      --sysconfdir=/etc/chrony \
      --chronyrundir=/run/chrony \
      --chronyvardir=/var/lib/chrony \
      --with-user=chrony \
      --with-pidfile=/run/chrony/chronyd.pid \
      --enable-scfilter && \
    make && \
    make install

# Create empty directories for state and run files with correct ownership
RUN mkdir -p /var/lib/chrony /run/chrony && \
    chown -R chrony:chrony /var/lib/chrony /run/chrony

# =========================================================
# STAGE 2: Secure, Distroless Final Image
# =========================================================
FROM gcr.io/distroless/static-debian12:latest

# Best-practice OCI Image Metadata
LABEL org.opencontainers.image.title="chrony-container" \
      org.opencontainers.image.description="Statically-linked Chrony (NTP daemon) running inside a hardened, zero-dependency distroless container." \
      org.opencontainers.image.url="https://github.com/containdk/chrony-container" \
      org.opencontainers.image.source="https://github.com/containdk/chrony-container" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Contain by Netic"

# Copy user/group definitions from the builder stage (contains uid 100/gid 101)
COPY --from=builder /etc/passwd /etc/passwd
COPY --from=builder /etc/group /etc/group

# Copy the statically compiled binary
COPY --from=builder /usr/sbin/chronyd /usr/sbin/chronyd

# Copy default configuration file
COPY chrony.conf /etc/chrony/chrony.conf

# Copy empty run and state directories with correct ownership (uid=100, gid=101)
COPY --chown=100:101 --from=builder /var/lib/chrony /var/lib/chrony
COPY --chown=100:101 --from=builder /run/chrony /run/chrony

# Expose NTP port (UDP 123)
EXPOSE 123/udp

# Run chronyd in foreground, logging to stdout (-d)
# -x: disable control of the system clock (crucial in container environments)
# -u chrony: drop privileges to low-privileged user after binding to port 123
ENTRYPOINT ["/usr/sbin/chronyd", "-d", "-x", "-u", "chrony"]
