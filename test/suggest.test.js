import { test } from "node:test";
import assert from "node:assert/strict";
import Anthropic from "@anthropic-ai/sdk";
import { decide } from "../server/suggest.js";

// A client whose HTTP layer answers from a queue and records each request.
function fakeClient(replies) {
  const requests = [];
  const fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    requests.push(body);
    const out = replies.shift();
    if (!out) throw new Error("unexpected extra API call");
    return new Response(
      JSON.stringify({
        id: "msg",
        type: "message",
        role: "assistant",
        model: body.model,
        stop_reason: "end_turn",
        stop_sequence: null,
        usage: { input_tokens: 1, output_tokens: 1 },
        content: [{ type: "text", text: JSON.stringify(out) }],
      }),
      { status: 200, headers: { "content-type": "application/json" } },
    );
  };
  return { client: new Anthropic({ apiKey: "test", fetch, maxRetries: 0 }), requests };
}

const paper = { w: 1000, h: 1458 };
const turn = (client, utterances, current = null) =>
  decide({ client, imageBase64: "AAAA", mediaType: "image/jpeg", paper, utterances, current });
const flower = { placement: { x: 1, y: 1, w: 5, h: 5 }, strokes: [{ role: "contour", points: [[10, 10], [2000, 50]], closed: false, weight: "medium" }] };
const shown = { suggestion: flower, history: ["add a flower"] };

test("chatter stops at the Haiku filter: one cheap, text-only call", async () => {
  const { client, requests } = fakeClient([{ action: "ignore", note: "thinking aloud" }]);
  const r = await turn(client, ["hmm, the roof looks good"]);
  assert.equal(r.action, "ignore");
  assert.equal(requests.length, 1);
  assert.equal(requests[0].model, "claude-haiku-5-5");
  assert.equal(typeof requests[0].messages[0].content, "string", "filter should not get the image");
  assert.equal(requests[0].fallbacks, undefined);
});

test("a request goes on to the drawing model with the page photo", async () => {
  const { client, requests } = fakeClient([{ action: "new", note: "wants a flower" }, flower]);
  const r = await turn(client, ["add a flower by the house"]);
  assert.equal(r.action, "new");
  assert.equal(requests.length, 2);
  assert.equal(requests[1].model, "claude-opus-5-5");
  assert.equal(requests[1].messages[0].content[0].type, "image");
  assert.deepEqual(r.suggestion.strokes[0].points[1], [1000, 50], "points are clamped to the page");
});

test("revisions send the current outline to the drawing model", async () => {
  const { client, requests } = fakeClient([{ action: "revise", note: "bigger" }, flower]);
  const r = await turn(client, ["bigger"], shown);
  assert.equal(r.action, "revise");
  assert.match(requests[1].messages[0].content[1].text, /Outline currently shown/);
});

test("hide needs no drawing call", async () => {
  const { client, requests } = fakeClient([{ action: "hide", note: "done" }]);
  assert.equal((await turn(client, ["clear it"], shown)).action, "hide");
  assert.equal(requests.length, 1);
});

test("revise or hide with nothing shown is treated sensibly", async () => {
  let { client } = fakeClient([{ action: "revise", note: "?" }, flower]);
  assert.equal((await turn(client, ["make it a tree"])).action, "new");
  ({ client } = fakeClient([{ action: "hide", note: "?" }]));
  assert.equal((await turn(client, ["clear it"])).action, "ignore");
});

test("a drawing with no usable strokes becomes ignore", async () => {
  const empty = { placement: { x: 0, y: 0, w: 1, h: 1 }, strokes: [{ role: "contour", points: [[1, 1]], closed: false, weight: "light" }] };
  const { client } = fakeClient([{ action: "new", note: "x" }, empty]);
  const r = await turn(client, ["draw a bird"]);
  assert.equal(r.action, "ignore");
  assert.equal(r.suggestion, null);
});
