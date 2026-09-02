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

```
wrangler secret put EB_APP_ID
wrangler secret put EB_PRIVATE_KEY_PKCS8   # paste the full PKCS#8 PEM
wrangler secret put DEVICE_TOKENS          # comma-separated, e.g. tok1,tok2
```

The key from Enable Banking's documented `openssl genrsa` route is PKCS#1
(`-----BEGIN RSA PRIVATE KEY-----`). Convert before pasting (the worker's
WebCrypto import requires PKCS#8, `-----BEGIN PRIVATE KEY-----`):

```
openssl pkcs8 -topk8 -nocrypt -in private.key -out private.pkcs8.pem
```

Generate device tokens with e.g. `openssl rand -hex 24` (one per phone).

## Add a device token

Re-run `wrangler secret put DEVICE_TOKENS` with the full updated
comma-separated list (it's a full overwrite, not an append). Give the new
token to the app to store in Keychain alongside the Worker's base URL.

## Tests

`npm test` (= `node --test`), zero dependencies, no build step.
