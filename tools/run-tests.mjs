// Runs the automated test pages in headless Chrome and prints the failures.
//   node tools/run-tests.mjs            (runs tests/run.html)
// Needs Node 22+, Chrome, and Python (`py`) for the throwaway local web server. Exit code 0 = all passed.
import { spawn } from "node:child_process";
import { mkdtempSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const page = (process.argv[2] || "run") + ".html";
const WEB = 8795, CDP = 9335, LIMIT_MS = 6 * 60 * 1000;
const chromePath = ["C:/Program Files/Google/Chrome/Application/chrome.exe", "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe", "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"].find(existsSync);
if (!chromePath) { console.error("Chrome or Edge not found."); process.exit(2); }
const sleep = ms => new Promise(r => setTimeout(r, ms));

const server = spawn("py", ["-m", "http.server", String(WEB), "--bind", "127.0.0.1"], { cwd: root, stdio: "ignore" });
const chrome = spawn(chromePath, [`--remote-debugging-port=${CDP}`, `--user-data-dir=${mkdtempSync(join(tmpdir(), "devlab-"))}`, "--headless=new", "--no-first-run", "--autoplay-policy=no-user-gesture-required", "--use-fake-ui-for-media-stream", "--window-size=1280,900", "about:blank"], { stdio: "ignore" });
const cleanup = () => { try { chrome.kill(); } catch (_) {} try { server.kill(); } catch (_) {} };
process.on("exit", cleanup);

let ws, id = 0; const pending = new Map();
const send = (method, params = {}) => new Promise((res, rej) => { const i = ++id; pending.set(i, { res, rej }); ws.send(JSON.stringify({ id: i, method, params })); });
const evaluate = async expr => { const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }); if (r.exceptionDetails) throw new Error(r.exceptionDetails.text); return r.result.value; };

try {
  let targets;
  for (let i = 0; i < 60; i++) { try { targets = await (await fetch(`http://127.0.0.1:${CDP}/json`)).json(); if (targets.length) break; } catch (_) {} await sleep(250); }
  const t = targets?.find(x => x.type === "page"); if (!t) throw new Error("Chrome didn't start");
  ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  ws.onmessage = m => { const d = JSON.parse(m.data); const p = pending.get(d.id); if (p) { pending.delete(d.id); d.error ? p.rej(new Error(d.error.message)) : p.res(d.result); } };
  await send("Page.enable"); await send("Runtime.enable");
  await send("Emulation.setFocusEmulationEnabled", { enabled: true });    // so animation frames run at full speed
  await send("Page.navigate", { url: `http://127.0.0.1:${WEB}/tests/${page}` });
  console.log(`Running tests/${page} in headless Chrome…`);
  const t0 = Date.now(); let done = null;
  while (Date.now() - t0 < LIMIT_MS) {
    await sleep(1500);
    try {   // finished when the page's "Run again" button appears; counts come from its summary line
      done = await evaluate(`(() => { if (window.testResult) return window.testResult; const b = document.getElementById("again"), m = /([0-9]+) passed, ([0-9]+) failed/.exec(document.getElementById("summary")?.textContent || ""); return b && !b.hidden && m ? { passed: +m[1], failed: +m[2] } : null; })()`);
    } catch (_) {}
    if (done) break;
  }
  if (!done) { console.error("Timed out. Last status: " + await evaluate("document.getElementById('summary')?.textContent").catch(() => "?")); process.exit(2); }
  const rows = await evaluate(`[...document.querySelectorAll("#out tr")].map(r => ({ scn: r.classList.contains("scn"), text: r.textContent }))`);
  let scn = "";
  for (const r of rows) { if (r.scn) { scn = r.text; continue; } if (/^FAIL/.test(r.text)) console.log(`FAIL [${scn}] ${r.text.slice(4, 500)}`); if (/^SKIP/.test(r.text)) console.log(`SKIP [${scn}] ${r.text.slice(4, 300)}`); }
  console.log(await evaluate("document.getElementById('summary').textContent"));
  process.exit(done.failed ? 1 : 0);
} catch (e) { console.error(e.message); process.exit(2); }
