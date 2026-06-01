# Build stage
FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./

ARG TARGETOS TARGETARCH
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /doppel .

# Runtime stage
FROM alpine:3.21

LABEL org.opencontainers.image.source="https://github.com/trmlabs/doppel"
LABEL org.opencontainers.image.description="Wire-protocol-aware shadow proxy for MySQL/StarRocks and Postgres/AlloyDB"
LABEL org.opencontainers.image.license="Apache-2.0"

RUN apk --no-cache add ca-certificates

WORKDIR /app
COPY --from=builder /doppel .

RUN adduser -D -u 1000 appuser
USER appuser

EXPOSE 3306 9090

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:9090/health || exit 1

ENTRYPOINT ["./doppel"]
