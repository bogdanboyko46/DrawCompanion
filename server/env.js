// Loads API keys from .env at the repo root, if it exists. Imported first by
// index.js so every module sees the values when it reads process.env.
// Variables already set in the shell win over the file. Needs Node 20.12+.

import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const file = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", ".env");
if (existsSync(file)) {
  const before = { ...process.env };
  process.loadEnvFile(file);
  for (const [k, v] of Object.entries(before)) process.env[k] = v; // shell takes precedence
}
