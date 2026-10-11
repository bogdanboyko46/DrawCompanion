// Runs a list of generations in parallel (each one a gen.mjs child process).
//   node --env-file=<.env> run.mjs <outdir> <prepdir> <case:variant:model:photo[:aspect]> ...
//   photo = photo | nogrid | clean ; aspect e.g. 16x9, or - for the default 1:1
// Output image: <outdir>/<case>__<variant>__<model>__<photo>__<aspect>.png
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { PROMPTS, CASES, fill } from "./prompts.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const [outdir, prepdir, ...jobs] = process.argv.slice(2);

function photoPath(page, kind) {
  if (kind === "photo") return join(here, "..", "photos", `${page}.jpg`);
  return join(prepdir, `${page}-${kind}.jpg`);
}

await Promise.all(jobs.map((job) => new Promise((resolve) => {
  const [cs, variant, model, kind, ax = "-"] = job.split(":");
  const aspect = ax.replace("x", ":");
  const c = CASES[cs];
  const prompt = fill(PROMPTS[variant], c);
  const tag = `${cs}__${variant}__${model}__${kind}__${aspect.replace(":", "x")}`;
  const out = join(outdir, `${tag}.png`);
  const p = spawn(process.execPath, [join(here, "gen.mjs"), photoPath(c.page, kind), model, out, tag, aspect, "--", prompt],
    { stdio: "inherit", env: process.env });
  p.on("exit", resolve);
})));
