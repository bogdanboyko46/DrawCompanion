// Drawing -> living 3D character, as a resumable job.
//
//   read      Claude reads the drawing and writes the character sheet
//   concept   image model paints a faithful, clean, T-posed render (multi-view)
//   review    Claude compares render to drawing; one corrected retry if it drifted
//   sculpt    multi-view image-to-3D: textured PBR mesh, remeshed for mobile
//   rig       auto-rig (humanoids only) + free walk/run clips
//   animate   personality-matched clips from the animation library
//   package   all clips laid on one timeline in a single USDZ for RealityKit
//
// Each remote task id is saved on the job as soon as it exists, so a server
// restart resumes polling instead of paying for the work twice. Anything that
// isn't humanoid skips rig/animate and ships as a static model; the app gives
// it procedural motion instead.

import { ENDPOINTS, MeshyError } from "./meshy.js";

export const STAGES = [
  { id: "read", weight: 0.05, label: "Studying your drawing" },
  { id: "concept", weight: 0.12, label: "Painting a 3D concept" },
  { id: "review", weight: 0.03, label: "Checking it matches" },
  { id: "sculpt", weight: 0.45, label: "Sculpting in 3D" },
  { id: "rig", weight: 0.12, label: "Building a skeleton" },
  { id: "animate", weight: 0.13, label: "Teaching it to move" },
  { id: "package", weight: 0.1, label: "Bringing it to life" },
];

const IMAGE_MODEL = process.env.DRAWCOMPANION_IMAGE_MODEL || "nano-banana-pro";
const MESH_MODEL = process.env.DRAWCOMPANION_MESH_MODEL || "latest";
const POLYCOUNT = Number(process.env.DRAWCOMPANION_POLYCOUNT || 50000);
const MULTIVIEW = process.env.DRAWCOMPANION_MULTIVIEW !== "0";
const LOOPING = new Set(["idle", "walk", "run", "dance", "sleep", "think"]);

export class PipelineError extends Error {}

/**
 * Runs (or resumes) a job. deps: { director, meshy, packer, store }.
 * The job object is mutated in place and saved after every change.
 */
export async function runCharacterJob(job, { director, meshy, packer, store }) {
  const save = () => store.save(job);
  job.tasks ??= {};
  job.status = "running";
  job.error = null;

  const stage = async (id, fn) => {
    const def = STAGES.find((s) => s.id === id);
    if (job.done?.includes(id)) return;
    job.stage = id;
    job.message = def.label;
    job.stageProgress = 0;
    job.progress = overall(job);
    await save();
    await fn((p) => {
      job.stageProgress = Math.max(job.stageProgress, Math.min(1, p));
      job.progress = overall(job);
      return save();
    });
    job.done = [...(job.done ?? []), id];
    job.stageProgress = 1;
    job.progress = overall(job);
    await save();
  };

  // Meshy tasks are created once; on resume we only wait.
  const task = async (key, endpoint, body, onProgress) => {
    if (!job.tasks[key]) {
      job.tasks[key] = await meshy.create(endpoint, body);
      await save();
    }
    try {
      return await meshy.wait(endpoint, job.tasks[key], { onProgress });
    } catch (err) {
      if (err instanceof MeshyError && !err.retryable) delete job.tasks[key]; // a re-run should start fresh
      throw err;
    }
  };

  try {
    const drawing = await store.readFile(job.id, "drawing.jpg");
    const drawingB64 = drawing.toString("base64");
    const drawingUri = `data:image/jpeg;base64,${drawingB64}`;

    await stage("read", async () => {
      let library = [];
      try {
        library = await meshy.library();
      } catch (err) {
        console.warn("animation library unavailable:", err.message);
      }
      job.sheet = await director.readDrawing({
        imageBase64: drawingB64,
        mediaType: "image/jpeg",
        hint: job.hint,
        library,
      });
      if (!job.sheet.is_character) {
        throw new PipelineError(job.sheet.reject_reason || "That doesn't look like a character yet. Try drawing a figure.");
      }
    });
    const sheet = job.sheet;

    const paint = (key, prompt, progress) =>
      task(
        key,
        ENDPOINTS.imageToImage,
        {
          ai_model: IMAGE_MODEL,
          prompt,
          reference_image_urls: [drawingUri],
          generate_multi_view: MULTIVIEW,
        },
        progress,
      );

    await stage("concept", async (progress) => {
      const t = await paint("concept", sheet.concept_prompt, progress);
      job.conceptTask = job.tasks.concept;
      job.conceptViews = t.image_urls?.length ?? 0;
      await store.download(meshy, t.image_urls?.[0], job.id, "concept.png");
    });

    await stage("review", async (progress) => {
      if (job.tasks.conceptRetry) return; // already retried on a previous run
      const concept = await store.readFile(job.id, "concept.png");
      let review;
      try {
        review = await director.reviewConcept({
          drawing: { base64: drawingB64, mediaType: "image/jpeg" },
          concept: { base64: concept.toString("base64"), mediaType: sniffImageType(concept) },
          sheet,
        });
      } catch (err) {
        console.warn("concept review skipped:", err.message);
        return;
      }
      job.review = { faithful: review.faithful, issues: review.issues };
      await progress(0.3);
      if (review.faithful || !review.revised_prompt) return;
      const t = await paint("conceptRetry", review.revised_prompt.slice(0, 800), (p) => progress(0.3 + 0.7 * p));
      job.conceptTask = job.tasks.conceptRetry;
      job.conceptViews = t.image_urls?.length ?? 0;
      await store.download(meshy, t.image_urls?.[0], job.id, "concept.png");
    });

    let sculpt;
    await stage("sculpt", async (progress) => {
      const common = {
        ai_model: MESH_MODEL,
        should_texture: true,
        enable_pbr: true,
        texture_prompt: sheet.texture_prompt,
        should_remesh: true,
        target_polycount: POLYCOUNT,
        topology: "triangle",
        target_formats: ["glb", "usdz"],
        ...(sheet.riggable ? { pose_mode: "t-pose" } : {}),
      };
      const multi = (job.conceptViews ?? 0) > 1;
      const endpoint = multi ? ENDPOINTS.multiImageTo3d : ENDPOINTS.imageTo3d;
      job.sculptEndpoint = endpoint;
      const body = job.conceptTask ? { ...common, input_task_id: job.conceptTask } : { ...common, image_url: drawingUri };
      sculpt = await task("sculpt", endpoint, body, progress);
      job.faces = sculpt.face_count ?? null;
      if (sculpt.thumbnail_url) await store.download(meshy, sculpt.thumbnail_url, job.id, "thumb.png").catch(() => {});
    });
    sculpt ??= await meshy.get(job.sculptEndpoint, job.tasks.sculpt);

    let rig = null;
    if (sheet.riggable) {
      await stage("rig", async (progress) => {
        try {
          rig = await task("rig", ENDPOINTS.rigging, { input_task_id: job.tasks.sculpt, height_meters: sheet.height_m }, progress);
        } catch (err) {
          // Not every "humanoid" rigs (wings, long robes). Ship it static instead of failing.
          console.warn(`rigging failed for ${job.id}, shipping static:`, err.message);
          job.rigFailed = err.message;
        }
      });
      if (!rig && job.tasks.rig && !job.rigFailed) rig = await meshy.get(ENDPOINTS.rigging, job.tasks.rig);
    }

    const clipFiles = {};
    if (rig) {
      await stage("animate", async (progress) => {
        const anims = sheet.animations;
        const done = new Array(anims.length).fill(0);
        const results = await Promise.allSettled(
          anims.map((a, i) =>
            task(
              `anim_${a.role}`,
              ENDPOINTS.animation,
              { rig_task_id: job.tasks.rig, action_id: a.action_id, post_process: { operation_type: "change_fps", fps: 30 } },
              (p) => {
                done[i] = p;
                return progress(done.reduce((s, v) => s + v, 0) / anims.length);
              },
            ),
          ),
        );
        job.animationUrls = {};
        results.forEach((r, i) => {
          const url = r.status === "fulfilled" && r.value.result?.animation_glb_url;
          if (url) job.animationUrls[anims[i].role] = url;
          else console.warn(`animation ${anims[i].role} failed:`, r.reason?.message ?? "no glb");
        });
      });
    }

    await stage("package", async (progress) => {
      if (rig || job.tasks.rig) {
        rig ??= await meshy.get(ENDPOINTS.rigging, job.tasks.rig);
        const r = rig.result ?? {};
        if (!r.rigged_character_glb_url) throw new PipelineError("The rig came back without a model.");
        await store.download(meshy, r.rigged_character_glb_url, job.id, "rigged.glb");
        const sources = {
          walk: r.basic_animations?.walking_glb_url,
          run: r.basic_animations?.running_glb_url,
          ...(job.animationUrls ?? {}),
        };
        for (const [role, url] of Object.entries(sources)) {
          if (!url) continue;
          clipFiles[role] = await store.download(meshy, url, job.id, `clip-${role}.glb`);
        }
        await progress(0.4);
        const manifest = await packer.pack({
          base: store.filePath(job.id, "rigged.glb"),
          clips: Object.entries(clipFiles).map(([name, file]) => ({ name, file, loop: LOOPING.has(name) })),
          out: store.filePath(job.id, "character.usdz"),
          manifest: store.filePath(job.id, "clips.json"),
        });
        job.clips = manifest.clips;
        job.animated = manifest.clips.length > 0;
      } else {
        const url = sculpt.model_urls?.usdz;
        if (!url) throw new PipelineError("The 3D model came back without a USDZ.");
        await store.download(meshy, url, job.id, "character.usdz");
        job.clips = [];
        job.animated = false;
      }
    });

    job.status = "ready";
    job.stage = "done";
    job.message = `${sheet.name} is ready`;
    job.progress = 1;
    job.finishedAt = new Date().toISOString();
    await save();
  } catch (err) {
    job.status = "failed";
    job.error = err instanceof PipelineError || err instanceof MeshyError || err.name === "DirectorError"
      ? err.message
      : "Something went wrong while making the character.";
    if (!(err instanceof PipelineError)) console.error(`job ${job.id} failed:`, err);
    await save();
  }
  return job;
}

function overall(job) {
  let total = 0;
  for (const s of STAGES) {
    if (job.done?.includes(s.id)) total += s.weight;
    else if (s.id === job.stage) total += s.weight * (job.stageProgress ?? 0);
  }
  return Math.min(0.99, total);
}

function sniffImageType(buf) {
  if (buf[0] === 0x89 && buf[1] === 0x50) return "image/png";
  if (buf[0] === 0xff && buf[1] === 0xd8) return "image/jpeg";
  if (buf.subarray(8, 12).toString() === "WEBP") return "image/webp";
  return "image/png";
}

