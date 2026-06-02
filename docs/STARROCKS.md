# MySQL / StarRocks shadow proxy

This document covers the MySQL wire-protocol path. For the pgwire / Postgres / AlloyDB path see [POSTGRES.md](POSTGRES.md). For the high-level overview, see the [README](../README.md).

## Quick start

```bash
# Start two local StarRocks clusters + the proxy + Prometheus + Grafana
docker compose -f docker-compose.local.yaml up --build

# Connect through the proxy (queries hit both clusters)
mysql -h 127.0.0.1 -P 3306 -u root -e "SELECT 1"

# View metrics
# Prometheus: http://localhost:9090/metrics
# Grafana:    http://localhost:3000 (admin/admin)
```

## Architecture

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                        │
│  Client ════[TLS]════> Shadow Proxy ────[MySQL Packets]────> Primary FE Service       │
│                        (terminates TLS)       │              (sync, latency-sensitive) │
│                              │                │                                        │
│                              │     ┌──────────┴──────────┐                            │
│                              │     │ MySQL Packet Reader │                            │
│                              │     │ (buffered, handles  │                            │
│                              │     │  TCP fragmentation) │                            │
│                              │     └──────────┬──────────┘                            │
│                              │                │                                        │
│                              │                └───> Primary response ───> Client       │
│                              │                                                         │
│                              └────[MySQL Packets]────> Shadow Worker                   │
│                                  1:1 per client         (async mirroring)              │
│                                  Bounded queue          Complete packets only          │
│                                  (10K packets)          Protocol-aware drain           │
│                                                                                        │
│  Legend:                                                                               │
│    ════  Encrypted (TLS, proxy as server)                                              │
│    ────  MySQL protocol packets (proxy parses and forwards complete packets)           │
│                                                                                        │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

## MySQL packet-based forwarding

The proxy reads and forwards **complete MySQL packets** rather than raw TCP streams. This ensures:

- **No packet fragmentation**: Each shadow connection receives complete, valid MySQL packets
- **Accurate query counting**: Counts actual MySQL commands (`COM_QUERY`, `COM_STMT_EXECUTE`), not TCP operations
- **Protocol correctness**: Handles TCP fragmentation transparently via buffered reading
- **Multi-packet support**: Properly handles large queries (>16MB) that span multiple MySQL packets

**Supported MySQL commands tracked**:

| Command | Hex | Counted as Query |
|---------|-----|------------------|
| `COM_QUERY` | 0x03 | Yes |
| `COM_STMT_PREPARE` | 0x16 | Yes |
| `COM_STMT_EXECUTE` | 0x17 | Yes |
| `COM_PING` | 0x0E | No |
| `COM_QUIT` | 0x01 | No |
| `COM_INIT_DB` | 0x02 | No |
| Other admin commands | - | No |

## Shadow worker (1:1 per client)

Each client connection gets exactly **one** dedicated shadow worker:

- **1:1 Mapping**: One shadow connection per client connection (N clients = N shadow connections)
- **Bounded Queue**: Each worker has a bounded queue (default: 10,000 packets) for backpressure
- **Non-blocking Send**: Packets are queued asynchronously; if queue is full, packets are dropped (metric tracked)
- **SSL Support**: Optional TLS for shadow connections (proxy acts as TLS client via STARTTLS)
- **Complete Packets**: Shadow connection receives only complete MySQL packets (no fragmentation)
- **Protocol-Aware Drain**: Uses MySQL protocol parsing to read complete responses (no timeout-based detection)

### Graceful shutdown

When a client disconnects, the shadow worker performs a graceful drain to ensure all queued queries are processed:

1. **Stop accepting new queries**: Worker is marked as closed
2. **Signal worker to drain**: Worker receives a drain signal
3. **Process pending queries**: Worker processes all remaining packets in its queue
4. **Wait for completion**: System waits up to 60 seconds (configurable) for draining to complete
5. **Close connection**: Only after draining (or timeout) is the connection closed

This ensures accurate query counting — every query sent to primary is also sent to shadow, with no queries lost due to connection cleanup races.

## How TLS works

The proxy implements MySQL protocol SSL upgrade following the same pattern as StarRocks FE:

1. **Handshake**: Proxy reads handshake from primary FE, modifies it to advertise SSL support, sends to client
2. **SSL Request Detection**: Client sends capabilities with `CLIENT_SSL` flag (32-byte packet)
3. **TLS Upgrade**: Proxy performs TLS handshake with client using configured certificate
4. **Decrypted Proxying**: All subsequent traffic is decrypted, forwarded to backends over plain TCP

This allows clients to connect with `--ssl-mode=REQUIRED` while backend connections remain plain TCP.

## MySQL packet handling internals

The proxy uses a **buffered MySQL packet reader** to ensure complete packets are forwarded:

1. **Buffered Reading**: TCP data is buffered until a complete MySQL packet is available
2. **Packet Parsing**: MySQL packet header (4 bytes) is parsed to determine payload length
3. **Complete Forwarding**: Only complete packets are forwarded to primary and shadow
4. **Command Detection**: The command byte is extracted to track query types accurately

**Why this matters for shadow mirroring**: without packet-aware handling, TCP fragmentation could cause partial packets on the shadow connection, leading to protocol errors. With packet-aware handling, shadow workers receive complete valid packets, no protocol corruption occurs, and query counting tracks actual `COM_QUERY` commands rather than TCP reads.

```
Before (raw TCP):
  Client → [TCP seg 1] → Proxy → Shadow (partial packet - protocol error)
  Client → [TCP seg 2] → Proxy → Shadow (orphaned data - protocol error)

After (MySQL packets):
  Client → [TCP seg 1+2] → Proxy → [Complete Packet] → Shadow (valid query)
```

### Protocol-aware response parsing

The shadow worker uses MySQL protocol parsing to read complete responses without timeout-based detection:

1. **Response Type Detection**: First packet's payload byte indicates response type:
   - `0x00`: OK packet (single packet, done)
   - `0xFF`: ERR packet (single packet, done)
   - `0xFE`: EOF packet (single packet, done)
   - Other: Result set (column count follows)

2. **Result Set Parsing**: For result sets:
   - Read column definition packets (count from first packet)
   - Read EOF packet after column definitions
   - Read row packets until EOF/OK marker

This eliminates the need for timeout-based response detection, ensuring accurate latency measurements.

## MySQL-specific metrics

| Metric | Description |
|--------|-------------|
| `shadow_proxy_mysql_commands_total` | MySQL commands by type (labels: `target`, `command=COM_QUERY\|COM_STMT_EXECUTE\|...`) |
| `shadow_proxy_mysql_packets_total` | Total MySQL packets processed (labels: `target=primary\|shadow`) |

These metrics provide accurate query counting by tracking actual MySQL protocol commands rather than TCP operations. The shared `shadow_proxy_*` metrics (query duration, errors, bytes, etc.) documented in the [README](../README.md#metrics) apply to the MySQL path with `target="primary"` and `target="shadow"`.

## Local testing

### Without TLS

```bash
docker compose -f docker-compose.local.yaml up --build

# Run basic connectivity tests
./test-local.sh

# Run filter integration tests (4 phases: baseline, operation, pattern, include)
./test-filter-integration.sh
# or:
make test-filter
```

### With TLS

```bash
# Generate test certificates
./certs/generate-certs.sh

# Start with TLS
TLS_ENABLED=true docker compose -f docker-compose.local.yaml up --build

# Connect with SSL
mysql -h 127.0.0.1 -P 3306 -u root --ssl-mode=REQUIRED --ssl-ca=certs/ca.crt
```

## Kubernetes (minikube example)

The `minikube/` directory contains a complete working example with:

- Primary and shadow StarRocks clusters (via the StarRocks Operator)
- Shadow proxy deployment with TLS
- Prometheus and Grafana monitoring

See [`minikube/README.md`](../minikube/README.md) for setup instructions. Adapt the manifests for your production cluster.

**Typical production setup**:

1. **Create credentials secret**:

```bash
kubectl create secret generic shadow-proxy-credentials -n starrocks \
  --from-literal=PRIMARY_USER=root \
  --from-literal=PRIMARY_PASSWORD='<primary-password>' \
  --from-literal=SHADOW_USER=root \
  --from-literal=SHADOW_PASSWORD='<shadow-password>'
```

2. **Deploy the proxy** (adapt from `minikube/primary/shadow-proxy.yaml`)

3. **Connect through the proxy**:

```bash
LB_IP=$(kubectl get svc shadow-proxy-lb -n starrocks -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
mysql -h $LB_IP -P 9030 -u root --ssl-mode=REQUIRED
```

### TLS certificates

For TLS termination, mount PEM-format certificate and key files and set:

```bash
TLS_ENABLED=true
TLS_CERT_FILE=/certs/tls.crt
TLS_KEY_FILE=/certs/tls.key
```

Generate self-signed certificates for testing with `./certs/generate-certs.sh`.
