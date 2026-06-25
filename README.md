# chrony-container

A minimal, secure, and production-ready container image for running Chrony (the NTP daemon) inside Kubernetes.

This project wraps Chrony inside a lightweight Alpine-based container, removing any runtime installer dependencies (`apk add`) and fully supporting a **read-only root filesystem** (`readOnlyRootFilesystem: true`).

## Key Features

- **No Startup Install:** Chrony is pre-packaged inside the container image, eliminating startup package installations and allowing fast initialization.
- **Secure Runtime:** Fully supports running with a read-only root filesystem.
- **Privilege Dropping:** Starts as root to bind to the privileged UDP port `123`, then automatically drops privileges to the low-privileged `chrony` user (`uid=100`, `gid=101`).
- **No Host Interference:** Uses the `-x` flag so Chrony does not attempt to modify the host's kernel clock, making it safe to run alongside hypervisor or node OS clock synchronization.
- **Kubernetes-Ready:** Includes ConfigMap and DaemonSet manifests tailored for direct deployment on Kubernetes nodes (such as Talos control-plane nodes).

---

## Getting Started

### 1. Project Structure

- `Dockerfile`: Defines the minimal image based on Alpine 3.20.
- `chrony.conf`: Default configuration file bundled inside the image.
- `kubernetes/`: Contains example deployment manifests:
  - `configmap.yaml`: High-quality config with upstream servers and network subnets.
  - `daemonset.yaml`: Secure DaemonSet running on `hostNetwork`.

---

### 2. Building the Image

To build the container image locally:

```bash
docker build -t ghcr.io/containdk/chrony:latest .
```

---

### 3. Local Testing (Read-Only FS)

You can run the built image locally in read-only mode to verify that it functions correctly without write access to the root filesystem.

To simulate the Kubernetes execution environment, mount temporary writable volumes (`tmpfs`) to `/run/chrony` and `/var/lib/chrony` with the correct ownership and permissions:

```bash
docker run -d \
  --name chrony-test \
  --read-only \
  --tmpfs /run/chrony:uid=100,gid=101,mode=0750 \
  --tmpfs /var/lib/chrony:uid=100,gid=101,mode=0750 \
  -p 123:123/udp \
  ghcr.io/containdk/chrony:latest
```

Check the logs to verify a successful, error-free start:

```bash
docker logs chrony-test
```

Expected output:
```text
chronyd version 4.5 starting (+CMDMON +NTP +REFCLOCK +RTC +PRIVDROP +SCFILTER +SIGND +ASYNCDNS +NTS +SECHASH +IPV6 -DEBUG)
Disabled control of system clock
```

To clean up:
```bash
docker rm -f chrony-test
```

---

### 4. Deploying to Kubernetes

The deployment manifests are located in the `kubernetes/` folder.

1. **Configure Settings:**
   Review and adjust `kubernetes/configmap.yaml` to specify your upstream NTP servers and client subnets.

2. **Apply ConfigMap:**
   ```bash
   kubectl apply -f kubernetes/configmap.yaml
   ```

3. **Apply DaemonSet:**
   ```bash
   kubectl apply -f kubernetes/daemonset.yaml
   ```

---

## Security Context Details

In `kubernetes/daemonset.yaml`, the container is configured with a hardened security context:

```yaml
securityContext:
  capabilities:
    drop:
      - ALL
    add:
      - NET_BIND_SERVICE
  readOnlyRootFilesystem: true
```

### Explanations:
1. **`readOnlyRootFilesystem: true`**: Locks down the container root filesystem to block writes, improving security. Writable storage is mounted via Kubernetes memory-backed `emptyDir` volumes at:
   - `/run/chrony` (used by Chrony to create PID and command socket files).
   - `/var/lib/chrony` (used to record clock drift files so Chrony converges quickly upon container restart).
2. **`capabilities`**:
   - `drop: [ALL]` removes all standard Linux capabilities.
   - `add: [NET_BIND_SERVICE]` is the single required capability, allowing the container to bind directly to host UDP port `123` (since NTP is a privileged port).
   - **No `CAP_SYS_TIME` required:** Because we run Chrony with `-x`, it does not modify the kernel clock and does not require system-time manipulation capabilities.
