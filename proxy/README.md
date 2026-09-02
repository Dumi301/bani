# bani-proxy

Cloudflare Worker that signs requests to `api.enablebanking.com` with an
RS256 JWT so the EB private key never reaches the iOS app. Contract:
`../pipeline/prompts-v2.3/contract.md`.

## Deploy

```
cd proxy
wrangler deploy
```

## Secrets (set once per environment, never in code/wrangler.toml)

Multi-tenant: one tenant per Enable Banking application (e.g. one per family
member's bank). Tenant 1 keeps the original unsuffixed secret names;
tenant n>=2 uses a `_n` suffix. The worker reads tenants 1, 2, 3, ... at
request time and stops at the first missing `EB_APP_ID{_n}` (capped at 16).

```
wrangler secret put EB_APP_ID
wrangler secret put EB_PRIVATE_KEY_PKCS8   # paste the full PKCS#8 PEM
wrangler secret put DEVICE_TOKENS          # comma-separated, e.g. tok1,tok2

# tenant 2
wrangler secret put EB_APP_ID_2
wrangler secret put EB_PRIVATE_KEY_PKCS8_2
wrangler secret put DEVICE_TOKENS_2

# tenant 3, 4, ... follow the same _n pattern
```

A tenant needs all three of its secrets set to count — if any one is
missing, that slot is skipped (not treated as the end of the list, so a
gap doesn't hide later tenants).

The key from Enable Banking's documented `openssl genrsa` route is PKCS#1
(`-----BEGIN RSA PRIVATE KEY-----`). Convert before pasting (the worker's
WebCrypto import requires PKCS#8, `-----BEGIN PRIVATE KEY-----`):

```
openssl pkcs8 -topk8 -nocrypt -in private.key -out private.pkcs8.pem
```

Generate device tokens with e.g. `openssl rand -hex 24` (one per phone).

## Add a device token

Re-run `wrangler secret put DEVICE_TOKENS` (or `DEVICE_TOKENS_n` for tenant
n) with the full updated comma-separated list (it's a full overwrite, not an
append). Give the new token to the app to store in Keychain alongside the
Worker's base URL.

## Multi-tenant auth (`X-Bani-Tenant`)

A device token may legitimately be listed under more than one tenant (one
phone, several bank apps). Every request still sends
`Authorization: Bearer <deviceToken>`; when the token is ambiguous across
tenants, the app must also send `X-Bani-Tenant: <n>` (1-based tenant number,
matching the secret suffix — tenant 1 has no suffix).

- Token unique to one tenant, no header: resolves automatically.
- Token listed in 2+ tenants, no header: `401 {"error":"unauthorized"}`.
- Header present: must be a plain positive integer, in range, and the token
  must be in *that* tenant's list — otherwise `401`.

## Tests

`npm test` (= `node --test`), zero dependencies, no build step.
