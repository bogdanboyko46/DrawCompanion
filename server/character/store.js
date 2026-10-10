// Character jobs on disk: data/characters/<id>/{job.json, drawing.jpg,
// concept.png, thumb.png, character.usdz, clips.json, ...}. Small enough that
// the whole index lives in memory; job.json is the source of truth.

import { randomBytes } from "node:crypto";
import { mkdir, readdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

export const PUBLIC_FILES = new Set(["drawing.jpg", "concept.png", "thumb.png", "character.usdz", "clips.json"]);

export class Store {
  constructor(root) {
    this.root = root;
    this.jobs = new Map();
    this.writes = new Map();
  }

  async load() {
    await mkdir(this.root, { recursive: true });
    for (const id of await readdir(this.root)) {
      try {
        const job = JSON.parse(await readFile(this.filePath(id, "job.json"), "utf8"));
        this.jobs.set(job.id, job);
      } catch {}
    }
    return [...this.jobs.values()];
  }

  async create({ drawing, hint }) {
    const id = `${Date.now().toString(36)}${randomBytes(4).toString("hex")}`;
    await mkdir(path.join(this.root, id), { recursive: true });
    await writeFile(this.filePath(id, "drawing.jpg"), drawing);
    const job = {
      id,
      hint: hint || "",
      status: "queued",
      stage: "queued",
      message: "Waiting to start",
      progress: 0,
      stageProgress: 0,
      createdAt: new Date().toISOString(),
    };
    this.jobs.set(id, job);
    await this.save(job);
    return job;
  }

  get(id) {
    return this.jobs.get(id);
  }

  list() {
    return [...this.jobs.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }

  // Parallel stages (animations) save the same job at once: chain the writes
  // per job so each one lands whole and the last state wins.
  save(job) {
    const prev = this.writes.get(job.id) ?? Promise.resolve();
    const next = prev.catch(() => {}).then(async () => {
      const file = this.filePath(job.id, "job.json");
      const tmp = `${file}.tmp`;
      await writeFile(tmp, JSON.stringify(job, null, 2));
      await rename(tmp, file);
    });
    this.writes.set(job.id, next);
    return next;
  }

  filePath(id, name) {
    if (!/^[a-z0-9]+$/.test(id) || name.includes("/") || name.includes("..")) throw new Error("bad path");
    return path.join(this.root, id, name);
  }

  readFile(id, name) {
    return readFile(this.filePath(id, name));
  }

  async download(meshy, url, id, name) {
    if (!url) throw new Error(`no URL for ${name}`);
    return meshy.download(url, this.filePath(id, name));
  }
}

/** What the app sees: no remote task ids or signed asset URLs. */
export function publicJob(job, base = "") {
  const file = (name) => `${base}/api/characters/${job.id}/${name}`;
  const sheet = job.sheet;
  return {
    id: job.id,
    status: job.status,
    stage: job.stage,
    message: job.message,
    progress: job.progress,
    stageProgress: job.stageProgress,
    error: job.error ?? null,
    createdAt: job.createdAt,
    drawingUrl: file("drawing.jpg"),
    conceptUrl: job.done?.includes("concept") ? file("concept.png") : null,
    thumbnailUrl: job.done?.includes("sculpt") ? file("thumb.png") : null,
    character: sheet
      ? {
          name: sheet.name,
          summary: sheet.summary,
          greeting: sheet.greeting,
          bodyPlan: sheet.body_plan,
          heightMeters: sheet.height_m,
          figureBox: sheet.figure_box,
          colors: sheet.colors,
          personality: sheet.personality,
        }
      : null,
    model:
      job.status === "ready"
        ? { url: file("character.usdz"), animated: Boolean(job.animated), clips: job.clips ?? [] }
        : null,
  };
}
