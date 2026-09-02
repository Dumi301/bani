// Bani signing proxy — Cloudflare Worker.
//
// Adds a short-lived RS256 JWT (per the Enable Banking API contract) to
// every proxied request so the private key never leaves this Worker.
// Pure logic (base64url, PEM decoding, JWT header/payload shape, route
// matching, the callback HTML) lives in ./core.mjs so it can be exercised
// by plain `node --test` — this file is just the fetch-handler glue plus
// the WebCrypto signing call, which needs a live runtime to test.

import {
  buildJwtHeader,
  buildJwtPayload,
  buildSigningInput,
  assembleJwt,
  isJwtFresh,
  isAuthorized,
  matchRoute,
  callbackHtml,
  pemToArrayBuffer,
} from "./core.mjs";

export interface Env {
  EB_APP_ID: string;
  EB_PRIVATE_KEY_PKCS8: string;
  DEVICE_TOKENS: string;
}

const UPSTREAM_BASE = "https://api.enablebanking.com";

// Per-isolate JWT cache (module scope survives across requests on a warm
// isolate, cleared on cold start — that's fine, we just re-sign).
let cachedJwt: { token: string; exp: number } | null = null;

async function getSignedJwt(env: Env): Promise<string> {
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (cachedJwt && isJwtFresh(cachedJwt.exp, nowSeconds)) {
    return cachedJwt.token;
  }

  const header = buildJwtHeader(env.EB_APP_ID);
  const payload = buildJwtPayload(nowSeconds);
  const signingInput = buildSigningInput(header, payload);

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(env.EB_PRIVATE_KEY_PKCS8),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput)
  );

  const token = assembleJwt(signingInput, signature);
  cachedJwt = { token, exp: payload.exp };
  return token;
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Log line only ever contains method + path + status — never headers,
// bodies, or tokens.
function log(method: string, pathname: string, status: number): void {
  console.log(`${method} ${pathname} ${status}`);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const { pathname, search } = url;
    const method = request.method;

    const route = matchRoute(method, pathname);

    if (route === "health") {
      log(method, pathname, 200);
      return jsonResponse({ ok: true }, 200);
    }

    if (route === "callback") {
      log(method, pathname, 200);
      return new Response(callbackHtml(), {
        status: 200,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    // Every other route requires a valid device token.
    if (!isAuthorized(request.headers.get("Authorization"), env.DEVICE_TOKENS)) {
      log(method, pathname, 401);
      return jsonResponse({ error: "unauthorized" }, 401);
    }

    if (route === "notfound") {
      log(method, pathname, 404);
      return jsonResponse({ error: "not_found" }, 404);
    }

    // route === "passthrough"
    let jwt: string;
    try {
      jwt = await getSignedJwt(env);
    } catch {
      log(method, pathname, 502);
      return jsonResponse({ error: "bad_gateway" }, 502);
    }

    const upstreamUrl = `${UPSTREAM_BASE}${pathname}${search}`;
    const hasBody = method === "POST";

    try {
      const upstreamResponse = await fetch(upstreamUrl, {
        method,
        headers: {
          Authorization: `Bearer ${jwt}`,
          ...(hasBody ? { "Content-Type": "application/json" } : {}),
        },
        body: hasBody ? await request.text() : undefined,
      });

      const bodyText = await upstreamResponse.text();
      log(method, pathname, upstreamResponse.status);
      return new Response(bodyText, {
        status: upstreamResponse.status,
        headers: {
          "Content-Type":
            upstreamResponse.headers.get("Content-Type") ?? "application/json",
        },
      });
    } catch {
      log(method, pathname, 502);
      return jsonResponse({ error: "bad_gateway" }, 502);
    }
  },
};
