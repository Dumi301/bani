// Pure, dependency-free helpers for the Bani signing proxy.
// Exported functions here have no I/O beyond WebCrypto (which itself is
// side-effect-free / deterministic-given-key) so they can be exercised
// directly by `node --test` without a Workers runtime. `src/index.ts`
// imports this module for its actual `fetch` handler.

const EB_ISSUER = "enablebanking.com";
const EB_AUDIENCE = "api.enablebanking.com";
const JWT_TTL_SECONDS = 3600;
const JWT_REFRESH_MARGIN_SECONDS = 300;

// ---- base64url ---------------------------------------------------------

/** @param {Uint8Array} bytes */
export function bytesToBase64Url(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  const b64 = btoa(binary);
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** @param {string} str */
export function stringToBase64Url(str) {
  return bytesToBase64Url(new TextEncoder().encode(str));
}

// ---- PEM -> ArrayBuffer -------------------------------------------------

/**
 * Decodes a PKCS#8 PEM string (as stored in the EB_PRIVATE_KEY_PKCS8
 * secret) into the raw DER ArrayBuffer that `crypto.subtle.importKey`
 * expects.
 * @param {string} pem
 * @returns {ArrayBuffer}
 */
export function pemToArrayBuffer(pem) {
  const b64 = pem
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith("-----"))
    .join("");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

// ---- JWT construction ----------------------------------------------------

/**
 * @param {string} kid - EB_APP_ID
 */
export function buildJwtHeader(kid) {
  return { typ: "JWT", alg: "RS256", kid };
}

/**
 * @param {number} iatSeconds - unix seconds
 */
export function buildJwtPayload(iatSeconds) {
  return {
    iss: EB_ISSUER,
    aud: EB_AUDIENCE,
    iat: iatSeconds,
    exp: iatSeconds + JWT_TTL_SECONDS,
  };
}

/**
 * The `<header>.<payload>` portion of the JWT that gets signed.
 * @param {object} header
 * @param {object} payload
 */
export function buildSigningInput(header, payload) {
  return `${stringToBase64Url(JSON.stringify(header))}.${stringToBase64Url(
    JSON.stringify(payload)
  )}`;
}

/**
 * @param {string} signingInput
 * @param {ArrayBuffer} signature
 */
export function assembleJwt(signingInput, signature) {
  return `${signingInput}.${bytesToBase64Url(new Uint8Array(signature))}`;
}

/**
 * Whether a cached JWT (with the given exp, unix seconds) is still usable,
 * i.e. more than JWT_REFRESH_MARGIN_SECONDS away from expiry.
 * @param {number} exp
 * @param {number} nowSeconds
 */
export function isJwtFresh(exp, nowSeconds) {
  return nowSeconds < exp - JWT_REFRESH_MARGIN_SECONDS;
}

// ---- device-token auth / tenant resolution --------------------------------

/**
 * Resolves which configured tenant an incoming request authenticates as.
 * Subsumes the old single-tenant `isAuthorized` check: a request is valid
 * only when its Bearer token appears in the resolved tenant's device-token
 * list.
 *
 * - No hint: the token must appear in exactly one tenant's list (the
 *   unique match wins); 0 or 2+ matches -> null.
 * - Hint present: parsed as a 1-based tenant number; must be a plain
 *   positive integer, in range, and the token must appear in that
 *   specific tenant's list -- otherwise null.
 *
 * @param {string | null | undefined} authHeader - raw `Authorization` header value
 * @param {string | null | undefined} tenantHint - raw `X-Bani-Tenant` header value (1-based); null/absent = auto-detect
 * @param {Array<{deviceTokensCsv?: string | null} | null | undefined>} tenants - tenant configs, index 0 = tenant 1 (unsuffixed secrets)
 * @returns {number | null} 0-based tenant index, or null on auth failure
 */
export function resolveTenant(authHeader, tenantHint, tenants) {
  if (!authHeader || !authHeader.startsWith("Bearer ")) return null;
  const token = authHeader.slice("Bearer ".length).trim();
  if (!token) return null;

  const list = tenants ?? [];
  const tokensOf = (tenant) =>
    (tenant?.deviceTokensCsv ?? "")
      .split(",")
      .map((t) => t.trim())
      .filter((t) => t.length > 0);

  if (tenantHint !== null && tenantHint !== undefined && tenantHint !== "") {
    if (!/^[0-9]+$/.test(tenantHint)) return null; // malformed (non-numeric)
    const idx = Number(tenantHint) - 1;
    if (idx < 0 || idx >= list.length) return null; // out of range
    return tokensOf(list[idx]).includes(token) ? idx : null;
  }

  let matchIndex = null;
  let matchCount = 0;
  for (let i = 0; i < list.length; i++) {
    if (tokensOf(list[i]).includes(token)) {
      matchIndex = i;
      matchCount++;
    }
  }
  return matchCount === 1 ? matchIndex : null;
}

// ---- router ---------------------------------------------------------------

/**
 * Classifies an incoming request per the v2.3 contract. Pure: no upstream
 * path rewriting happens here — passthrough routes forward the original
 * pathname + search verbatim, so this only needs to decide which bucket a
 * (method, pathname) pair falls into.
 * @param {string} method
 * @param {string} pathname
 * @returns {"health" | "callback" | "passthrough" | "notfound"}
 */
export function matchRoute(method, pathname) {
  if (method === "GET" && pathname === "/health") return "health";
  if (method === "GET" && pathname === "/callback") return "callback";

  if (method === "GET" && pathname === "/aspsps") return "passthrough";
  if (method === "POST" && pathname === "/auth") return "passthrough";
  if (method === "POST" && pathname === "/sessions") return "passthrough";
  if (
    (method === "GET" || method === "DELETE") &&
    /^\/sessions\/[^/]+$/.test(pathname)
  ) {
    return "passthrough";
  }
  if (method === "GET" && /^\/accounts\/[^/]+\/transactions$/.test(pathname)) {
    return "passthrough";
  }

  return "notfound";
}

// ---- /callback relay page --------------------------------------------------

/**
 * Static HTML/JS relay page. It reads `location.search` client-side so the
 * worker itself never needs to parse/re-encode the `code`/`state` query —
 * whatever the browser received is forwarded verbatim to the app.
 */
export function callbackHtml() {
  return `<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>Returning to Bani…</title>
  </head>
  <body>
    <p>Returning to Bani… <a id="fallback" href="bani://oauth/callback">Return to Bani</a></p>
    <script>
      location.replace("bani://oauth/callback?" + location.search.slice(1));
    </script>
  </body>
</html>`;
}
