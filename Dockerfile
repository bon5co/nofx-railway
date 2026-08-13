# NOFX packaged for Railway as a single container.
#
# Upstream ships two images (a Go backend and an nginx-served React frontend) plus a
# Railway all-in-one Dockerfile that merges them. This wrapper follows the same shape but
# pins both upstream images by digest, keeps every piece of durable state on the Railway
# volume, and replaces upstream's start script with one that supervises the backend,
# claims the instance before the public port ever binds, and generates the RSA key once
# instead of on every boot.
#
# Upstream images (linux/amd64), resolved 2026-08-13:
#   ghcr.io/nofxaios/nofx/nofx-backend:latest
#     sha256:e68372343bef1e96c6123009087b560617d66f4eda2176bea31996212e996ad7
#   ghcr.io/nofxaios/nofx/nofx-frontend:latest
#     sha256:37bd3ba93c2de5b2fb0d9df90b53c96a8265d27f98427180af01cab06476e6a2

FROM ghcr.io/nofxaios/nofx/nofx-backend@sha256:e68372343bef1e96c6123009087b560617d66f4eda2176bea31996212e996ad7 AS backend
FROM ghcr.io/nofxaios/nofx/nofx-frontend@sha256:37bd3ba93c2de5b2fb0d9df90b53c96a8265d27f98427180af01cab06476e6a2 AS frontend

FROM alpine:3.22

RUN apk add --no-cache ca-certificates tzdata sqlite nginx openssl curl

COPY --from=backend /app/nofx /app/nofx
COPY --from=backend /usr/local/lib/libta_lib* /usr/local/lib/
COPY --from=frontend /usr/share/nginx/html /usr/share/nginx/html

WORKDIR /app
RUN mkdir -p /app/data /run/nginx

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

# SQLite database on the Railway volume. Upstream defaults DBPath to a relative
# "data/data.db", which resolves under the ephemeral working directory.
ENV DB_PATH=/app/data/data.db \
    API_SERVER_PORT=8081 \
    HOST=0.0.0.0 \
    TZ=UTC \
    # Upstream defaults telemetry ON: telemetry/telemetry.go POSTs trade events
    # (exchange, symbol, USD size, leverage, user id) to Google Analytics.
    EXPERIENCE_IMPROVEMENT=false \
    # Browser-side encryption of API keys needs the page to be a secure context.
    # Railway serves the public domain over HTTPS, so this is safe to leave on.
    TRANSPORT_ENCRYPTION=true

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
