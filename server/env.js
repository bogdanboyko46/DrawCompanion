// API keys and settings live in .env at the project root (git ignores it;
// copy .env.example to start). Variables already set in the shell win.
// Imported first by index.js so other modules read these at load time.
import path from "node:path";
import { fileURLToPath } from "node:url";

try {
  process.loadEnvFile(path.join(path.dirname(fileURLToPath(import.meta.url)), "..", ".env"));
} catch (err) {
  if (err.code !== "ENOENT") throw err;
}
