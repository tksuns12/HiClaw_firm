import http from "node:http"
import { promises as fs } from "node:fs"
import path from "node:path"
import { Readable } from "node:stream"

const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
const ISSUER = "https://auth.openai.com"
const CODEX_API_ENDPOINT = "https://chatgpt.com/backend-api/codex/responses"
const PORT = parseInt(process.env.HICLAW_OPENAI_CODEX_PROXY_PORT || "1455", 10)
const STATE_FILE = process.env.HICLAW_OPENAI_CODEX_STATE_FILE || "/data/openai-codex-oauth.json"
const REFRESH_TOKEN_FILE = process.env.HICLAW_OPENAI_CODEX_REFRESH_TOKEN_FILE || ""
const TOKEN_REFRESH_SKEW_MS = 60_000
const USER_AGENT = process.env.HICLAW_OPENAI_CODEX_USER_AGENT || "HiClaw Codex OAuth Proxy/1.0"
const ORIGINATOR = process.env.HICLAW_OPENAI_CODEX_ORIGINATOR || "hiclaw"
const DEFAULT_ALLOWED_MODELS = [
  "gpt-5.1-codex",
  "gpt-5.1-codex-max",
  "gpt-5.1-codex-mini",
  "gpt-5.2",
  "gpt-5.2-codex",
  "gpt-5.3-codex",
  "gpt-5.4",
  "gpt-5.4-mini",
]

const allowedModels = new Set(
  (process.env.HICLAW_OPENAI_CODEX_ALLOWED_MODELS || DEFAULT_ALLOWED_MODELS.join(","))
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean),
)

let state = {
  refreshToken: "",
  accessToken: "",
  expiresAt: 0,
  accountId: "",
}

let refreshPromise = null

function log(message, extra) {
  const ts = new Date().toISOString()
  if (extra === undefined) {
    console.log(`[codex-proxy ${ts}] ${message}`)
    return
  }
  console.log(`[codex-proxy ${ts}] ${message}`, extra)
}

function parseJwtClaims(token) {
  const parts = token.split(".")
  if (parts.length !== 3) return undefined
  try {
    return JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"))
  } catch {
    return undefined
  }
}

function extractAccountIdFromClaims(claims) {
  return (
    claims?.chatgpt_account_id ||
    claims?.["https://api.openai.com/auth"]?.chatgpt_account_id ||
    claims?.organizations?.[0]?.id
  )
}

function extractAccountId(tokens) {
  if (tokens.id_token) {
    const idClaims = parseJwtClaims(tokens.id_token)
    const accountId = extractAccountIdFromClaims(idClaims)
    if (accountId) return accountId
  }
  if (tokens.access_token) {
    const accessClaims = parseJwtClaims(tokens.access_token)
    return extractAccountIdFromClaims(accessClaims)
  }
  return undefined
}

async function saveState() {
  const dir = path.dirname(STATE_FILE)
  await fs.mkdir(dir, { recursive: true })
  const tmpFile = `${STATE_FILE}.tmp`
  await fs.writeFile(
    tmpFile,
    JSON.stringify(
      {
        refreshToken: state.refreshToken,
        accessToken: state.accessToken,
        expiresAt: state.expiresAt,
        accountId: state.accountId,
        updatedAt: new Date().toISOString(),
      },
      null,
      2,
    ),
    { mode: 0o600 },
  )
  await fs.rename(tmpFile, STATE_FILE)
  await fs.chmod(STATE_FILE, 0o600)
}

async function seedRefreshToken() {
  if (process.env.HICLAW_OPENAI_CODEX_REFRESH_TOKEN) {
    state.refreshToken = process.env.HICLAW_OPENAI_CODEX_REFRESH_TOKEN
    return
  }
  if (!REFRESH_TOKEN_FILE) return
  try {
    const token = (await fs.readFile(REFRESH_TOKEN_FILE, "utf8")).trim()
    if (token) state.refreshToken = token
  } catch (error) {
    if (error?.code !== "ENOENT") {
      log("failed to read refresh token file", error)
    }
  }
}

async function loadState() {
  try {
    const saved = JSON.parse(await fs.readFile(STATE_FILE, "utf8"))
    state = {
      ...state,
      refreshToken: saved.refreshToken || state.refreshToken,
      accessToken: saved.accessToken || "",
      expiresAt: Number(saved.expiresAt || 0),
      accountId: saved.accountId || "",
    }
    if (state.refreshToken && state.refreshToken !== saved.refreshToken) {
      state.accessToken = ""
      state.expiresAt = 0
      state.accountId = ""
    }
  } catch (error) {
    if (error?.code !== "ENOENT") {
      log("failed to load persisted state", error)
    }
  }
}

async function refreshAccessToken(refreshToken) {
  const response = await fetch(`${ISSUER}/oauth/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: CLIENT_ID,
    }).toString(),
  })

  if (!response.ok) {
    const body = await response.text()
    throw new Error(`token refresh failed: HTTP ${response.status} ${body}`)
  }

  return response.json()
}

async function ensureTokens(forceRefresh = false) {
  const now = Date.now()
  if (!state.refreshToken) {
    throw new Error("OpenAI Codex refresh token is not configured")
  }
  if (!forceRefresh && state.accessToken && now < state.expiresAt - TOKEN_REFRESH_SKEW_MS) {
    return state
  }
  if (refreshPromise) {
    await refreshPromise
    return state
  }

  refreshPromise = (async () => {
    log("refreshing OpenAI Codex access token")
    const tokens = await refreshAccessToken(state.refreshToken)
    state.refreshToken = tokens.refresh_token || state.refreshToken
    state.accessToken = tokens.access_token
    state.expiresAt = Date.now() + (tokens.expires_in || 3600) * 1000
    state.accountId = extractAccountId(tokens) || state.accountId || ""
    if (!state.accountId) {
      log("OpenAI Codex token refresh completed without ChatGPT account id")
    }
    await saveState()
    log("OpenAI Codex access token ready", {
      expiresAt: new Date(state.expiresAt).toISOString(),
      accountId: state.accountId || undefined,
    })
  })()

  try {
    await refreshPromise
  } finally {
    refreshPromise = null
  }

  return state
}

function writeJson(res, statusCode, payload) {
  const body = JSON.stringify(payload)
  res.writeHead(statusCode, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(body),
  })
  res.end(body)
}

function openAIError(message, type = "invalid_request_error", code) {
  return {
    error: {
      message,
      type,
      ...(code ? { code } : {}),
    },
  }
}

function parseRequestModel(bodyText) {
  try {
    const payload = JSON.parse(bodyText)
    return typeof payload?.model === "string" ? payload.model : undefined
  } catch {
    return undefined
  }
}

function buildModelList() {
  const created = Math.floor(Date.now() / 1000)
  return {
    object: "list",
    data: Array.from(allowedModels).map((id) => ({
      id,
      object: "model",
      created,
      owned_by: "openai-codex-subscription",
    })),
  }
}

async function proxyCodexRequest(req, res, bodyBuffer) {
  const model = parseRequestModel(bodyBuffer.toString("utf8"))
  if (model && !allowedModels.has(model)) {
    writeJson(
      res,
      400,
      openAIError(
        `Model '${model}' is not enabled for OpenAI Codex subscription OAuth. Allowed models: ${Array.from(allowedModels).join(", ")}`,
        "invalid_request_error",
        "model_not_supported",
      ),
    )
    return
  }

  const send = async (forceRefresh = false) => {
    const tokens = await ensureTokens(forceRefresh)
    const headers = new Headers()
    headers.set("authorization", `Bearer ${tokens.accessToken}`)
    headers.set("user-agent", req.headers["user-agent"] || USER_AGENT)
    headers.set("originator", req.headers.originator || ORIGINATOR)
    headers.set("content-type", req.headers["content-type"] || "application/json")
    headers.set("accept", req.headers.accept || "application/json")
    if (req.headers.session_id) headers.set("session_id", req.headers.session_id)
    if (tokens.accountId) headers.set("ChatGPT-Account-Id", tokens.accountId)
    return fetch(CODEX_API_ENDPOINT, {
      method: req.method,
      headers,
      body: bodyBuffer,
    })
  }

  let upstream = await send(false)
  if (upstream.status === 401) {
    log("upstream returned 401, forcing token refresh")
    state.accessToken = ""
    state.expiresAt = 0
    upstream = await send(true)
  }

  const responseHeaders = {}
  upstream.headers.forEach((value, key) => {
    if (key.toLowerCase() === "content-length") return
    responseHeaders[key] = value
  })
  res.writeHead(upstream.status, responseHeaders)

  if (!upstream.body) {
    res.end(await upstream.text())
    return
  }

  Readable.fromWeb(upstream.body).pipe(res)
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    req.on("data", (chunk) => chunks.push(chunk))
    req.on("end", () => resolve(Buffer.concat(chunks)))
    req.on("error", reject)
  })
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.url === "/healthz") {
      if (state.refreshToken) {
        writeJson(res, 200, { ok: true, configured: true })
      } else {
        writeJson(res, 503, { ok: false, configured: false, error: "missing_refresh_token" })
      }
      return
    }

    if (req.method === "GET" && (req.url === "/v1/models" || req.url === "/models")) {
      writeJson(res, 200, buildModelList())
      return
    }

    if (
      req.method === "POST" &&
      ["/v1/chat/completions", "/chat/completions", "/v1/responses", "/responses"].includes(req.url)
    ) {
      const bodyBuffer = await readRequestBody(req)
      await proxyCodexRequest(req, res, bodyBuffer)
      return
    }

    writeJson(res, 404, openAIError(`Unsupported path: ${req.method} ${req.url}`, "not_found_error"))
  } catch (error) {
    log("request failed", error)
    writeJson(res, 502, openAIError(error instanceof Error ? error.message : String(error), "server_error"))
  }
})

await seedRefreshToken()
await loadState()
server.listen(PORT, "0.0.0.0", () => {
  log(`OpenAI Codex OAuth proxy listening on :${PORT}`)
  if (!state.refreshToken) {
    log("proxy started without refresh token; healthz will stay red until configured")
  }
})
