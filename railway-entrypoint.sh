#!/bin/sh
# NOFX on Railway: boot the backend, claim the instance, then open the public port.
#
# Ordering matters. NOFX registers the first account that reaches
# POST /api/auth/register and refuses every later one ("System already initialized"),
# so the public listener must not exist until the deployer's own account is in place.
set -eu

DATA_DIR=${DATA_DIR:-/app/data}
BACKEND_PORT=${API_SERVER_PORT:-8081}
PUBLIC_PORT=${PORT:-8080}

mkdir -p "$DATA_DIR"

die() {
    echo "[nofx] FATAL: $1" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
# NOFX refuses to boot without JWT_SECRET (config/config.go MustInit panics), and
# upstream's own Railway start script does not generate one -- it only generates the
# two encryption keys. A deploy that leaves this blank therefore serves the dashboard
# from nginx while the API is dead, so fail loudly instead.
if [ -z "${JWT_SECRET:-}" ]; then
    die "JWT_SECRET is empty. Set it to a random 32+ character value and redeploy."
fi
if [ "${#JWT_SECRET}" -lt 32 ]; then
    die "JWT_SECRET must be at least 32 characters (got ${#JWT_SECRET})."
fi
export JWT_SECRET

# The AES data key and the RSA key wrap every exchange API key, wallet key and AI
# provider key NOFX stores. Upstream generates both at boot when unset, which means a
# redeploy silently invalidates everything already in the database -- decryption then
# fails and crypto.go hands the ciphertext back as if it were the plaintext value.
# Keep them on the volume so a redeploy keeps reading its own data.
if [ -z "${DATA_ENCRYPTION_KEY:-}" ]; then
    if [ ! -s "$DATA_DIR/data_encryption_key" ]; then
        openssl rand -base64 32 > "$DATA_DIR/data_encryption_key"
        chmod 600 "$DATA_DIR/data_encryption_key"
        echo "[nofx] generated a data encryption key on the volume"
    fi
    DATA_ENCRYPTION_KEY=$(cat "$DATA_DIR/data_encryption_key")
fi
export DATA_ENCRYPTION_KEY

if [ -z "${RSA_PRIVATE_KEY:-}" ]; then
    if [ ! -s "$DATA_DIR/rsa_private_key.pem" ]; then
        openssl genrsa -out "$DATA_DIR/rsa_private_key.pem" 2048 2>/dev/null
        chmod 600 "$DATA_DIR/rsa_private_key.pem"
        echo "[nofx] generated an RSA transport key on the volume"
    fi
    RSA_PRIVATE_KEY=$(cat "$DATA_DIR/rsa_private_key.pem")
fi
export RSA_PRIVATE_KEY

ADMIN_EMAIL=${NOFX_ADMIN_EMAIL:-}
ADMIN_PASSWORD=${NOFX_ADMIN_PASSWORD:-}
[ -n "$ADMIN_EMAIL" ] || die "NOFX_ADMIN_EMAIL is empty. Set it and redeploy."
[ -n "$ADMIN_PASSWORD" ] || die "NOFX_ADMIN_PASSWORD is empty. Set it and redeploy."
if [ "${#ADMIN_PASSWORD}" -lt 8 ]; then
    die "NOFX_ADMIN_PASSWORD must be at least 8 characters (NOFX rejects shorter ones)."
fi

# ---------------------------------------------------------------------------
# Password rotation
# ---------------------------------------------------------------------------
# On a database that already holds the owner account, re-apply the password from the
# environment so changing NOFX_ADMIN_PASSWORD and redeploying actually rotates it.
# NOFX exposes no password reset over HTTP by design (cli.go); the CLI works offline
# against the same SQLite file, so this runs before the server opens it.
SEEDED=0
if [ -s "$DB_PATH" ]; then
    if /app/nofx reset-password --email "$ADMIN_EMAIL" --password "$ADMIN_PASSWORD" >/dev/null 2>&1; then
        echo "[nofx] re-applied the password for $ADMIN_EMAIL"
        SEEDED=1
    fi
fi

# ---------------------------------------------------------------------------
# Backend
# ---------------------------------------------------------------------------
echo "[nofx] starting backend on 127.0.0.1:$BACKEND_PORT"
API_SERVER_PORT="$BACKEND_PORT" /app/nofx &
BACKEND_PID=$!

ready=0
i=0
while [ "$i" -lt 120 ]; do
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
        die "backend exited during startup -- see the log lines above this one."
    fi
    if curl -fsS -o /dev/null "http://127.0.0.1:$BACKEND_PORT/api/health" 2>/dev/null; then
        ready=1
        break
    fi
    i=$((i + 1))
    sleep 1
done
[ "$ready" -eq 1 ] || die "backend did not answer /api/health within 120s."
echo "[nofx] backend is up"

# ---------------------------------------------------------------------------
# Claim the instance before anything is reachable from the internet
# ---------------------------------------------------------------------------
if [ "$SEEDED" -eq 0 ]; then
    seed_body=$(printf '{"email":"%s","password":"%s","lang":"en"}' "$ADMIN_EMAIL" "$ADMIN_PASSWORD")
    seed_status=$(curl -s -o /tmp/nofx-seed.out -w '%{http_code}' \
        -X POST "http://127.0.0.1:$BACKEND_PORT/api/register" \
        -H 'Content-Type: application/json' \
        -d "$seed_body" || echo 000)
    case "$seed_status" in
        200|201)
            echo "[nofx] registered the owner account $ADMIN_EMAIL"
            ;;
        403)
            # "System already initialized": an account exists under a different
            # address than NOFX_ADMIN_EMAIL, so there is nothing safe to seed.
            echo "[nofx] an account already exists, leaving it alone"
            ;;
        *)
            die "could not register the owner account (HTTP $seed_status): $(cat /tmp/nofx-seed.out 2>/dev/null)"
            ;;
    esac
    rm -f /tmp/nofx-seed.out
fi

# ---------------------------------------------------------------------------
# Public listener
# ---------------------------------------------------------------------------
# /health proxies to the backend rather than returning a literal 200, so Railway's
# healthcheck fails when the trading engine is down instead of reporting a green
# deployment that only serves static files.
cat > /etc/nginx/http.d/default.conf <<NGINX_EOF
server {
    listen $PUBLIC_PORT;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    client_max_body_size 20m;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:$BACKEND_PORT/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }

    location = /health {
        proxy_pass http://127.0.0.1:$BACKEND_PORT/api/health;
        proxy_set_header Host \$host;
    }
}
NGINX_EOF

echo "[nofx] serving on port $PUBLIC_PORT"
nginx -g 'daemon off;' &
NGINX_PID=$!

# Supervise. Upstream ends its script with `tail -f /dev/null`, so a backend crash
# leaves the container running and the deploy healthy forever; here either process
# dying takes the container down and Railway restarts it.
term() {
    kill "$BACKEND_PID" "$NGINX_PID" 2>/dev/null || true
    exit 0
}
trap term TERM INT

while true; do
    if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
        echo "[nofx] backend exited -- stopping the container" >&2
        kill "$NGINX_PID" 2>/dev/null || true
        exit 1
    fi
    if ! kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "[nofx] nginx exited -- stopping the container" >&2
        kill "$BACKEND_PID" 2>/dev/null || true
        exit 1
    fi
    sleep 5
done
