# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this project, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, please email **security@trmlabs.com** with:

- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

We will acknowledge receipt within 48 hours and aim to provide a fix within 7 days for critical issues.

## Scope

This project handles database credentials and proxies SQL query traffic. Security-relevant areas include:

- **Credential handling**: Primary and shadow passwords are passed via environment variables. On the MySQL path they're used for MySQL native password authentication; on the pgwire path the proxy forwards the auth exchange (cleartext, MD5, or SCRAM-SHA-256) without terminating it.
- **TLS termination**: The proxy can terminate TLS for client connections. The MySQL path follows STARTTLS / `CLIENT_SSL` upgrade; the pgwire path responds to `SSLRequest` with `'S'` and wraps the connection in `tls.Server`. The backend hop can be TLS too — required against AlloyDB.
- **Query logging**: When enabled, full SQL query text is written to GCS -- users should be aware of potential PII in logged queries.
- **Network exposure**: The proxy listens on a TCP port and accepts MySQL or PostgreSQL wire-protocol connections (default `:3306` or `:5432` depending on `PROTOCOL`).

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Older releases | Best effort |
