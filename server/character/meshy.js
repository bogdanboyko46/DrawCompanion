// Thin client for the Meshy API (https://docs.meshy.ai): create a task, poll
// it to completion, download what it made. Field names follow Meshy's own
// MCP server (github.com/meshy-dev/meshy-mcp-server), which tracks the API.

import { createWriteStream } from "node:fs";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";

const BASE = process.env.MESHY_API_HOST || "https://api.meshy.ai";

export const ENDPOINTS = {
  imageToImage: "/openapi/v1/image-to-image",
  imageTo3d: "/openapi/v1/image-to-3d",
  multiImageTo3d: "/openapi/v1/multi-image-to-3d",
  rigging: "/openapi/v1/rigging",
  animation: "/openapi/v1/animations",
  library: "/openapi/v1/animations/library",
};

export class MeshyError extends Error {
  constructor(message, { status, code, retryable = false } = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.retryable = retryable;
  }
}

export class Meshy {
  constructor({ apiKey = process.env.MESHY_API_KEY, fetchImpl = fetch, pollMs = 3000 } = {}) {
    if (!apiKey) throw new MeshyError("MESHY_API_KEY is not set");
    this.apiKey = apiKey;
    this.fetch = fetchImpl;
    this.pollMs = pollMs;
  }

  async request(method, url, body, { attempts = 4 } = {}) {
    for (let attempt = 1; ; attempt++) {
      let res;
      try {
        res = await this.fetch(BASE + url, {
          method,
          headers: { Authorization: `Bearer ${this.apiKey}`, "content-type": "application/json" },
          body: body ? JSON.stringify(body) : undefined,
        });
      } catch (err) {
        if (attempt < attempts) {
          await sleep(1000 * 2 ** attempt);
          continue;
        }
        throw new MeshyError(`Meshy unreachable: ${err.message}`, { retryable: true });
      }
      if (res.ok) return res.json();
      const text = await res.text().catch(() => "");
      const retryable = res.status === 429 || res.status >= 500;
      if (retryable && attempt < attempts) {
        const after = Number(res.headers.get("retry-after"));
        await sleep(Number.isFinite(after) && after > 0 ? after * 1000 : 1000 * 2 ** attempt);
        continue;
      }
      let message = text;
      try {
        message = JSON.parse(text).message ?? text;
      } catch {}
      throw new MeshyError(`Meshy ${method} ${url} failed (${res.status}): ${message}`.slice(0, 400), {
        status: res.status,
        retryable,
      });
    }
  }

  /** Starts a task and returns its id. */
  async create(endpoint, body) {
    const out = await this.request("POST", endpoint, body);
    const id = out.result ?? out.id;
    if (typeof id !== "string") throw new MeshyError(`Meshy returned no task id for ${endpoint}`);
    return id;
  }

  get(endpoint, id) {
    return this.request("GET", `${endpoint}/${id}`);
  }

  /**
   * Polls until the task finishes. onProgress(0..1) fires on every change.
   * Throws MeshyError when the task fails, is canceled, or runs past timeoutMs.
   */
  async wait(endpoint, id, { onProgress, timeoutMs = 15 * 60_000, signal } = {}) {
    const deadline = Date.now() + timeoutMs;
    let last = -1;
    for (;;) {
      if (signal?.aborted) throw new MeshyError("canceled");
      const task = await this.get(endpoint, id);
      const progress = clamp01((task.progress ?? 0) / 100);
      if (progress !== last) {
        last = progress;
        onProgress?.(progress, task);
      }
      if (task.status === "SUCCEEDED") return task;
      if (task.status === "FAILED" || task.status === "CANCELED") {
        const msg = task.task_error?.message || task.status.toLowerCase();
        throw new MeshyError(`Meshy task ${id} ${task.status.toLowerCase()}: ${msg}`, { code: task.status });
      }
      if (Date.now() > deadline) throw new MeshyError(`Meshy task ${id} timed out`, { retryable: true });
      await sleep(this.pollMs);
    }
  }

  /** The animation catalog, normalized to [{ id, name, category }]. */
  async library() {
    const raw = await this.request("GET", ENDPOINTS.library);
    return normalizeLibrary(raw);
  }

  async download(url, dest) {
    await mkdir(path.dirname(dest), { recursive: true });
    const res = await this.fetch(url);
    if (!res.ok || !res.body) throw new MeshyError(`Download failed (${res.status}) for ${dest}`, { retryable: true });
    await pipeline(Readable.fromWeb(res.body), createWriteStream(dest));
    return dest;
  }
}

// The library endpoint is the one response whose exact shape isn't pinned down
// in Meshy's MCP server, so accept the plausible variants.
export function normalizeLibrary(raw) {
  const list = Array.isArray(raw)
    ? raw
    : raw?.result ?? raw?.data ?? raw?.animations ?? raw?.items ?? [];
  if (!Array.isArray(list)) return [];
  return list
    .map((a) => ({
      id: Number(a.action_id ?? a.id),
      name: String(a.name ?? a.action_name ?? a.title ?? ""),
      category: String(a.category ?? a.type ?? (Array.isArray(a.tags) ? a.tags.join(", ") : "") ?? ""),
    }))
    .filter((a) => Number.isInteger(a.id) && a.name);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const clamp01 = (v) => Math.min(1, Math.max(0, Number(v) || 0));
