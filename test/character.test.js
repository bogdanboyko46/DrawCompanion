import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { sanitizeSheet } from "../server/character/director.js";
import { ENDPOINTS, MeshyError, normalizeLibrary } from "../server/character/meshy.js";
import { MockMeshy, mockDirector, mockPacker } from "../server/character/mock.js";
import { runCharacterJob } from "../server/character/pipeline.js";
import { Store, publicJob } from "../server/character/store.js";

const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 0xff, 0xd9]);

async function setup({ meshy = new MockMeshy({ speed: 100 }), director = mockDirector, sheet } = {}) {
  const store = new Store(await mkdtemp(path.join(tmpdir(), "dc-")));
  const job = await store.create({ drawing: JPEG, hint: "" });
  const dir = sheet ? { ...director, readDrawing: async (a) => ({ ...(await director.readDrawing(a)), ...sheet }) } : director;
  return { store, job, deps: { meshy, director: dir, packer: mockPacker, store } };
}

class CountingMeshy extends MockMeshy {
  constructor(opts) {
    super({ speed: 100, ...opts });
    this.created = [];
  }
  async create(endpoint, body) {
    this.created.push(endpoint);
    return super.create(endpoint, body);
  }
}

test("riggable character runs every stage and ships an animated USDZ", async () => {
  const meshy = new CountingMeshy();
  const { store, job, deps } = await setup({ meshy });
  await runCharacterJob(job, deps);
  assert.equal(job.status, "ready", job.error);
  assert.deepEqual(job.done, ["read", "concept", "review", "sculpt", "rig", "animate", "package"]);
  assert.equal(job.progress, 1);
  assert.ok((await stat(store.filePath(job.id, "character.usdz"))).size > 100_000);
  const pub = publicJob(job);
  assert.equal(pub.model.animated, true);
  assert.deepEqual(pub.model.clips.map((c) => c.name).sort(), ["greet", "happy", "idle", "walk"]);
  assert.equal(pub.character.name, "Doodle");
  assert.ok(!JSON.stringify(pub).includes("mock-"), "remote task ids stay server-side");
  // one concept, one mesh, one rig, one task per chosen animation
  assert.equal(meshy.created.filter((e) => e === ENDPOINTS.animation).length, 3);
  assert.equal(meshy.created.filter((e) => e === ENDPOINTS.rigging).length, 1);
});

test("non-humanoid skips the rig and ships the static model", async () => {
  const meshy = new CountingMeshy();
  const { job, deps } = await setup({ meshy, sheet: { riggable: false, body_plan: "quadruped", animations: [] } });
  await runCharacterJob(job, deps);
  assert.equal(job.status, "ready", job.error);
  assert.equal(job.animated, false);
  assert.ok(!job.done.includes("rig"));
  assert.ok(!meshy.created.includes(ENDPOINTS.rigging));
  // the sculpt asks for a T-pose only when it will be rigged
  assert.equal(meshy.tasks.get(job.tasks.sculpt).body.pose_mode, undefined);
});

test("a failed rig falls back to a static model instead of failing the job", async () => {
  class NoRig extends MockMeshy {
    async wait(endpoint, id, opts) {
      if (endpoint === ENDPOINTS.rigging) throw new MeshyError("rigging failed: not humanoid");
      return super.wait(endpoint, id, opts);
    }
  }
  const { job, deps } = await setup({ meshy: new NoRig({ speed: 100 }) });
  await runCharacterJob(job, deps);
  assert.equal(job.status, "ready", job.error);
  assert.equal(job.animated, false);
  assert.match(job.rigFailed, /not humanoid/);
});

test("resuming after a crash waits on saved tasks instead of paying again", async () => {
  class Flaky extends CountingMeshy {
    failOnce = true;
    async wait(endpoint, id, opts) {
      if (endpoint === ENDPOINTS.multiImageTo3d || endpoint === ENDPOINTS.imageTo3d) {
        if (this.failOnce) {
          this.failOnce = false;
          throw new MeshyError("network blip", { retryable: true });
        }
      }
      return super.wait(endpoint, id, opts);
    }
  }
  const meshy = new Flaky();
  const { job, deps } = await setup({ meshy });
  await runCharacterJob(job, deps);
  assert.equal(job.status, "failed");
  assert.ok(job.tasks.sculpt, "the sculpt task id survives the failure");
  await runCharacterJob(job, deps);
  assert.equal(job.status, "ready", job.error);
  assert.equal(meshy.created.filter((e) => e === ENDPOINTS.imageToImage).length, 1);
  assert.equal(meshy.created.filter((e) => e === ENDPOINTS.imageTo3d || e === ENDPOINTS.multiImageTo3d).length, 1);
});

test("an unfaithful concept is repainted once with the corrected prompt", async () => {
  const meshy = new CountingMeshy();
  const director = {
    ...mockDirector,
    reviewConcept: async () => ({ faithful: false, issues: ["lost the scarf"], revised_prompt: "same, WITH the red scarf" }),
  };
  const { job, deps } = await setup({ meshy, director });
  await runCharacterJob(job, deps);
  assert.equal(job.status, "ready", job.error);
  assert.equal(meshy.created.filter((e) => e === ENDPOINTS.imageToImage).length, 2);
  assert.equal(meshy.tasks.get(job.tasks.conceptRetry).body.prompt, "same, WITH the red scarf");
  assert.equal(job.conceptTask, job.tasks.conceptRetry, "the 3D stage uses the repainted concept");
  assert.deepEqual(job.review.issues, ["lost the scarf"]);
});

test("a page with no character fails early with the director's reason", async () => {
  const meshy = new CountingMeshy();
  const { job, deps } = await setup({ meshy, sheet: { is_character: false, reject_reason: "That's a lovely landscape, but there's no one in it." } });
  await runCharacterJob(job, deps);
  assert.equal(job.status, "failed");
  assert.match(job.error, /landscape/);
  assert.equal(meshy.created.length, 0, "nothing is paid for");
});

test("job state survives a reload from disk", async () => {
  const { store, job, deps } = await setup();
  await runCharacterJob(job, deps);
  const again = new Store(store.root);
  const [loaded] = await again.load();
  assert.equal(loaded.status, "ready");
  assert.deepEqual(JSON.parse(await readFile(store.filePath(job.id, "clips.json"), "utf8")).clips.length, 4);
});

test("sanitizeSheet keeps downstream APIs in bounds", () => {
  const library = [{ id: 0, name: "Idle" }, { id: 7, name: "Wave" }];
  const s = sanitizeSheet(
    {
      ...baseSheet(),
      riggable: true,
      height_m: 40,
      figure_box: { x: 0.9, y: -1, w: 2, h: 0.5 },
      colors: [{ hex: "#abcdef", part: "a" }, { hex: "red", part: "b" }],
      animations: [
        { role: "greet", action_id: 7 },
        { role: "greet", action_id: 0 },
        { role: "walk", action_id: 7 },
        { role: "happy", action_id: 999 },
      ],
    },
    library,
  );
  assert.equal(s.height_m, 3);
  assert.ok(s.figure_box.x + s.figure_box.w <= 1 && s.figure_box.y >= 0);
  assert.deepEqual(s.colors.map((c) => c.hex), ["#abcdef"]);
  assert.deepEqual(s.animations, [{ role: "idle", action_id: 0 }, { role: "greet", action_id: 7 }]);
});

test("normalizeLibrary accepts the plausible response shapes", () => {
  assert.deepEqual(normalizeLibrary([{ action_id: 3, name: "Jump", category: "Fun" }]), [{ id: 3, name: "Jump", category: "Fun" }]);
  assert.deepEqual(normalizeLibrary({ result: [{ id: "4", name: "Bow", tags: ["greet", "polite"] }] }), [
    { id: 4, name: "Bow", category: "greet, polite" },
  ]);
  assert.deepEqual(normalizeLibrary({ nope: 1 }), []);
});

function baseSheet() {
  return {
    is_character: true,
    reject_reason: "",
    name: "  Pip ",
    summary: "",
    body_plan: "humanoid",
    riggable: false,
    height_m: 1,
    figure_box: { x: 0, y: 0, w: 1, h: 1 },
    colors: [],
    design_details: [],
    concept_prompt: "x",
    texture_prompt: "y",
    personality: { traits: [], energy: 0.5, friendliness: 0.5 },
    greeting: "hi",
    animations: [],
  };
}
