import { test } from "node:test";
import assert from "node:assert/strict";
import Anthropic from "@anthropic-ai/sdk";
import { runTurn } from "../server/suggest.js";

// A client whose HTTP layer answers from a queue and records each request.
// Streaming requests get the reply as server-sent events, split into chunks.
function fakeClient(replies) {
  const requests = [];
  const fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    requests.push(body);
    const out = replies.shift();
    if (!out) throw new Error("unexpected extra API call");
    const text = JSON.stringify(out);
    const message = { id: "msg", type: "message", role: "assistant", model: body.model, stop_sequence: null };
    if (!body.stream) {
      return Response.json({ ...message, stop_reason: "end_turn", usage: { input_tokens: 1, output_tokens: 1 }, content: [{ type: "text", text }] });
    }
    const ev = (type, data) => `event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`;
    let sse = ev("message_start", { message: { ...message, stop_reason: null, content: [], usage: { input_tokens: 1, output_tokens: 0 } } });
    sse += ev("content_block_start", { index: 0, content_block: { type: "text", text: "" } });
    for (let i = 0; i < text.length; i += 9) sse += ev("content_block_delta", { index: 0, delta: { type: "text_delta", text: text.slice(i, i + 9) } });
    sse += ev("content_block_stop", { index: 0 });
    sse += ev("message_delta", { delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 1 } });
    sse += ev("message_stop", {});
    return new Response(sse, { status: 200, headers: { "content-type": "text/event-stream" } });
  };
  return { client: new Anthropic({ apiKey: "test", fetch, maxRetries: 0 }), requests };
}

const paper = { w: 1000, h: 1458 };
async function turn(client, utterances, current = null) {
  const events = [];
  const result = await runTurn({ client, imageBase64: "AAAA", mediaType: "image/jpeg", paper, utterances, current, emit: (e) => events.push(e) });
  return { result, events, strokes: events.filter((e) => e.type === "stroke").map((e) => e.stroke) };
}
const drawing = {
  strokes: [
    { role: "construction", weight: "light", d: "M 100 100 C 100 50 200 50 200 100 Z" },
    { role: "contour", weight: "medium", d: "M 150 100 L 150 2000" },
  ],
};
const shown = { suggestion: { strokes: [{ role: "contour", weight: "medium", d: "M 1 1 L 9 9" }] }, history: ["add a flower"] };

test("chatter stops at the Haiku filter: one cheap, text-only call", async () => {
  const { client, requests } = fakeClient([{ action: "ignore", note: "thinking aloud" }]);
  const { result, events } = await turn(client, ["hmm, the roof looks good"]);
  assert.equal(result.action, "ignore");
  assert.deepEqual(events, [{ type: "action", action: "ignore" }, { type: "done" }]);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].model, "claude-haiku-5-5");
  assert.equal(typeof requests[0].messages[0].content, "string", "filter should not get the image");
  assert.equal(requests[0].fallbacks, undefined);
});

test("a request streams strokes from Sonnet, in order, flattened and clamped", async () => {
  const { client, requests } = fakeClient([{ action: "new", note: "wants a flower" }, drawing]);
  const { result, events, strokes } = await turn(client, ["add a flower by the house"]);
  assert.equal(result.action, "new");
  assert.equal(requests[1].model, "claude-sonnet-5-5");
  assert.equal(requests[1].stream, true);
  assert.equal(requests[1].messages[0].content[0].type, "image");
  assert.deepEqual(events.map((e) => e.type), ["action", "stroke", "stroke", "done"]);
  assert.equal(strokes[0].role, "construction");
  assert.equal(strokes[0].closed, true);
  assert.deepEqual(strokes[1].points.at(-1), [150, 1458]);
});

test("revisions send the current outline as compact path data", async () => {
  const { client, requests } = fakeClient([{ action: "revise", note: "bigger" }, drawing]);
  await turn(client, ["bigger"], shown);
  const text = requests[1].messages[0].content[1].text;
  assert.match(text, /Outline currently shown/);
  assert.match(text, /"d":"M 1 1 L 9 9"/);
});

test("hide needs no drawing call", async () => {
  const { client, requests } = fakeClient([{ action: "hide", note: "done" }]);
  assert.equal((await turn(client, ["clear it"], shown)).result.action, "hide");
  assert.equal(requests.length, 1);
});

test("revise or hide with nothing shown is treated sensibly", async () => {
  let { client } = fakeClient([{ action: "revise", note: "?" }, drawing]);
  assert.equal((await turn(client, ["make it a tree"])).result.action, "new");
  ({ client } = fakeClient([{ action: "hide", note: "?" }]));
  assert.equal((await turn(client, ["clear it"])).result.action, "ignore");
});

test("malformed strokes are dropped, good ones still arrive", async () => {
  const mixed = { strokes: [{ role: "contour", weight: "medium", d: "M 1 1" }, ...drawing.strokes] };
  const { client } = fakeClient([{ action: "new", note: "x" }, mixed]);
  const { strokes } = await turn(client, ["draw a bird"]);
  assert.equal(strokes.length, 2);
});
