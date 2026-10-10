// Offline stand-ins for Meshy, Claude and the packer. Mock mode runs the real
// pipeline against these, so the app's whole flow (progress stages, concept
// preview, animated USDZ) works without API keys or Blender.

import { copyFile, mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ENDPOINTS } from "./meshy.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.join(here, "fixtures");

// Rough real-world durations, compressed: the whole job takes ~12 s.
const DURATION_MS = {
  [ENDPOINTS.imageToImage]: 2500,
  [ENDPOINTS.imageTo3d]: 4000,
  [ENDPOINTS.multiImageTo3d]: 4000,
  [ENDPOINTS.rigging]: 1500,
  [ENDPOINTS.animation]: 1500,
};

export class MockMeshy {
  constructor({ speed = 1 } = {}) {
    this.speed = speed;
    this.tasks = new Map();
    this.n = 0;
    this.pollMs = 250 / speed;
  }

  async library() {
    return [
      { id: 0, name: "Idle", category: "Idle" },
      { id: 1, name: "Friendly Wave", category: "Greeting" },
      { id: 2, name: "Happy Jump", category: "Emotion" },
    ];
  }

  async create(endpoint, body) {
    const id = `mock-${++this.n}`;
    this.tasks.set(id, { endpoint, body, started: Date.now() });
    return id;
  }

  async get(endpoint, id) {
    const t = this.tasks.get(id);
    if (!t) return { id, status: "SUCCEEDED", progress: 100, ...result(endpoint, null) };
    const p = Math.min(1, (Date.now() - t.started) / ((DURATION_MS[endpoint] ?? 1000) / this.speed));
    const status = p >= 1 ? "SUCCEEDED" : "IN_PROGRESS";
    return { id, status, progress: Math.round(p * 100), ...(p >= 1 ? result(endpoint, t.body) : {}) };
  }

  async wait(endpoint, id, { onProgress } = {}) {
    for (;;) {
      const t = await this.get(endpoint, id);
      await onProgress?.(t.progress / 100, t);
      if (t.status === "SUCCEEDED") return t;
      await new Promise((r) => setTimeout(r, this.pollMs));
    }
  }

  async download(url, dest) {
    await mkdir(path.dirname(dest), { recursive: true });
    if (url.startsWith("data:")) {
      await writeFile(dest, Buffer.from(url.split(",")[1], "base64"));
    } else {
      await copyFile(path.join(FIXTURES, url.replace(/^fixture:/, "")), dest);
    }
    return dest;
  }
}

function result(endpoint, body) {
  switch (endpoint) {
    case ENDPOINTS.imageToImage:
      // The "concept" is the drawing itself; there is no image model offline.
      return { image_urls: [body?.reference_image_urls?.[0] ?? "fixture:mock.png"] };
    case ENDPOINTS.imageTo3d:
    case ENDPOINTS.multiImageTo3d:
      return { model_urls: { glb: "fixture:mock.glb", usdz: "fixture:mock.usdz" }, face_count: 16000 };
    case ENDPOINTS.rigging:
      return {
        result: {
          rigged_character_glb_url: "fixture:mock.glb",
          basic_animations: { walking_glb_url: "fixture:mock.glb" },
        },
      };
    case ENDPOINTS.animation:
      return { result: { animation_glb_url: "fixture:mock.glb" } };
    default:
      return {};
  }
}

export const mockDirector = {
  async readDrawing({ hint }) {
    return {
      is_character: true,
      reject_reason: "",
      name: "Doodle",
      summary: hint ? `A round little creature (you said: ${hint}).` : "A round little creature with big eyes and pointy ears.",
      body_plan: "biped_creature",
      riggable: true,
      height_m: 0.4,
      figure_box: { x: 0.25, y: 0.2, w: 0.5, h: 0.6 },
      colors: [
        { hex: "#F98030", part: "body", from_drawing: false },
        { hex: "#FFDB99", part: "belly", from_drawing: false },
        { hex: "#0A0A0F", part: "eyes and feet", from_drawing: true },
      ],
      design_details: ["pointy ears", "big glossy eyes", "pale belly", "tiny smile"],
      concept_prompt: "mock",
      texture_prompt: "mock",
      personality: { traits: ["curious", "cheerful"], energy: 0.7, friendliness: 0.9 },
      greeting: "Hi! I'm Doodle!",
      animations: [
        { role: "idle", action_id: 0 },
        { role: "greet", action_id: 1 },
        { role: "happy", action_id: 2 },
      ],
    };
  },
  async reviewConcept() {
    return { faithful: true, issues: [], revised_prompt: "" };
  },
};

// The fixture USDZ was packed by pack_usdz.py from mock.glb, with clips named
// after the app's roles (idle, walk, greet, happy).
export const mockPacker = {
  async pack({ out, manifest }) {
    await copyFile(path.join(FIXTURES, "mock.usdz"), out);
    await copyFile(path.join(FIXTURES, "mock.clips.json"), manifest);
    return JSON.parse(await readFile(manifest, "utf8"));
  },
  async available() {
    return true;
  },
};
