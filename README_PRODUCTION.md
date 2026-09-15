# EPV Production Release - 2026/09/15

## Release components

- Client: `epv_api_cli_v2.3.3_rhel7.c`
  - RHEL 7/8/9/10 portable build logic.
  - TLS server identity verification for DNS/IP SAN.
  - fast priority failback probe with hard TLS/I/O deadline.
  - multi-instance cache isolation by executable + server-file path.
  - external server file is authoritative when it contains valid entries.
  - bounded nonblocking cache locking to avoid cross-process hangs.
- Shadow connector: `api_connector_shadow_v2.3.2.c`
  - schema: `gen_file/epv_file/epa_file/epb_file`.
  - RHEL 7/8/9/10 and OpenSSL 1.0.2+ compatibility.
  - ACTIVE/STANDBY/MAINTENANCE, LKG DB, replay protection, mTLS, systemd notify/watchdog.
  - sensitive debug tracing exists but production service does NOT enable `--debug`.
- Snapshot connector: `api_connector_snapshot_v2.3.2.c`
  - schema: `users/access/records`.
  - preserves salted SHA-256 authentication.
  - same RHEL/TLS/HA/LKG/debug framework as shadow v2.3.2.

## Important deployment rule

Build deployment binaries on the target RHEL major version, or on an older compatible build root. Do not build on RHEL 10 and copy that binary to RHEL 7.

Target dependencies:

```bash
yum install -y gcc openssl-devel sqlite-devel jansson-devel
```

Use:

```bash
./tools/preflight_rhel.sh
./tools/build_all_rhel.sh
```

Built files are copied to `build/bin/`.

## Client deployment

Recommended primary client:

```bash
install -o root -g root -m 0755 \
  build/bin/epv_api_cli_v2.3.3_rhel7 \
  /aprun/shell/epv_api
```

Optional independent second client:

```bash
install -o root -g root -m 0755 \
  build/bin/epv_api_cli_v2.3.3_rhel7 \
  /aprun/shell/epv_api_second
```

The two copies can safely use different server files:

```bash
/aprun/shell/epv_api \
  --server-file /opt/epm_certs/epv_servers.ini \
  --priority-recheck 30 \
  --priority-probe-timeout 1 \
  --health

/aprun/shell/epv_api_second \
  --server-file /opt/epm_certs/epv_servers_second.ini \
  --priority-recheck 30 \
  --priority-probe-timeout 1 \
  --health
```

v2.3.3 gives each executable/config combination a separate ACTIVE-server and token-origin cache namespace.

When upgrading from v2.3.1/v2.3.2, remove only the old shared caches once all old client processes have stopped:

```bash
rm -f /tmp/epv_api_active_server_$(id -u).cache
rm -f /tmp/epv_api_token_origin_$(id -u).cache
```

Do not wildcard-delete the new v2.3.3 scoped cache files during normal operation.

## Client TLS files

Recommended root-only private-key permissions:

```bash
chown root:root /opt/epm_certs/client.key /opt/epm_certs/client.crt /opt/epm_certs/ca.crt
chmod 0600 /opt/epm_certs/client.key
chmod 0644 /opt/epm_certs/client.crt /opt/epm_certs/ca.crt
chmod 0644 /opt/epm_certs/epv_servers.ini
```

Production must use certificate verification. Do not use `--insecure` except temporary troubleshooting.

The server certificate SAN must contain the exact DNS name or IP/VIP used by the client. See `config/sa.cnf.example`.

## Connector deployment

Choose **one** connector implementation per listen IP/port:

- shadow: `/ws/shadow.db`
- snapshot: `/ws/snapshot.db`

Do not enable both supplied units on the same host if both are configured to port 6666.

Create service account:

```bash
getent group epvconnector >/dev/null || groupadd -r epvconnector
id epvconnector >/dev/null 2>&1 || \
  useradd -r -g epvconnector -d /nonexistent -s /sbin/nologin epvconnector
```

Recommended server permissions:

```bash
chown root:epvconnector /opt/epm_certs/server.crt /opt/epm_certs/server.key /opt/epm_certs/ca.crt
chmod 0640 /opt/epm_certs/server.crt /opt/epm_certs/server.key /opt/epm_certs/ca.crt
chmod 0750 /opt/epm_certs

mkdir -p /etc/epv
chown root:epvconnector /etc/epv
chmod 0750 /etc/epv
printf 'ACTIVE\n' > /etc/epv/connector.role
chown root:epvconnector /etc/epv/connector.role
chmod 0640 /etc/epv/connector.role
```

Database should normally be owned by root and readable by the service group:

```bash
chown root:epvconnector /ws/shadow.db   # or /ws/snapshot.db
chmod 0640 /ws/shadow.db                # or /ws/snapshot.db
```

### Shadow connector

```bash
install -o root -g root -m 0755 \
  build/bin/api_connector_shadow_v2.3.2 \
  /usr/local/sbin/api_connector_shadow_v2.3.2

install -o root -g root -m 0644 \
  systemd/epv-api-connector-shadow-v2.3.2.service \
  /etc/systemd/system/epv-api-connector-shadow-v2.3.2.service

./tools/check_runtime_files.sh shadow
systemd-analyze verify /etc/systemd/system/epv-api-connector-shadow-v2.3.2.service
systemctl daemon-reload
systemctl enable --now epv-api-connector-shadow-v2.3.2.service
```

### Snapshot connector

```bash
install -o root -g root -m 0755 \
  build/bin/api_connector_snapshot_v2.3.2 \
  /usr/local/sbin/api_connector_snapshot_v2.3.2

install -o root -g root -m 0644 \
  systemd/epv-api-connector-snapshot-v2.3.2.service \
  /etc/systemd/system/epv-api-connector-snapshot-v2.3.2.service

./tools/check_runtime_files.sh snapshot
systemd-analyze verify /etc/systemd/system/epv-api-connector-snapshot-v2.3.2.service
systemctl daemon-reload
systemctl enable --now epv-api-connector-snapshot-v2.3.2.service
```

## Role switching

No restart is required for the connector role file:

```bash
printf 'ACTIVE\n'      > /etc/epv/connector.role
printf 'STANDBY\n'     > /etc/epv/connector.role
printf 'MAINTENANCE\n' > /etc/epv/connector.role
```

## Health verification

```bash
/aprun/shell/epv_api --debug --health
```

Production executions should normally omit `--debug`.

## Debug warning

Connector v2.3.2 intentionally supports full sensitive debug output for troubleshooting. When `--debug` is enabled, logs may contain login passwords, encrypted secret values, decrypted database passwords, token plaintext, and token ciphertext. Never leave `--debug` enabled in production systemd units.

## Data intentionally excluded from this archive

This production source package does **not** contain:

- `shadow.db`
- `snapshot.db`
- private keys or certificates
- live `epv_servers.ini` files
- live role/config secrets

Keep those environment-specific files outside the software release archive.
