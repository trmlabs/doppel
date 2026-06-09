# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Renamed**: project, binary, GHCR image, and Go module from
  `starrocks-shadow-proxy` to `doppel`. The proxy is no longer StarRocks-specific:
  it now supports both MySQL/StarRocks and pgwire (Postgres/AlloyDB) wire
  protocols with shared infrastructure. GitHub redirects keep old URLs working;
  the GHCR image `ghcr.io/trmlabs/starrocks-shadow-proxy` continues to exist for
  existing deployments, and the next tag will publish to `ghcr.io/trmlabs/doppel`.
- Docs refreshed for the multi-protocol scope (README, `docs/POSTGRES.md`).

### Added

- Postgres / pgwire proxy mode (`PROTOCOL=postgres`).
  - Hand-rolled pgwire v3 packet reader (no new external dependencies).
  - Per-query timing via ReadyForQuery correlation; falls back to bidirectional
    `io.Copy` for COPY connections.
  - Async shadow mirroring via `PgShadowWorker` honoring the same
    `SHADOW_FILTER_*` env vars as the MySQL path, plus a pgwire-specific
    sticky-by-statement-name filter for extended-query-protocol coherence.
  - Listener-side TLS termination (`TLS_ENABLED=true`) and independent
    backend-side TLS initiation (`PRIMARY_TLS_ENABLED=true`). Backend TLS
    is required against AlloyDB.
  - Per-connection sample rate (`SHADOW_SAMPLE_RATE` evaluated once at
    connection start, not per frame) to avoid breaking prepared-statement
    sessions when filtering.
  - New Prometheus metrics: `shadow_proxy_pg_commands_total`,
    `shadow_proxy_pg_packets_total`,
    `shadow_proxy_pg_sticky_stmt_map_resets_total`. Existing
    query-duration / query-error / bytes metrics are reused with
    `target="primary"` and `target="shadow"`.
  - `docker-compose.pg.yaml` for local testing against `postgres:15` (primary)
    and `postgres:18` (shadow) — wire-compatible with AlloyDB Omni.
  - `docker-compose.pg-tls.yaml` + `test-pg-local-tls.sh` for testing both
    TLS hops end-to-end.
  - `test-pg-local.sh` smoke test exercising simple + extended-protocol queries.
  - Docs: `docs/POSTGRES.md` describing behavior, env vars, design tradeoffs,
    shadow filtering semantics, and a TLS-path CPU-profile breakdown.

## [1.0.0] - 2026-03-23

Initial open-source release.

### Features

- MySQL wire-protocol proxy with packet-level forwarding (no TCP fragmentation on shadow)
- 1:1 shadow worker per client connection with bounded queue (10K packets) and backpressure
- TLS termination for client connections (MySQL protocol SSL upgrade / STARTTLS)
- Optional TLS for shadow connections (proxy as TLS client)
- Protocol-aware response parsing for accurate latency measurement
- Graceful drain on client disconnect (configurable timeout, default 60s)
- Prometheus metrics: latency histograms, query counts, error rates, connection stats, queue depth
- Optional per-query logging to GCS as JSONL with Hive-style partitioning (for BigQuery or other analytics)
- Health and readiness endpoints (`/health`, `/ready`, `/status`)
- Docker Compose environments for local testing (with and without TLS)
- Minikube setup for Kubernetes testing with StarRocks Operator
- Grafana dashboard for monitoring
