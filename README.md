# doppel

[![CI](https://github.com/trmlabs/doppel/actions/workflows/ci.yml/badge.svg)](https://github.com/trmlabs/doppel/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Go Version](https://img.shields.io/github/go-mod/go-version/trmlabs/doppel)](go.mod)

A wire-protocol-aware proxy that mirrors database traffic from a primary backend to a shadow backend, for upgrade validation, performance comparison, and migration testing.

| Wire protocol | Backends | Default port | Docs |
|---|---|---|---|
| MySQL | StarRocks, MySQL | `3306` | [docs/STARROCKS.md](docs/STARROCKS.md) |
| pgwire | Postgres, AlloyDB | `5432` | [docs/POSTGRES.md](docs/POSTGRES.md) |

Pick the protocol with `PROTOCOL=mysql` (default) or `PROTOCOL=postgres` (aliases: `pg`, `postgresql`).

## Why

Upgrading or migrating a database — StarRocks 3.1 → 3.3, Postgres 15 → 18, an AlloyDB minor — is risky without observing real production traffic against the candidate. Doppel lets you:

- **Compare performance** between versions before cutting over
- **Validate configuration or schema changes** on a shadow cluster with real traffic
- **Catch regressions** by collecting P50/P90/P99 latency on both primary and shadow
- **Record per-query traces** to GCS for offline analysis in BigQuery

The proxy is transparent to clients — they connect to it exactly as they would to the primary. Queries hit the primary synchronously (zero added latency on the critical path) and are mirrored asynchronously to the shadow.

## Quick start

**MySQL / StarRocks** — full deep dive in [docs/STARROCKS.md](docs/STARROCKS.md):

```bash
docker compose -f docker-compose.local.yaml up --build
mysql -h 127.0.0.1 -P 3306 -u root -e "SELECT 1"
```

**Postgres / AlloyDB** — full deep dive in [docs/POSTGRES.md](docs/POSTGRES.md):

```bash
docker compose -f docker-compose.pg.yaml up --build
PGPASSWORD=trmlabs psql "host=127.0.0.1 port=5432 user=postgres dbname=trm" -c "SELECT 1"
```

## Features

- **Wire-protocol aware**: MySQL (StarRocks, MySQL) and pgwire (Postgres, AlloyDB)
- **TLS termination**: MySQL SSL upgrade (STARTTLS) and pgwire SSLRequest, with independent listener-side and backend-side TLS
- **Zero-latency mirroring**: forwards queries to primary synchronously, mirrors to shadow asynchronously
- **1:1 shadow workers** per client with bounded queue (10K frames) and graceful drain
- **Selective shadow mirroring**: include/exclude filters by SQL operation, regex pattern, or per-connection sampling
- **Prometheus metrics**: P50/P90/P95/P99 latency histograms, query counts, error rates, queue depth
- **Query logging**: optional per-query JSONL log to GCS with Hive-style partitioning for BigQuery analysis
- **Transparent to clients**: connect as you would to the primary directly

## Metrics

All metrics use the `shadow_proxy_` prefix. The tables below cover the shared counters; protocol-specific metrics (`shadow_proxy_mysql_*`, `shadow_proxy_pg_*`) are documented in [docs/STARROCKS.md](docs/STARROCKS.md#mysql-specific-metrics) and [docs/POSTGRES.md](docs/POSTGRES.md#metrics).

### Core

| Metric | Description |
|--------|-------------|
| `shadow_proxy_query_duration_seconds` | Query latency histogram (labels: `target=primary\|shadow`) |
| `shadow_proxy_queries_total` | Total query count (labels: `target=primary\|shadow`) |
| `shadow_proxy_query_errors_total` | Total error count (labels: `target=primary\|shadow`) |
| `shadow_proxy_active_connections` | Current active connections |
| `shadow_proxy_connections_total` | Total connections accepted |

### Connection & auth

| Metric | Description |
|--------|-------------|
| `shadow_proxy_connection_failures_total` | Connection failures (labels: `target=primary\|shadow`) |
| `shadow_proxy_auth_failures_total` | Authentication failures (labels: `target=shadow`) |
| `shadow_proxy_connections_with_shadow_total` | Connections successfully mirroring to shadow |
| `shadow_proxy_connections_without_shadow_total` | Connections that fell back to primary-only |

### Shadow I/O

| Metric | Description |
|--------|-------------|
| `shadow_proxy_read_timeouts_total` | Shadow read timeouts |
| `shadow_proxy_drain_timeouts_total` | Shadow drain timeouts |
| `shadow_proxy_write_errors_total` | Shadow write errors |
| `shadow_proxy_bytes_total` | Bytes transferred (labels: `target`, `direction=sent\|received`) |

### TLS, health, worker

| Metric | Description |
|--------|-------------|
| `shadow_proxy_tls_upgrades_total` | Successful TLS upgrades |
| `shadow_proxy_tls_failures_total` | TLS handshake failures |
| `shadow_proxy_primary_up` | Primary cluster reachable (1=up, 0=down) |
| `shadow_proxy_shadow_up` | Shadow cluster reachable (1=up, 0=down) |
| `shadow_proxy_queue_drops_total` | Queries dropped due to full shadow queue |
| `shadow_proxy_queue_depth` | Current queue depth (sum across all workers) |
| `shadow_proxy_shadow_dropped_total` | Queries dropped before reaching the shadow (labels: `reason=conn_dead\|...`) |

## Query logging (GCS → BigQuery)

The proxy can log per-query execution details to GCS for later analysis in BigQuery. This enables per-query latency comparison, query-pattern analysis, and historical trend analysis across primary and shadow. The logger is shared between both protocols.

### How it works

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Shadow Proxy                                     │
│                                                                               │
│  Query arrives ──> Generate UUID ──> Forward to Primary ──> Log primary time │
│                         │                                                     │
│                         └──> Queue for Shadow ──> Process async ──> Log shadow│
│                                                                    time       │
│                                     │                                         │
│                           [In-memory buffer]                                  │
│                           (channel, 10K entries)                              │
│                                     │                                         │
│                           Every 2 min OR 1000 entries                         │
│                                     │                                         │
│                                     ▼                                         │
│                           Flush to GCS as JSONL                               │
└──────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  GCS Bucket (Hive-style partitioning)                                        │
│                                                                               │
│  gs://bucket/query-logs/                                                      │
│    └── year=2026/                                                             │
│        └── month=02/                                                          │
│            └── day=05/                                                        │
│                └── hour=14/                                                   │
│                    ├── 20260205_140000_a3f2b8c9.jsonl                        │
│                    └── ...                                                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Log entry schema

| Field | Type | Description |
|-------|------|-------------|
| `ts` | string | ISO8601 timestamp |
| `query_id` | string | UUID for correlating primary ↔ shadow entries |
| `target` | string | `"primary"` or `"shadow"` |
| `command` | string | MySQL command (`COM_QUERY`, `COM_PING`, …) on the MySQL path; pgwire frame name (`Query`, `Parse`, `Bind`, `Execute`, …) on the pgwire path |
| `query_text` | string | Full SQL query text (only for `COM_QUERY` / `Query` / `Parse`) |
| `duration_ms` | float | Execution time in milliseconds |
| `bytes_sent` | int | Bytes sent to target |
| `bytes_recv` | int | Bytes received from target |
| `success` | bool | Whether execution succeeded |
| `error` | string | Error message if failed |
| `client_addr` | string | Client IP address |
| `filtered` | bool | True when the row represents a query filtered out of the shadow path |
| `filter_reason` | string | Reason the query was filtered (`sql_operation`, `pattern`, `sampling`, `sticky_stmt`) |

Both primary and shadow entries share the **same `query_id`** for join-based latency comparison.

### BigQuery setup

```sql
CREATE EXTERNAL TABLE `project.dataset.query_logs`
(
  ts TIMESTAMP, query_id STRING, target STRING, command STRING,
  query_text STRING, duration_ms FLOAT64, bytes_sent INT64, bytes_recv INT64,
  success BOOL, error STRING, client_addr STRING, query_hash STRING,
  filtered BOOL, filter_reason STRING
)
WITH PARTITION COLUMNS (year STRING, month STRING, day STRING, hour STRING)
OPTIONS (
  format = 'JSON',
  uris = ['gs://your-bucket/query-logs/*'],
  hive_partition_uri_prefix = 'gs://your-bucket/query-logs/'
);
```

See [docs/usage-patterns.md](docs/usage-patterns.md) for example queries (slowdown detection, error-rate comparison, filtered-query analysis).

### Enabling

```bash
QUERY_LOG_GCS_BUCKET=your-bucket-name
QUERY_LOG_GCS_PREFIX=query-logs               # optional
QUERY_LOG_FLUSH_INTERVAL_SECONDS=120          # optional
QUERY_LOG_BATCH_SIZE=1000                     # optional
```

## Environment variables

The variables below apply to both protocols, except where labeled. Defaults can differ when `PROTOCOL=postgres` — for instance `LISTEN_ADDR` defaults to `:5432` and `PRIMARY_PORT` to `5432`. For protocol-specific TLS variables and behavioral notes, see [docs/STARROCKS.md](docs/STARROCKS.md) and [docs/POSTGRES.md](docs/POSTGRES.md).

### Protocol selection

| Variable | Description | Default |
|----------|-------------|---------|
| `PROTOCOL` | `mysql` (default) or `postgres` / `pg` / `postgresql` | `mysql` |

### Connection

| Variable | Description | Default |
|----------|-------------|---------|
| `PRIMARY_HOST` | Primary backend host | (required) |
| `PRIMARY_PORT` | Primary backend port | `9030` (mysql) / `5432` (pg) |
| `PRIMARY_USER` | Primary cluster username | `root` |
| `PRIMARY_PASSWORD` | Primary cluster password | (required for mysql) |
| `SHADOW_HOST` | Shadow backend host (empty disables shadow on pg path) | (required for mysql) |
| `SHADOW_PORT` | Shadow backend port | `9030` (mysql) / `5432` (pg) |
| `SHADOW_USER` | Shadow cluster username | `root` |
| `SHADOW_PASSWORD` | Shadow cluster password | (required for mysql) |
| `LISTEN_ADDR` | Proxy listen address | `:3306` (mysql) / `:5432` (pg) |
| `METRICS_PORT` | Prometheus metrics port | `:9090` |

### TLS

| Variable | Description | Default |
|----------|-------------|---------|
| `TLS_ENABLED` | Enable TLS termination for client connections | `false` |
| `TLS_CERT_FILE` | Path to TLS certificate | `/certs/tls.crt` |
| `TLS_KEY_FILE` | Path to TLS private key | `/certs/tls.key` |
| `PRIMARY_TLS_ENABLED` | (pgwire) Backend-side TLS initiation. Required against AlloyDB. | `false` |
| `PRIMARY_TLS_CA_FILE` | (pgwire) PEM bundle for verifying the backend cert. Empty = system roots. | `""` |
| `SHADOW_TLS_ENABLED` | Enable TLS for shadow connections | `false` |
| `SHADOW_TLS_INSECURE` | Skip cert verification (dev only — logs WARNING on startup) | `false` |

### Shadow queue & worker

| Variable | Description | Default |
|----------|-------------|---------|
| `SHADOW_QUEUE_SIZE` | Buffer size for shadow queue per worker | `10000` |
| `SHADOW_READ_TIMEOUT_SECONDS` | Timeout waiting for shadow response | `30` |
| `SHADOW_DRAIN_TIMEOUT_MS` | Timeout for draining queue on client disconnect | `60000` |
| `SHADOW_RESPONSE_DRAIN_TIMEOUT_MS` | Per-read timeout when draining shadow response | `100` |

### Query logging

| Variable | Description | Default |
|----------|-------------|---------|
| `QUERY_LOG_GCS_BUCKET` | GCS bucket for query logs (empty = disabled) | (disabled) |
| `QUERY_LOG_GCS_PREFIX` | Path prefix within bucket | `query-logs` |
| `QUERY_LOG_FLUSH_INTERVAL_SECONDS` | Flush interval (or when batch is full) | `120` |
| `QUERY_LOG_BATCH_SIZE` | Max entries before forced flush | `1000` |
| `QUERY_LOG_BUFFER_SIZE` | In-memory channel buffer size | `10000` |

### Shadow query filtering (selective mirroring)

By default, every query is mirrored. Selective control via include/exclude rules, optional regex on full SQL text, and optional random sampling.

| Variable | Description | Default |
|----------|-------------|---------|
| `SHADOW_FILTER_MODE` | `include` or `exclude`. Unset = disabled (mirror all). | (disabled) |
| `SHADOW_FILTER_SQL_OPERATIONS` | Comma-separated SQL operations. StarRocks-aware: `SELECT`, `INSERT_OVERWRITE`, `SUBMIT_TASK`, `CREATE_MATERIALIZED_VIEW`, etc. | (empty) |
| `SHADOW_FILTER_PATTERNS` | Comma-separated Go regex patterns matched against full query text. | (empty) |
| `SHADOW_SAMPLE_RATE` | Fraction of queries (mysql) / connections (pgwire) to shadow. `0.0`–`1.0`. | `1.0` |

**Filter logic**:
- **Include mode**: query must match ALL configured criteria (operations AND patterns). Within each, OR logic applies.
- **Exclude mode**: query is blocked if it matches ANY criterion.
- **Sampling** is applied last. On the pgwire path, the roll is evaluated once per client connection (not per frame) to avoid breaking prepared-statement sessions.

**Examples**:

```bash
# Only shadow SELECT queries
SHADOW_FILTER_MODE=include
SHADOW_FILTER_SQL_OPERATIONS=SELECT

# Shadow everything except heavy ETL writes
SHADOW_FILTER_MODE=exclude
SHADOW_FILTER_SQL_OPERATIONS=INSERT_OVERWRITE,SUBMIT_TASK

# Shadow 10% of all queries (load testing)
SHADOW_SAMPLE_RATE=0.1
```

**Metrics**: `shadow_proxy_shadow_filtered_total{reason="sql_operation|pattern|sampling|sticky_stmt"}`.

**GCS logging**: when query logging is enabled, filtered queries are logged with `target=shadow`, `filtered=true`, and `filter_reason` so every primary entry has a corresponding shadow entry for BigQuery correlation analysis.

## Development

### Project structure

The source is a single `package main` split into focused files:

| File | Purpose |
|---|---|
| `main.go` | Entry point — config, health checks, HTTP server, signal handling |
| `config.go` | `Config` struct, env var loading |
| `metrics.go` | Prometheus metric declarations, registry, worker registry |
| `mysql_protocol.go` | MySQL constants, command helpers, `MySQLPacketReader` |
| `mysql_auth.go` | SSL/TLS detection, handshake modification, scramble extraction |
| `shadow_worker.go` | `ShadowWorker` — per-client queue, async mirroring (MySQL) |
| `proxy.go` | `TCPProxy` — connection handling, SSL upgrade, auth (MySQL) |
| `pg_main.go` | pgwire entry point — wired from `main.go` when `PROTOCOL=postgres` |
| `pg_protocol.go` | pgwire constants, frame reader |
| `pg_tls.go` | Listener-side and backend-side TLS handshake helpers |
| `pg_proxy.go` | `PgProxy` — pgwire connection handling, request/response loop, COPY fallback |
| `pg_shadow_worker.go` | `PgShadowWorker` — async mirroring for pgwire |
| `pg_shadow_filter.go` | pgwire shadow filter (sticky-by-statement-name) |
| `query_filter.go` | Protocol-agnostic filter API (StarRocks-aware SQL parsing) |
| `query_logger.go` | Async batched query logging to GCS (JSONL, Hive-partitioned) |

Test files mirror source files (e.g. `proxy.go` → `proxy_test.go`).

### Build & test

```bash
make build           # local binary
make test-unit       # fast unit tests (skips integration)
make test            # all tests with race detection
make test-coverage   # with coverage report
make docker-build    # Docker image
```

### Local testing

For protocol-specific local-testing recipes, see:
- MySQL / StarRocks: [docs/STARROCKS.md#local-testing](docs/STARROCKS.md#local-testing)
- Postgres / AlloyDB: [docs/POSTGRES.md#local-testing](docs/POSTGRES.md#local-testing)

## Deployment

### Docker

```bash
# MySQL / StarRocks
docker run -d \
  -e PRIMARY_HOST=primary-starrocks-fe \
  -e PRIMARY_PASSWORD=secret \
  -e SHADOW_HOST=shadow-starrocks-fe \
  -e SHADOW_PASSWORD=secret \
  -p 3306:3306 \
  -p 9090:9090 \
  ghcr.io/trmlabs/doppel:latest

# Postgres / AlloyDB
docker run -d \
  -e PROTOCOL=postgres \
  -e PRIMARY_HOST=primary-db.example.com \
  -e PRIMARY_TLS_ENABLED=true \
  -e SHADOW_HOST=shadow-db.example.com \
  -e SHADOW_TLS_ENABLED=true \
  -p 5432:5432 \
  -p 9090:9090 \
  ghcr.io/trmlabs/doppel:latest
```

### Kubernetes

A full minikube example for the MySQL/StarRocks path (operator-based StarRocks clusters, proxy with TLS, Prometheus + Grafana) is documented in [docs/STARROCKS.md#kubernetes-minikube-example](docs/STARROCKS.md#kubernetes-minikube-example).

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
