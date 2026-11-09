#!/usr/bin/env node
// OpenClaw <-> Omarchy bridge.
//
// Speaks newline-delimited JSON on stdin/stdout with Service.qml. The QML side
// never talks WebSocket directly: this process owns the Gateway connection,
// pairing, device token, session subscriptions, and transcript refreshes.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { pathToFileURL } from "node:url";

const VERSION = "0.1.0";
const HOME = os.homedir();
const STATE_DIR = process.env.OC_STATE_DIR || path.join(HOME, ".local", "state", "omarchy-openclaw");
const TOKENS_FILE = path.join(STATE_DIR, "tokens.json");
const IDENTITY_FILE = path.join(STATE_DIR, "identity.json");
const AVATAR_DIR = path.join(STATE_DIR, "avatars");
const MAX_SESSIONS = clampInt(process.env.OC_MAX_SESSIONS, 20, 3, 100);
const HISTORY_LIMIT = 80;
const MAIN_ONLY = process.env.OC_MAIN_ONLY === "1";

fs.mkdirSync(STATE_DIR, { recursive: true });
fs.mkdirSync(AVATAR_DIR, { recursive: true });

// ---------------------------------------------------------------- output

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function log(...args) {
  process.stderr.write(`[openclaw] ${args.join(" ")}\n`);
}

function clampInt(raw, fallback, min, max) {
  const value = Number.parseInt(String(raw ?? ""), 10);
  if (!Number.isFinite(value)) return fallback;
  return Math.max(min, Math.min(max, value));
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJsonPrivate(file, value) {
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

function truncate(value, max = 512) {
  const text = String(value ?? "");
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

// ---------------------------------------------------------------- config

function loadGatewayConfig() {
  const configPath =
    process.env.OPENCLAW_CONFIG_PATH || path.join(HOME, ".openclaw", "openclaw.json");
  const config = readJson(configPath, {});
  const remote = config?.gateway?.remote ?? {};
  const auth = config?.gateway?.auth ?? {};
  const url = String(
    process.env.OC_GATEWAY_URL || remote.url || config?.gateway?.url || "ws://127.0.0.1:18789",
  ).trim();
  const token = String(
    process.env.OC_GATEWAY_TOKEN || remote.token || auth.token || "",
  ).trim();
  return { url, token, configPath };
}

// ---------------------------------------------------------------- identity

function readOpenClawIdentity() {
  const candidates = [];
  const stateRoot = process.env.OPENCLAW_STATE_DIR;
  if (stateRoot) {
    candidates.push(path.join(stateRoot, "state", "openclaw.sqlite"));
    candidates.push(path.join(stateRoot, "openclaw.sqlite"));
  }
  candidates.push(path.join(HOME, ".openclaw", "state", "openclaw.sqlite"));

  for (const databasePath of candidates) {
    if (!fs.existsSync(databasePath)) continue;
    try {
      // node:sqlite is available in Node 22.5+. The desktop already runs Node
      // 24/26 for OpenClaw itself.
      const { DatabaseSync } = requireNodeSqlite();
      const db = new DatabaseSync(databasePath, { readOnly: true });
      try {
        const row = db
          .prepare(
            "select device_id, public_key_pem, private_key_pem from device_identities where identity_key = 'primary' limit 1",
          )
          .get();
        if (!row?.device_id || !row?.public_key_pem || !row?.private_key_pem) continue;
        return {
          deviceId: String(row.device_id),
          publicKeyPem: String(row.public_key_pem),
          privateKeyPem: String(row.private_key_pem),
          source: "openclaw",
        };
      } finally {
        db.close();
      }
    } catch (error) {
      log(`identity read skipped: ${error?.message ?? error}`);
    }
  }
  return null;
}

let nodeSqlite;
function requireNodeSqlite() {
  if (!nodeSqlite) {
    // Synchronous require keeps the identity bootstrap simple.
    nodeSqlite = process.getBuiltinModule
      ? process.getBuiltinModule("node:sqlite")
      : null;
    if (!nodeSqlite) throw new Error("node:sqlite is unavailable");
  }
  return nodeSqlite;
}

function loadIdentity() {
  const fromOpenClaw = readOpenClawIdentity();
  if (fromOpenClaw) return fromOpenClaw;

  const stored = readJson(IDENTITY_FILE, null);
  if (stored?.deviceId && stored?.publicKeyPem && stored?.privateKeyPem) {
    return { ...stored, source: "plugin" };
  }

  const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");
  const publicKeyPem = publicKey.export({ type: "spki", format: "pem" }).toString();
  const privateKeyPem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
  const rawPublicKey = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
  const deviceId = crypto.createHash("sha256").update(rawPublicKey).digest("hex");
  const identity = { deviceId, publicKeyPem, privateKeyPem };
  writeJsonPrivate(IDENTITY_FILE, identity);
  return { ...identity, source: "plugin" };
}

const identity = loadIdentity();
log(`identity ${identity.source} ${identity.deviceId.slice(0, 12)}`);

// ---------------------------------------------------------------- token store

const tokenKey = (deviceId, role) => `${deviceId}:${role}`;
let tokens = readJson(TOKENS_FILE, {});

function loadDeviceAuthToken({ deviceId, role }) {
  const record = tokens[tokenKey(deviceId, role)];
  return record?.token ? record : null;
}

function storeDeviceAuthToken({ deviceId, role, token, scopes, expectedToken, signal, assertCurrent }) {
  signal?.throwIfAborted();
  assertCurrent?.();
  const key = tokenKey(deviceId, role);
  const current = tokens[key];
  if (expectedToken !== undefined) {
    if (expectedToken === null && current) return;
    if (typeof expectedToken === "string" && current?.token !== expectedToken) return;
  }
  tokens[key] = { token, scopes: Array.isArray(scopes) ? scopes : [] };
  signal?.throwIfAborted();
  assertCurrent?.();
  writeJsonPrivate(TOKENS_FILE, tokens);
}

function clearDeviceAuthToken({ deviceId, role, expectedToken, signal, assertCurrent }) {
  signal?.throwIfAborted();
  assertCurrent?.();
  const key = tokenKey(deviceId, role);
  const current = tokens[key];
  if (typeof expectedToken === "string" && current?.token !== expectedToken) return;
  if (!current) return;
  delete tokens[key];
  writeJsonPrivate(TOKENS_FILE, tokens);
}

// ---------------------------------------------------------------- gateway client

let GatewayClientConstructor = null;

async function loadGatewayClient() {
  if (GatewayClientConstructor) return GatewayClientConstructor;

  try {
    const mod = await import("@openclaw/gateway-client");
    if (typeof mod.GatewayClient === "function") {
      GatewayClientConstructor = mod.GatewayClient;
      return GatewayClientConstructor;
    }
  } catch {
    // Fall through to the copy bundled with the local OpenClaw install.
  }

  for (const root of findOpenClawRoots()) {
    const dist = path.join(root, "dist");
    if (!fs.existsSync(dist)) continue;
    let files = [];
    try {
      files = fs.readdirSync(dist).filter((name) => /^client-.*\.mjs$/.test(name));
    } catch {
      continue;
    }
    for (const name of files) {
      try {
        const mod = await import(pathToFileURL(path.join(dist, name)).href);
        const candidate = mod.GatewayClient ?? mod.t;
        if (typeof candidate === "function") {
          GatewayClientConstructor = candidate;
          log(`using OpenClaw client from ${path.join(dist, name)}`);
          return GatewayClientConstructor;
        }
      } catch {
        // Try the next hashed build file.
      }
    }
  }

  throw new Error(
    "Client Gateway OpenClaw introuvable. Installe OpenClaw ou lance « npm install » dans le dossier du plugin.",
  );
}

function findOpenClawRoots() {
  const roots = [];
  const add = (candidate) => {
    if (!candidate) return;
    try {
      if (fs.existsSync(path.join(candidate, "dist")) && !roots.includes(candidate)) roots.push(candidate);
    } catch {
      // ignore
    }
  };

  add(process.env.OPENCLAW_PACKAGE_ROOT);

  const toolsDir = path.join(HOME, ".openclaw", "tools");
  try {
    for (const entry of fs.readdirSync(toolsDir)) {
      add(path.join(toolsDir, entry, "lib", "node_modules", "openclaw"));
    }
  } catch {
    // ignore
  }

  add(path.join(HOME, ".openclaw", "node_modules", "openclaw"));
  add("/usr/lib/node_modules/openclaw");
  add("/usr/local/lib/node_modules/openclaw");
  return roots;
}

// ---------------------------------------------------------------- state

let client = null;
let generation = 0;
let connected = false;
let pairing = null;
let sessions = new Map();
let agentIdentities = new Map();
let agentFetching = new Set();
let selectedKey = "";
let reconnectTimer = null;
let refreshTimer = null;
let historyTimer = null;
let sendingRunId = null;

const listParams = {
  limit: MAX_SESSIONS,
  ownerFirst: true,
  sortBy: "activity",
};

const filteredListParams = {
  ...listParams,
  excludeSubagents: true,
  excludeCron: true,
  excludeSystem: true,
  excludeDock: true,
};

function clearTimer(timer) {
  if (timer) clearTimeout(timer);
  return null;
}

function scheduleReconnect(delayMs = 8000) {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delayMs);
}

function scheduleRefreshSessions(delayMs = 250) {
  if (refreshTimer) return;
  refreshTimer = setTimeout(() => {
    refreshTimer = null;
    refreshSessions().catch((error) => log(`refresh failed: ${error?.message ?? error}`));
  }, delayMs);
}

function scheduleHistory(delayMs = 600) {
  if (historyTimer) clearTimeout(historyTimer);
  historyTimer = setTimeout(() => {
    historyTimer = null;
    if (selectedKey) {
      sendHistory(selectedKey).catch((error) =>
        emit({ type: "error", message: `Historique indisponible : ${error?.message ?? error}` }),
      );
    }
  }, delayMs);
}

// ---------------------------------------------------------------- connect

async function connect() {
  clearTimer(reconnectTimer);
  reconnectTimer = null;
  const thisGeneration = ++generation;

  if (client) {
    try {
      client.stop();
    } catch {
      // ignore
    }
    client = null;
  }

  connected = false;
  emit({ type: "status", status: "connecting" });

  const config = loadGatewayConfig();
  if (!config.url) {
    emit({ type: "error", message: "Aucune URL de gateway OpenClaw configurée." });
    scheduleReconnect(15000);
    return;
  }

  let GatewayClient;
  try {
    GatewayClient = await loadGatewayClient();
  } catch (error) {
    emit({ type: "error", message: error?.message ?? String(error) });
    scheduleReconnect(20000);
    return;
  }

  if (thisGeneration !== generation) return;

  try {
    client = new GatewayClient({
      url: config.url,
      token: config.token,
      clientName: "openclaw-linux",
      clientDisplayName: "Omarchy OpenClaw Shell",
      clientVersion: VERSION,
      mode: "ui",
      role: "operator",
      scopes: ["operator.read", "operator.write"],
      minProtocol: 4,
      maxProtocol: 4,
      deviceIdentity: {
        deviceId: identity.deviceId,
        publicKeyPem: identity.publicKeyPem,
        privateKeyPem: identity.privateKeyPem,
      },
      hostDeps: {
        loadDeviceAuthToken,
        storeDeviceAuthToken,
        clearDeviceAuthToken,
        signDevicePayload: (privateKeyPem, payload) =>
          crypto.sign(null, Buffer.from(payload, "utf8"), privateKeyPem).toString("base64url"),
        publicKeyRawBase64UrlFromPem: (publicKeyPem) => {
          const der = crypto.createPublicKey(publicKeyPem).export({ type: "spki", format: "der" });
          return der.subarray(-32).toString("base64url");
        },
        logDebug: (message) => log(`debug ${message}`),
        logError: (message) => log(`error ${message}`),
      },
      onHelloOk: (hello) => {
        if (thisGeneration !== generation) return;
        connected = true;
        pairing = null;
        emit({
          type: "hello",
          protocol: hello?.protocol ?? 4,
          server: hello?.server ?? null,
          auth: hello?.auth ?? null,
          features: hello?.features ?? null,
        });
        emit({ type: "status", status: "online" });
        subscribeSessions(thisGeneration).catch((error) => {
          if (thisGeneration !== generation) return;
          emit({ type: "error", message: `Abonnement sessions impossible : ${error?.message ?? error}` });
        });
      },
      onEvent: (event) => {
        if (thisGeneration !== generation) return;
        handleGatewayEvent(event).catch((error) =>
          log(`event ${event?.event ?? "?"}: ${error?.message ?? error}`),
        );
      },
      onConnectError: (error) => {
        if (thisGeneration !== generation) return;
        handleConnectError(error);
      },
      onReconnectPaused: (info) => {
        if (thisGeneration !== generation) return;
        log(`reconnect paused ${JSON.stringify(info)}`);
        if (!pairing) emit({ type: "status", status: "offline", detail: info?.reason ?? "" });
      },
      onClose: (code, reason) => {
        if (thisGeneration !== generation) return;
        connected = false;
        if (!pairing) {
          emit({ type: "status", status: "offline", detail: truncate(reason, 160) });
        }
        if (code !== 1000 && !pairing) scheduleReconnect(8000);
      },
    });
    client.start();
  } catch (error) {
    emit({ type: "error", message: error?.message ?? String(error) });
    scheduleReconnect(15000);
  }
}

function handleConnectError(error) {
  const details = error?.details ?? {};
  const code = String(details.code ?? "");
  const message = String(error?.message ?? error ?? "connexion impossible");

  if (code === "PAIRING_REQUIRED" || message.includes("pairing required")) {
    pairing = {
      requestId: String(details.requestId ?? ""),
      deviceId: String(details.deviceId ?? identity.deviceId),
      scopes: Array.isArray(details.requestedScopes) ? details.requestedScopes : [],
      recommendedNextStep: String(details.recommendedNextStep ?? ""),
    };
    emit({
      type: "pairing",
      requestId: pairing.requestId,
      deviceId: pairing.deviceId,
      scopes: pairing.scopes,
      command: pairing.requestId ? `openclaw devices approve ${pairing.requestId}` : "",
    });
    emit({ type: "status", status: "pairing", detail: pairing.requestId });
    // Keep the request ID stable until the user explicitly retries. A new
    // connection supersedes the pending request and changes its ID.
    return;
  }

  if (code === "AUTH_TOKEN_MISSING" || code === "AUTH_TOKEN_MISMATCH") {
    emit({
      type: "error",
      code,
      message:
        "Token gateway refusé. Vérifie gateway.remote.token dans ~/.openclaw/openclaw.json ou le champ Token du plugin.",
    });
    emit({ type: "status", status: "error", detail: code });
    scheduleReconnect(20000);
    return;
  }

  emit({ type: "error", code, message });
  emit({ type: "status", status: "error", detail: truncate(message, 160) });
  scheduleReconnect(15000);
}

// ---------------------------------------------------------------- sessions

async function requestWithFallback(method, params, fallbackParams, options) {
  try {
    return await client.request(method, params, options);
  } catch (error) {
    if (!fallbackParams) throw error;
    return client.request(method, fallbackParams, options);
  }
}

async function subscribeSessions(thisGeneration) {
  if (!client || !connected) return;
  const response = await requestWithFallback(
    "sessions.subscribe",
    { ...filteredListParams },
    { ...listParams },
  );
  if (thisGeneration !== generation) return;
  const rows = extractSessionRows(response);
  if (rows.length) applySessions(rows, "subscribe");
  else await refreshSessions();
}

async function refreshSessions() {
  if (!client || !connected) return;
  const response = await requestWithFallback(
    "sessions.list",
    { ...filteredListParams },
    { ...listParams },
  );
  applySessions(extractSessionRows(response), "refresh");
}

function extractSessionRows(response) {
  if (Array.isArray(response)) return response;
  if (!response || typeof response !== "object") return [];
  for (const key of ["list", "sessions", "items", "rows", "entries"]) {
    if (Array.isArray(response[key])) return response[key];
  }
  return [];
}

function applySessions(rows, reason = "") {
  const previous = sessions;
  sessions = new Map();
  for (const row of rows) {
    const normalized = normalizeSession(row);
    if (!normalized.key) continue;
    if (MAIN_ONLY && !isMainSessionKey(normalized.key)) continue;
    sessions.set(normalized.key, normalized);
  }

  // A true -> false active transition is the end of an agent turn. Notify only
  // for rows we had already observed, so the initial snapshot stays quiet.
  for (const [key, next] of sessions) {
    const old = previous.get(key);
    if (old?.active === true && next.active === false) {
      setTimeout(() => enrichFinished(next), 600);
    }
  }

  if (selectedKey && sessions.has(selectedKey)) scheduleHistory(350);
  emitSessions(reason);
}

function friendlySessionTitle(row, key) {
  const explicit = row?.title ?? row?.displayName ?? row?.label ?? row?.name ?? row?.subject;
  if (explicit && String(explicit).trim()) return truncate(String(explicit).trim(), 120);

  let rest = String(key || "");
  if (rest.startsWith("agent:")) {
    const parts = rest.split(":");
    rest = parts.slice(2).join(":");
  }
  if (!rest || rest === "main") return "Main session";
  if (rest.includes("openai-user")) {
    const id = rest.split(":").filter(Boolean).pop() || "";
    return `OpenAI · ${id.slice(0, 8)}`;
  }
  if (rest.startsWith("webchat")) return "WebChat";
  if (rest.startsWith("cron")) return "Cron";
  if (rest.startsWith("subagent")) return "Subagent";
  return rest
    .replace(/[:._-]+/g, " ")
    .replace(/\b\w/g, (character) => character.toUpperCase())
    .slice(0, 80);
}

function isMainSessionKey(key) {
  return /(^|:)main$/.test(String(key || ""));
}

function normalizeAgentIdentity(identity, agentId) {
  const name = String(identity?.name ?? identity?.displayName ?? agentId ?? "").trim();
  const emoji = String(identity?.emoji ?? "").trim();
  const avatar = String(identity?.avatar ?? "").trim();
  return {
    agentId,
    name: truncate(name || agentId, 80),
    emoji: truncate(emoji, 8),
    avatar: truncate(avatar, 400000),
    avatarFile: "",
    avatarSource: truncate(String(identity?.avatarSource ?? ""), 80),
  };
}

function avatarFileExtension(mime) {
  const value = String(mime || "").toLowerCase();
  if (value.includes("svg")) return "svg";
  if (value.includes("jpeg") || value.includes("jpg")) return "jpg";
  if (value.includes("webp")) return "webp";
  return "png";
}

async function prepareAgentAvatarFile(avatar, agentId) {
  const value = String(avatar || "").trim();
  if (!value) return "";

  let bytes = null;
  let extension = "png";

  if (value.startsWith("data:image/")) {
    const match = /^data:(image\/[a-z0-9.+-]+);base64,(.+)$/i.exec(value);
    if (!match) return "";
    extension = avatarFileExtension(match[1]);
    bytes = Buffer.from(match[2], "base64");
  } else if (value.startsWith("file://")) {
    try {
      const filePath = decodeURIComponent(new URL(value).pathname);
      return fs.existsSync(filePath) ? filePath : "";
    } catch {
      return "";
    }
  } else if (value.startsWith("/")) {
    return fs.existsSync(value) ? value : "";
  } else if (/^https?:\/\//i.test(value)) {
    try {
      const response = await fetch(value, { signal: AbortSignal.timeout(5000) });
      if (!response.ok) return "";
      extension = avatarFileExtension(response.headers.get("content-type"));
      bytes = Buffer.from(await response.arrayBuffer());
    } catch {
      return "";
    }
  } else {
    return "";
  }

  if (!bytes || bytes.length === 0 || bytes.length > 2_000_000) return "";
  const slug = String(agentId || "agent")
    .toLowerCase()
    .replace(/[^a-z0-9.-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40) || "agent";
  const hash = crypto.createHash("sha256").update(String(agentId || "")).digest("hex").slice(0, 8);
  const filePath = path.join(AVATAR_DIR, `openclaw-agent-${slug}-${hash}.${extension}`);
  fs.writeFileSync(filePath, bytes);
  return filePath;
}

async function ensureAgentIdentities() {
  if (!client || !connected) return;
  const ids = new Set();
  for (const session of sessions.values()) {
    if (session.agentId) ids.add(session.agentId);
  }
  let changed = false;
  for (const agentId of ids) {
    if (agentIdentities.has(agentId) || agentFetching.has(agentId)) continue;
    agentFetching.add(agentId);
    try {
      const identity = await client.request("agent.identity.get", { agentId }, { timeoutMs: 10000 });
      const normalized = normalizeAgentIdentity(identity, agentId);
      normalized.avatarFile = await prepareAgentAvatarFile(normalized.avatar, agentId);
      agentIdentities.set(agentId, normalized);
      changed = true;
    } catch {
      agentIdentities.set(agentId, normalizeAgentIdentity(null, agentId));
    } finally {
      agentFetching.delete(agentId);
    }
  }
  if (changed) emitSessions("agents");
}

function withAgentIdentity(session) {
  const identity = agentIdentities.get(session.agentId);
  if (!identity) return session;
  return {
    ...session,
    agentName: identity.name,
    agentEmoji: identity.emoji,
    agentAvatar: identity.avatar,
    agentAvatarFile: identity.avatarFile,
  };
}

function normalizeSession(row) {
  const key = String(row?.key ?? row?.sessionKey ?? row?.id ?? "");
  const lastActivityAt = Number(
    row?.lastActivityAt ?? row?.lastInteractionAt ?? row?.updatedAt ?? row?.createdAt ?? 0,
  );
  const title = friendlySessionTitle(row, key);
  return {
    key,
    sessionId: String(row?.sessionId ?? row?.sessionIdCurrent ?? ""),
    agentId: String(row?.agentId ?? row?.agent ?? ""),
    agentName: truncate(String(row?.agentName ?? row?.agent?.name ?? row?.agentId ?? ""), 80),
    agentEmoji: truncate(String(row?.agentEmoji ?? row?.agent?.emoji ?? ""), 8),
    agentAvatar: truncate(String(row?.agentAvatar ?? row?.avatar ?? row?.agent?.avatar ?? ""), 400000),
    title: truncate(title || key, 120),
    label: truncate(String(row?.label ?? ""), 80),
    channel: String(row?.channel ?? row?.surface ?? ""),
    model: truncate(String(row?.model ?? row?.modelId ?? ""), 80),
    active: row?.hasActiveRun === true,
    lastActivityAt: Number.isFinite(lastActivityAt) ? lastActivityAt : 0,
    updatedAt: Number(row?.updatedAt ?? 0) || 0,
    parentSessionKey: String(row?.parentSessionKey ?? ""),
    unread: row?.unread === true,
  };
}

function emitSessions(reason = "") {
  const rows = [...sessions.values()]
    .map(withAgentIdentity)
    .sort((a, b) => {
      if (a.active !== b.active) return a.active ? -1 : 1;
      return b.lastActivityAt - a.lastActivityAt;
    });
  emit({
    type: "sessions",
    reason,
    sessions: rows,
    activeCount: rows.filter((row) => row.active).length,
  });
  if (reason !== "agents") ensureAgentIdentities().catch(() => {});
}

async function enrichFinished(session) {
  if (!client || !connected) return;
  let preview = "";
  try {
    const history = await client.request(
      "chat.history",
      { sessionKey: session.key, limit: 6 },
      { timeoutMs: 15000 },
    );
    const messages = normalizeMessages(history?.messages ?? history?.items ?? []);
    const lastAssistant = [...messages].reverse().find(
      (message) => message.role === "assistant" && message.text.trim(),
    );
    preview = truncate(lastAssistant?.text ?? "", 220).replace(/\s+/g, " ").trim();
  } catch {
    // The notification is still useful without a preview.
  }
  emit({ type: "finished", session, preview });
}

// ---------------------------------------------------------------- events

async function handleGatewayEvent(event) {
  const name = String(event?.event ?? "");
  const payload = event?.payload ?? {};

  if (name === "sessions.changed") {
    const row = payload?.session ?? payload?.entry ?? payload?.row;
    if (row && (row.key || row.sessionKey || row.id)) {
      const next = normalizeSession(row);
      if (MAIN_ONLY && !isMainSessionKey(next.key)) return;
      const old = sessions.get(next.key);
      sessions.set(next.key, next);
      if (old?.active === true && next.active === false) {
        setTimeout(() => enrichFinished(next), 600);
      }
      if (selectedKey === next.key) scheduleHistory(400);
      emitSessions("changed");
    } else {
      scheduleRefreshSessions(250);
    }
    return;
  }

  if (name === "chat" || name === "session.message" || name === "agent") {
    const key = String(payload?.sessionKey ?? payload?.key ?? selectedKey);
    if (key && key === selectedKey) scheduleHistory(650);
    return;
  }

  if (name === "device.pair.resolved") {
    const decision = String(payload?.decision ?? payload?.status ?? "");
    if (decision === "approved") {
      pairing = null;
      scheduleReconnect(800);
    } else if (decision === "rejected" || decision === "expired") {
      emit({ type: "error", message: `Appairage ${decision === "rejected" ? "refusé" : "expiré"}.` });
    }
  }
}

// ---------------------------------------------------------------- transcript

function extractMessageText(message) {
  const content = message?.content ?? message?.message?.content ?? message?.text ?? "";
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    const parts = [];
    for (const block of content) {
      if (typeof block === "string") {
        parts.push(block);
        continue;
      }
      if (!block || typeof block !== "object") continue;
      if (block.type === "text" && typeof block.text === "string") parts.push(block.text);
      else if (block.type === "image") parts.push("[image]");
      else if (block.type === "audio") parts.push("[audio]");
      else if (block.type === "file") parts.push("[fichier]");
    }
    return parts.join("\n");
  }
  if (content && typeof content === "object" && typeof content.text === "string") return content.text;
  return "";
}

function normalizeMessage(message) {
  const roleRaw = String(message?.role ?? message?.author ?? message?.type ?? "system").toLowerCase();
  let role = "system";
  if (roleRaw === "user" || roleRaw === "human") role = "user";
  else if (roleRaw === "assistant" || roleRaw === "agent" || roleRaw === "bot") role = "assistant";
  else if (roleRaw === "tool" || roleRaw === "tool_result") role = "tool";

  const meta = message?.__openclaw ?? {};
  const text = truncate(extractMessageText(message).trim(), 32000);
  const timestamp = Number(
    message?.timestamp ?? message?.ts ?? message?.createdAt ?? message?.time ?? 0,
  );
  return {
    id: String(meta.id ?? message?.id ?? message?.messageId ?? `${role}-${timestamp}-${text.length}`),
    role,
    text,
    ts: Number.isFinite(timestamp) ? timestamp : 0,
    kind: String(meta.kind ?? message?.kind ?? ""),
    name: truncate(String(message?.name ?? message?.toolName ?? ""), 80),
  };
}

function normalizeMessages(messages) {
  if (!Array.isArray(messages)) return [];
  const out = [];
  for (const message of messages) {
    const normalized = normalizeMessage(message);
    if (normalized.role === "tool") continue;
    if (normalized.role === "system" && normalized.kind !== "reset" && normalized.kind !== "compaction") {
      continue;
    }
    if (!normalized.text && normalized.kind !== "reset" && normalized.kind !== "compaction") continue;
    out.push(normalized);
  }
  return out;
}

async function sendHistory(sessionKey) {
  if (!client || !connected || !sessionKey) return;
  const response = await requestWithFallback(
    "chat.history",
    { sessionKey, limit: HISTORY_LIMIT },
    { sessionKey },
    { timeoutMs: 20000 },
  );
  emit({
    type: "history",
    sessionKey,
    session: sessions.get(sessionKey) ?? null,
    messages: normalizeMessages(response?.messages ?? response?.items ?? []),
    inFlight: response?.inFlightRun ?? null,
  });
}

// ---------------------------------------------------------------- commands

async function handleCommand(command) {
  const op = String(command?.op ?? "");
  const id = command?.id ?? null;

  if (op === "refresh") {
    if (!connected) {
      connect();
      return;
    }
    await refreshSessions();
    if (selectedKey) await sendHistory(selectedKey);
    return;
  }

  if (op === "reconnect") {
    connect();
    return;
  }

  if (!connected) {
    if (!pairing) emit({ type: "status", status: "connecting" });
    return;
  }

  if (op === "select") {
    const key = String(command?.sessionKey ?? "");
    if (!key) return;
    const previous = selectedKey;
    selectedKey = key;
    if (previous && previous !== key) {
      client
        ?.request("sessions.messages.unsubscribe", { sessionKey: previous })
        .catch(() => {});
    }
    client
      ?.request("sessions.messages.subscribe", { sessionKey: key, includeApprovals: false })
      .catch(() => {});
    await sendHistory(key);
    return;
  }

  if (op === "send") {
    const sessionKey = String(command?.sessionKey ?? selectedKey);
    const message = String(command?.message ?? "").trim();
    if (!sessionKey || !message) {
      emit({ type: "result", id, ok: false, error: "Session ou message vide." });
      return;
    }
    try {
      const response = await client.request(
        "chat.send",
        { sessionKey, message, idempotencyKey: crypto.randomUUID() },
        { timeoutMs: 60000 },
      );
      sendingRunId = response?.runId ?? null;
      emit({
        type: "result",
        id,
        ok: true,
        sessionKey,
        runId: response?.runId ?? null,
        status: response?.status ?? "",
      });
      scheduleHistory(400);
    } catch (error) {
      emit({ type: "result", id, ok: false, error: truncate(error?.message ?? String(error), 300) });
    }
    return;
  }

  if (op === "abort") {
    const sessionKey = String(command?.sessionKey ?? selectedKey);
    if (!sessionKey) return;
    try {
      const params = { sessionKey };
      if (sendingRunId) params.runId = sendingRunId;
      const response = await client.request("chat.abort", params, { timeoutMs: 15000 });
      emit({ type: "result", id, ok: true, sessionKey, aborted: response?.abortedRunId ?? null });
      scheduleHistory(300);
    } catch (error) {
      emit({ type: "result", id, ok: false, error: truncate(error?.message ?? String(error), 300) });
    }
    return;
  }

  if (op === "ping") {
    emit({ type: "pong", id });
  }
}

// ---------------------------------------------------------------- main

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", (line) => {
  const trimmed = String(line ?? "").trim();
  if (!trimmed) return;
  let command;
  try {
    command = JSON.parse(trimmed);
  } catch {
    emit({ type: "error", message: "Commande JSON invalide." });
    return;
  }
  handleCommand(command).catch((error) =>
    emit({ type: "error", message: truncate(error?.message ?? String(error), 300) }),
  );
});
input.on("close", shutdown);

function shutdown() {
  generation++;
  clearTimer(reconnectTimer);
  clearTimer(refreshTimer);
  if (historyTimer) clearTimeout(historyTimer);
  try {
    client?.stop();
  } catch {
    // ignore
  }
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

emit({ type: "status", status: "starting", version: VERSION });
connect().catch((error) => {
  emit({ type: "error", message: error?.message ?? String(error) });
  scheduleReconnect(15000);
});
