// Runs pack_usdz.py under a Python that has Blender's `bpy` module.
// Set DRAWCOMPANION_PYTHON to that interpreter (default: python3).

import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(here, "pack_usdz.py");
const PYTHON = process.env.DRAWCOMPANION_PYTHON || "python3";

export const packer = {
  /** clips: [{ name, file, loop }]. Resolves to { fps, clips: [{ name, start, end, loop }] }. */
  async pack({ base, clips, out, manifest, embedded = false }) {
    const args = [SCRIPT, "--base", base, "--out", out, "--manifest", manifest];
    for (const c of clips) {
      args.push("--clip", `${c.name}=${c.file}`);
      if (c.loop) args.push("--loop", c.name);
    }
    if (embedded) args.push("--embedded");
    await run(PYTHON, args);
    return JSON.parse(await readFile(manifest, "utf8"));
  },

  /** True when the configured Python can import bpy. */
  async available() {
    try {
      await run(PYTHON, ["-c", "import bpy"], 60_000);
      return true;
    } catch {
      return false;
    }
  },
};

function run(cmd, args, timeout = 10 * 60_000) {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { timeout, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) {
        const tail = String(stderr || stdout).trim().split("\n").slice(-6).join("\n");
        reject(new Error(`${path.basename(cmd)} failed: ${tail || err.message}`));
      } else resolve(stdout);
    });
  });
}
