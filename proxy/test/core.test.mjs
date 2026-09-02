import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, createPrivateKey } from "node:crypto";
import {
  bytesToBase64Url,
  stringToBase64Url,
  pemToArrayBuffer,
  buildJwtHeader,
  buildJwtPayload,
  buildSigningInput,
  assembleJwt,
  isJwtFresh,
  isAuthorized,
  matchRoute,
  callbackHtml,
} from "../src/core.mjs";

// ---- base64url (checked against Node's built-in base64url encoder) -------

test("stringToBase64Url matches Buffer's base64url encoding, no padding", () => {
  const cases = ["hello", "", "a", "Bani proxy", '{"iss":"enablebanking.com"}'];
  for (const s of cases) {
    assert.equal(stringToBase64Url(s), Buffer.from(s, "utf8").toString("base64url"));
    assert.ok(!stringToBase64Url(s).includes("="), "no padding");
    assert.ok(!stringToBase64Url(s).includes("+"), "no plus");
    assert.ok(!stringToBase64Url(s).includes("/"), "no slash");
  }
});

test("bytesToBase64Url matches Buffer's base64url encoding for arbitrary bytes", () => {
  const bytes = new Uint8Array([0xfb, 0xff, 0xbf, 0x00, 0x10, 0xab, 0xcd, 0xef]);
  assert.equal(bytesToBase64Url(bytes), Buffer.from(bytes).toString("base64url"));
});

// ---- JWT header/payload/signing-input construction ------------------------

test("buildJwtHeader / buildJwtPayload produce the exact contract shape", () => {
  const header = buildJwtHeader("app-123");
  assert.deepEqual(header, { typ: "JWT", alg: "RS256", kid: "app-123" });

  const iat = 1700000000;
  const payload = buildJwtPayload(iat);
  assert.deepEqual(payload, {
    iss: "enablebanking.com",
    aud: "api.enablebanking.com",
    iat: 1700000000,
    exp: 1700003600,
  });
});

test("buildSigningInput base64url-encodes header.payload against fixed inputs", () => {
  const header = { typ: "JWT", alg: "RS256", kid: "app-123" };
  const payload = {
    iss: "enablebanking.com",
    aud: "api.enablebanking.com",
    iat: 1700000000,
    exp: 1700003600,
  };
  const expected =
    Buffer.from(JSON.stringify(header), "utf8").toString("base64url") +
    "." +
    Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");

  assert.equal(buildSigningInput(header, payload), expected);
});

// ---- PEM -> ArrayBuffer ----------------------------------------------------

test("pemToArrayBuffer decodes PKCS8 PEM to the exact same DER bytes Node's own parser produces", () => {
  const { privateKey } = generateKeyPairSync("rsa", {
    modulusLength: 2048,
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });

  const decoded = Buffer.from(pemToArrayBuffer(privateKey));
  const expectedDer = createPrivateKey(privateKey).export({ format: "der", type: "pkcs8" });

  assert.ok(decoded.equals(expectedDer), "decoded bytes must match Node's DER export byte-for-byte");
});

test("end-to-end: pemToArrayBuffer + WebCrypto sign/verify round-trip works", async () => {
  const { privateKey, publicKey } = generateKeyPairSync("rsa", {
    modulusLength: 2048,
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });

  const header = buildJwtHeader("app-abc");
  const payload = buildJwtPayload(Math.floor(Date.now() / 1000));
  const signingInput = buildSigningInput(header, payload);

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(privateKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput)
  );

  const jwt = assembleJwt(signingInput, signature);
  const parts = jwt.split(".");
  assert.equal(parts.length, 3);

  const pubDer = Buffer.from(
    publicKey.split("\n").filter((l) => l && !l.startsWith("-----")).join(""),
    "base64"
  );
  const verifyKey = await crypto.subtle.importKey(
    "spki",
    pubDer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"]
  );
  const isValid = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    verifyKey,
    signature,
    new TextEncoder().encode(signingInput)
  );
  assert.equal(isValid, true);
});

// ---- JWT cache freshness ----------------------------------------------------

test("isJwtFresh honours the 300s refresh margin", () => {
  assert.equal(isJwtFresh(1000, 100), true);
  assert.equal(isJwtFresh(1000, 699), true); // 699 < 700
  assert.equal(isJwtFresh(1000, 700), false); // exactly at the margin -> refresh
  assert.equal(isJwtFresh(1000, 999), false);
});

// ---- device-token auth -------------------------------------------------------

test("isAuthorized validates Bearer token against the DEVICE_TOKENS csv", () => {
  assert.equal(isAuthorized("Bearer abc", "abc,def"), true);
  assert.equal(isAuthorized("Bearer xyz", "abc,def"), false);
  assert.equal(isAuthorized(null, "abc,def"), false);
  assert.equal(isAuthorized(undefined, "abc,def"), false);
  assert.equal(isAuthorized("Basic abc", "abc,def"), false);
  assert.equal(isAuthorized("Bearer ", "abc,def"), false);
  assert.equal(isAuthorized("Bearer  abc ", " abc , def "), true);
  assert.equal(isAuthorized("Bearer abc", ""), false);
  assert.equal(isAuthorized("Bearer abc", undefined), false);
});

// ---- router -------------------------------------------------------------------

test("matchRoute classifies every contract path correctly (allowed vs 404)", () => {
  const cases = [
    ["GET", "/health", "health"],
    ["POST", "/health", "notfound"],
    ["GET", "/callback", "callback"],
    ["GET", "/aspsps", "passthrough"],
    ["POST", "/aspsps", "notfound"],
    ["POST", "/auth", "passthrough"],
    ["GET", "/auth", "notfound"],
    ["POST", "/sessions", "passthrough"],
    ["GET", "/sessions", "notfound"],
    ["GET", "/sessions/abc123", "passthrough"],
    ["DELETE", "/sessions/abc123", "passthrough"],
    ["POST", "/sessions/abc123", "notfound"],
    ["GET", "/sessions/", "notfound"],
    ["GET", "/accounts/uid-1/transactions", "passthrough"],
    ["POST", "/accounts/uid-1/transactions", "notfound"],
    ["GET", "/accounts/uid-1/transactions/extra", "notfound"],
    ["GET", "/accounts//transactions", "notfound"],
    ["GET", "/unknown", "notfound"],
    ["GET", "/", "notfound"],
  ];

  for (const [method, pathname, expected] of cases) {
    assert.equal(
      matchRoute(method, pathname),
      expected,
      `${method} ${pathname} should be "${expected}"`
    );
  }
});

// ---- /callback relay page -----------------------------------------------------

test("callbackHtml contains the exact bani://oauth/callback forward and a fallback link", () => {
  const html = callbackHtml();
  assert.match(html, /<!doctype html>/i);
  assert.ok(
    html.includes('location.replace("bani://oauth/callback?" + location.search.slice(1));'),
    "must forward via location.replace with the exact custom scheme"
  );
  assert.match(html, /href="bani:\/\/oauth\/callback"/);
  assert.match(html, /Return to Bani/);
});
