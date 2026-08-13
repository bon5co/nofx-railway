# nofx-railway

NOFX (open-source AI trading platform) packaged for Railway as a single container.

Upstream: [NoFxAiOS/nofx](https://github.com/NoFxAiOS/nofx). This repo builds
`ghcr.io/bon5co/nofx-railway`, which merges upstream's backend and frontend images —
both pinned by digest — behind one nginx listener, and replaces upstream's Railway start
script (`railway/start.sh`) with `railway-entrypoint.sh`.

What the wrapper changes, and why:

| Change | Reason |
|---|---|
| Owner account seeded before the public port binds | `POST /api/register` creates the first account for whoever reaches it first and refuses everyone after ("System already initialized"), so an unclaimed instance is claimable by a stranger. |
| Password re-applied on every boot (`nofx reset-password`) | NOFX exposes no password reset over HTTP by design. Without this, the password can never be changed after the first boot. |
| Refuses to boot on an empty `JWT_SECRET` / admin password | `config.MustInit()` panics without `JWT_SECRET`, and upstream's Railway script keeps nginx alive afterwards — the dashboard and `/health` answer 200 while every `/api/*` call 502s. |
| `DATA_ENCRYPTION_KEY` and the RSA key persisted on the volume | Upstream generates both at boot when unset. They wrap every stored exchange API key and wallet key, and `crypto.go` returns the ciphertext unchanged when decryption fails, so rotating them silently corrupts stored credentials. |
| `DB_PATH=/app/data/data.db` | Upstream's default `DBPath` is the relative `data/data.db`. |
| `/health` proxied to the backend | Upstream's nginx returns a literal `200`, which cannot see a dead trading engine. |
| Both processes supervised | Upstream ends its script with `tail -f /dev/null`, so a backend crash leaves a running container serving static files forever. |
| `EXPERIENCE_IMPROVEMENT=false` | `telemetry/telemetry.go` posts trade events (exchange, symbol, USD size, leverage, user id) to Google Analytics and defaults to enabled. |

## Variables

| Variable | Required | Notes |
|---|---|---|
| `JWT_SECRET` | yes | 32+ characters. The container refuses to boot without it. |
| `NOFX_ADMIN_EMAIL` | yes | Owner account, created on first boot. |
| `NOFX_ADMIN_PASSWORD` | yes | 8+ characters. Changing it and redeploying rotates the password. |
| `DATA_ENCRYPTION_KEY` | no | Generated onto the volume when unset. |
| `RSA_PRIVATE_KEY` | no | Generated onto the volume when unset. |

Mount a volume at `/app/data`.
