// A fake Claude API for checking the eval harness without a key or spend:
//   node eval/mock-api.mjs & ANTHROPIC_API_KEY=mock ANTHROPIC_BASE_URL=http://localhost:8899 node eval/run.mjs draw --label mock
// Every drawing is the same small circle below the figure; the filter is a few regexes.
import http from "node:http";
http.createServer((req, res) => {
  let body = ""; req.on("data", (c) => (body += c)); req.on("end", () => {
    const b = JSON.parse(body);
    if (req.url.includes("count_tokens")) { res.writeHead(200, {"content-type":"application/json"}); return res.end(JSON.stringify({ input_tokens: 3000 })); }
    const usage = { input_tokens: 3000, output_tokens: 800 };
    if (!b.stream) {
      const said = JSON.stringify(b.messages);
      const action = /clear|got it|never mind/.test(said) ? "hide" : /add|draw|give|put|stuck|what if/.test(said) ? "new" : /bigger|move|smaller|no,|instead|face|longer|red/.test(said) ? "revise" : "ignore";
      res.writeHead(200, {"content-type":"application/json"});
      return res.end(JSON.stringify({ id: "m", type: "message", role: "assistant", model: b.model, stop_reason: "end_turn", content: [{ type: "text", text: JSON.stringify({ action, note: "mock" }) }], usage }));
    }
    res.writeHead(200, {"content-type":"text/event-stream"});
    const send = (e) => res.write(`event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`);
    send({ type: "message_start", message: { id: "m", type: "message", role: "assistant", model: b.model, content: [], stop_reason: null, usage: { input_tokens: 3000, output_tokens: 1 } } });
    send({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
    const text = JSON.stringify({ parts: [{ name: "head", box: { x0: 372, y0: 85, x1: 530, y1: 197 } }], place: { reason: "x", box: { x0: 1, y0: 1, x1: 2, y1: 2 } },
      strokes: [{ role: "construction", weight: "light", d: "M 430 280 L 470 280" }, { role: "contour", weight: "medium", d: "M 430 280 C 430 250 470 250 470 280 C 470 310 430 310 430 280 Z" }] });
    let i = 0;
    const tick = setInterval(() => {
      if (i >= text.length) { clearInterval(tick); send({ type: "content_block_stop", index: 0 }); send({ type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 800 } }); send({ type: "message_stop" }); return res.end(); }
      send({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: text.slice(i, i + 20) } }); i += 20;
    }, 5);
  });
}).listen(8899);
