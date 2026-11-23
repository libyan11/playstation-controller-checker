// Simulated PlayStation controllers (DualShock 4 and DualSense) for testing index.html without hardware.
// It follows the report formats the checker uses, so it proves the page's logic is self-consistent,
// not that every physical controller behaves identically.
//
//   const m = await import('./tests/mock-controller.js');
//   const dev = m.install({ type: 'ds4' | 'ds5', kind: 'genuine' | 'clone' | 'gioteck', transport: 'usb' | 'bt', gen: 1 | 2 });
//   'gioteck' mimics a Gioteck VX4 over Bluetooth, as measured on a real one: Sony's 2nd-gen ID, 1st-gen (JDM-001, 2014)
//   firmware, generic calibration (gyro ±8704, accel ±8192), ~32 updates a second, no lightbar.

const T = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
export const crc32 = u8 => { let c = 0xFFFFFFFF; for (const b of u8) c = T[(c ^ b) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; };
const dec = s => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));
const pad = (u8, n) => { const o = new Uint8Array(n); o.set(u8, n - u8.length); return o; };
const fail = msg => new DOMException(msg || "Failed to receive the feature report.", "NotAllowedError");
const MAC = [0x56, 0x34, 0x12, 0xE2, 0x1F, 0x00];        // example address 00:1F:E2:12:34:56 (little-endian)
const HOST = [0x66, 0x55, 0x44, 0x33, 0x22, 0x00];       // example host 00:22:33:44:55:66

let sharedKey = null;

// Payload offsets (report ID removed, Bluetooth header skipped), mirroring the checker's LAYOUT table
const LAYOUT = {
  ds4: { l2: 7, r2: 8, btn: 4, gyro: 12, acc: 18, ts: 9, tsBytes: 2, touch: 34, bat: 29, btId: 0x11, btOff: 2, usbLen: 63, btLen: 77 },
  ds5: { l2: 4, r2: 5, btn: 7, gyro: 15, acc: 21, ts: 27, tsBytes: 4, touch: 32, bat: 52, btId: 0x31, btOff: 1, usbLen: 63, btLen: 77 },
};

export class MockController {
  constructor({ type = "ds4", kind = "genuine", transport = "usb", gen = 2, mac = MAC } = {}) {
    Object.assign(this, { type, kind, transport, gen, mac });
    this.vendorId = 0x054C;
    this.productId = type === "ds5" ? 0x0CE6 : (gen === 1 && kind !== "gioteck" ? 0x05C4 : 0x09CC);
    this.productName = type === "ds5" ? "DualSense Wireless Controller" : "Wireless Controller";
    this.opened = false; this.listeners = new Set();
    this.state = { lx: 128, ly: 128, rx: 128, ry: 128, l2: 0, r2: 0, dpad: 8, b4hi: 0, b5: 0, b6: 0,
                   gyro: [0, 0, 0], acc: [0, 8192, 0], touch: false, battery: 7, cable: transport === "usb" };
    this.full = transport === "usb";         // Bluetooth starts with short reports until calibration is read
    this.ts = 0; this.counter = 0; this.outputs = []; this.errors = []; this.featureWrites = [];
    this.period = kind === "gioteck" ? 32 : transport === "usb" ? (kind === "clone" ? 8 : 4) : 1.33;
    this.auth = { pages: [], seq: 0, resp: null, readPage: 0, ready: false };
    this.pending80 = null;
  }
  get L() { return LAYOUT[this.type]; }
  async open() {
    this.opened = true; this.last = performance.now();
    this.timer = setInterval(() => {      // catch up on elapsed time so throttled timers still give the right count
      const now = performance.now(); let n = Math.floor((now - this.last) / this.period);
      if (n > 2000) n = 2000;
      for (let i = 0; i < n; i++) this.emit();
      this.last += n * this.period;
    }, 4);
  }
  async close() { this.opened = false; clearInterval(this.timer); }
  addEventListener(t, f) { if (t === "inputreport") this.listeners.add(f); }
  removeEventListener(t, f) { this.listeners.delete(f); }

  emit() {
    const s = this.state, Y = this.L;
    let reportId, buf;
    if (!this.full) { reportId = 1; buf = new Uint8Array(9); buf.set([s.lx, s.ly, s.rx, s.ry]); }
    else {
      const usb = this.transport === "usb", off = usb ? 0 : Y.btOff;
      reportId = usb ? 1 : Y.btId; buf = new Uint8Array(usb ? Y.usbLen : Y.btLen);
      const dv = new DataView(buf.buffer, off);
      dv.setUint8(0, s.lx); dv.setUint8(1, s.ly); dv.setUint8(2, s.rx); dv.setUint8(3, s.ry);
      dv.setUint8(Y.btn, (s.dpad & 0x0F) | s.b4hi); dv.setUint8(Y.btn + 1, s.b5);
      this.counter = (this.counter + 1) & (this.type === "ds5" ? 255 : 63);
      if (this.type === "ds5") { dv.setUint8(Y.btn + 2, s.b6 & 7); dv.setUint8(6, this.counter); }
      else dv.setUint8(6, (s.b6 & 3) | (this.counter << 2));
      dv.setUint8(Y.l2, s.l2); dv.setUint8(Y.r2, s.r2);
      if (this.kind !== "clone") this.ts = (this.ts + 750) >>> 0;
      if (Y.tsBytes === 4) dv.setUint32(Y.ts, this.ts, true); else dv.setUint16(Y.ts, this.ts & 0xFFFF, true);
      for (let i = 0; i < 3; i++) { dv.setInt16(Y.gyro + i * 2, s.gyro[i], true); dv.setInt16(Y.acc + i * 2, s.acc[i], true); }
      if (this.type === "ds5") dv.setUint8(Y.bat, ((s.cable ? (s.battery >= 10 ? 2 : 1) : 0) << 4) | Math.min(s.battery, 10));
      else dv.setUint8(Y.bat, (s.cable ? 0x10 : 0) | s.battery);
      dv.setUint8(Y.touch, s.touch ? 0x01 : 0x80);
      if (s.touch) { dv.setUint8(Y.touch + 1, 0x20); dv.setUint8(Y.touch + 2, 0x13); dv.setUint8(Y.touch + 3, 0x1F); }
    }
    const ev = { reportId, data: new DataView(buf.buffer), device: this };
    for (const f of this.listeners) f(ev);
  }

  feat(id, payload) { const o = new Uint8Array(payload.length + 1); o[0] = id; o.set(payload, 1); return new DataView(o.buffer); }

  calibration(id, grouped) {
    const p = new Uint8Array(id === 0x05 ? 40 : 36);
    if (this.kind === "clone") return this.feat(id, p);   // blank calibration
    const dv = new DataView(p.buffer);
    const generic = this.kind === "gioteck";             // same round value on every axis
    const gy = generic ? (grouped ? [8704, 8704, 8704, -8704, -8704, -8704] : [8704, -8704, 8704, -8704, 8704, -8704])
      : grouped ? [8800, 8790, 8805, -8800, -8810, -8795] : [8800, -8800, 8790, -8810, 8805, -8795];
    gy.forEach((v, i) => dv.setInt16(6 + i * 2, v, true));
    dv.setInt16(18, 540, true); dv.setInt16(20, 540, true);
    (generic ? [8192, -8192, 8192, -8192, 8192, -8192] : [8230, -8170, 8210, -8190, 8250, -8150]).forEach((v, i) => dv.setInt16(22 + i * 2, v, true));
    return this.feat(id, p);
  }

  async receiveFeatureReport(id) {
    const clone = this.kind === "clone", bt = this.transport === "bt";
    if (bt && (id === 0x05 || id === 0x02)) this.full = true;
    return this.type === "ds5" ? this.featureDS5(id, clone, bt) : this.featureDS4(id, clone, bt);
  }

  featureDS5(id, clone, bt) {
    const te = new TextEncoder();
    switch (id) {
      case 0x20: {
        const p = new Uint8Array(63), dv = new DataView(p.buffer);
        p.set(te.encode(clone ? "Jan 29 2034" : "Jun 10 2023"), 0); p.set(te.encode("10:20:30"), 11);
        dv.setUint32(23, clone ? 0x00009900 : 0x00000600, true);   // board byte 0x06 = BDM-040
        dv.setUint32(27, 0x0110002a, true);
        return this.feat(id, p);
      }
      case 0x05: return this.calibration(0x05, false);
      case 0x09: { const p = new Uint8Array(19); p.set(this.mac, 0); return this.feat(id, p); }
      case 0x81: {
        if (clone || !this.pending80) throw fail();
        const [a, b] = this.pending80; this.pending80 = null;
        const p = new Uint8Array(63); p[0] = a; p[1] = b === 2 ? 2 : b; p[2] = 2;
        return this.feat(id, p);
      }
      default: throw fail();
    }
  }

  featureDS4(id, clone, bt) {
    switch (id) {
      case 0xA3: {
        if (clone) throw fail();
        const p = new Uint8Array(48), te = new TextEncoder();
        // genuine 2nd gen: JDM-055 board (0xB4); genuine 1st gen: JDM-030 (0x54); Gioteck VX4: JDM-001 (0x31) firmware from 2014
        const g = this.kind === "gioteck";
        p.set(te.encode(g ? "Apr  8 2014" : this.gen === 1 ? "Apr  6 2015" : "Sep 21 2018"), 0); p.set(te.encode(g ? "09:46:06" : "04:50:51"), 16);
        const dv = new DataView(p.buffer);
        dv.setUint16(0x20, 0x0100, true); dv.setUint16(0x22, g ? 0x3100 : this.gen === 1 ? 0x5404 : 0xB400, true); dv.setUint32(0x24, 0x0001, true); dv.setUint16(0x28, 0x7001, true);
        return this.feat(id, p);
      }
      case 0x02: case 0x05: return this.calibration(id, id === 0x05);
      case 0x12: {
        if (bt) throw fail();
        const p = new Uint8Array(15);
        p.set(clone ? [0x01, 0x02, 0x03, 0x04, 0x05, 0x02] : this.mac, 0);   // clone: locally-administered address
        p.set([0x08, 0x25, 0x00], 6); p.set(HOST, 9);
        return this.feat(id, p);
      }
      case 0x81:   // genuine answers instantly; clones ignore it (DualShock Tools' check)
        if (clone) return new Promise(() => {});
        return this.feat(id, new Uint8Array(this.mac));
      case 0xF3:
        if (clone || bt || this.gen === 1) throw fail();   // real 1st-gen DS4s don't have 0xF3
        this.auth = { pages: [], seq: 0, resp: null, readPage: 0, ready: false };
        return this.feat(id, new Uint8Array([0, 0x38, 0x38, 0, 0, 0, 0]));
      case 0xF2: {
        if (clone || bt) throw fail();
        const p = new Uint8Array(15); p[0] = this.auth.seq; p[1] = this.auth.ready ? 0 : 0x10;
        return this.feat(id, p);
      }
      case 0xF1: {
        if (clone || bt || !this.auth.resp) throw fail();
        const page = this.auth.readPage++;
        const full = new Uint8Array(64); full[0] = 0xF1; full[1] = this.auth.seq; full[2] = page;
        full.set(this.auth.resp.subarray(page * 56, page * 56 + 56), 4);
        new DataView(full.buffer).setUint32(60, crc32(full.subarray(0, 60)), true);
        return new DataView(full.buffer);
      }
      default: throw fail();
    }
  }

  async sendFeatureReport(id, data) {
    this.featureWrites.push([id, Array.from(data)]);
    if (this.type === "ds5") {
      if (id !== 0x80 || this.kind === "clone") throw fail("Failed to send the feature report.");
      if (!(data[0] === 12 && data[1] === 2)) { this.errors.push("unexpected DS5 0x80 write " + Array.from(data)); throw fail("bad"); }
      this.pending80 = [data[0], data[1]];
      return;
    }
    if (id !== 0xF0 || this.kind === "clone" || this.transport === "bt") throw fail("Failed to send the feature report.");
    const full = new Uint8Array(64); full[0] = 0xF0; full.set(data, 1);
    if (data.length !== 63) { this.errors.push("0xF0 wrong length " + data.length); throw fail("bad length"); }
    if (new DataView(full.buffer).getUint32(60, true) !== crc32(full.subarray(0, 60))) { this.errors.push("0xF0 bad CRC"); throw fail("bad CRC"); }
    const seq = full[1], page = full[2];
    if (page === 0) this.auth = { pages: [], seq, resp: null, readPage: 0, ready: false };
    this.auth.pages[page] = full.slice(4, 60);
    if (page === 4) {
      const nonce = new Uint8Array(280); this.auth.pages.forEach((p, i) => nonce.set(p, i * 56));
      this.sign(nonce.subarray(0, 256));
    }
  }

  async sign(nonce) {
    sharedKey ||= await crypto.subtle.generateKey({ name: "RSA-PSS", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
    const sig = new Uint8Array(await crypto.subtle.sign({ name: "RSA-PSS", saltLength: 32 }, sharedKey.privateKey, nonce));
    const jwk = await crypto.subtle.exportKey("jwk", sharedKey.publicKey);
    const resp = new Uint8Array(19 * 56);
    resp.set(sig, 0); resp.set(new TextEncoder().encode("MOCKSERIAL000001"), 256);
    resp.set(pad(dec(jwk.n), 256), 272); resp.set(pad(dec(jwk.e), 256), 528);
    resp.set(crypto.getRandomValues(new Uint8Array(256)), 784);
    this.auth.resp = resp;
    setTimeout(() => { this.auth.ready = true; }, 200);
  }

  async sendReport(id, data) {
    const full = new Uint8Array(data.length + 1); full[0] = id; full.set(data, 1);
    const checkCrc = () => {
      const crcBuf = new Uint8Array(75); crcBuf[0] = 0xA2; crcBuf.set(full.subarray(0, 74), 1);
      if (new DataView(full.buffer).getUint32(74, true) !== crc32(crcBuf)) { this.errors.push("BT output bad CRC"); throw fail("bad CRC"); }
    };
    let rgb, weak, strong, lightOn = true;
    if (this.type === "ds5") {
      let c;
      if (this.transport === "bt") {
        if (id !== 0x31 || full.length !== 78 || full[2] !== 0x10) { this.errors.push(`DS5 BT output wrong id/len/tag ${id}/${full.length}/${full[2]}`); throw fail("bad output"); }
        checkCrc(); c = full.subarray(3, 50);
      } else {
        if (id !== 0x02 || full.length !== 48) { this.errors.push(`DS5 USB output wrong id/len ${id}/${full.length}`); throw fail("bad output"); }
        c = full.subarray(1, 48);
      }
      if (c[38] & 0x02) return;            // lightbar release (setup) report: no colour change
      lightOn = !!(c[1] & 0x04);
      weak = c[2]; strong = c[3]; rgb = [c[44], c[45], c[46]];
      if (!(c[0] & 0x03)) { weak = strong = 0; }
    } else if (this.transport === "bt") {
      if (id !== 0x11 || full.length !== 78) { this.errors.push(`BT output wrong id/len ${id}/${full.length}`); throw fail("bad output"); }
      checkCrc();
      weak = full[6]; strong = full[7]; rgb = [full[8], full[9], full[10]];
    } else {
      if (id !== 0x05 || full.length !== 32) { this.errors.push(`USB output wrong id/len ${id}/${full.length}`); throw fail("bad output"); }
      weak = full[4]; strong = full[5]; rgb = [full[6], full[7], full[8]];
    }
    if (!lightOn || this.kind === "gioteck") rgb = [0, 0, 0];   // the VX4 has no lightbar
    if (this.kind === "clone") rgb = [rgb[2], rgb[0], rgb[1]];   // a clone with swapped LED channels
    this.outputs.push({ rgb, weak, strong });
  }
}

export function install(opts, win = window) {
  const dev = new MockController(opts);
  win.navigator.hid.requestDevice = async () => [dev];
  win.mockDev = dev;
  return dev;
}

// Answers the lightbar quiz the way a person would, based on what the simulated LEDs and motors did.
export async function autoAnswerLights(dev, timeoutMs = 30000, doc = document) {
  const end = Date.now() + timeoutMs;
  const colorName = ([r, g, b]) => r > 200 && g < 50 && b < 50 ? "Red" : g > 200 && r < 50 && b < 50 ? "Green" : b > 200 && r < 50 && g < 50 ? "Blue" : (r | g | b) ? "Other colour" : "Off";
  while (Date.now() < end) {
    await new Promise(r => setTimeout(r, 50));
    const q = doc.getElementById("lightQ");
    if (q.classList.contains("hidden")) { if (doc.getElementById("lightStatus").textContent === "Done.") return true; continue; }
    const text = doc.getElementById("lightQText").textContent;
    const btns = [...doc.getElementById("lightQBtns").children];
    if (!btns.length) continue;
    const click = label => btns.find(b => b.textContent === label)?.click();
    const out = dev.outputs[dev.outputs.length - 1];
    if (text.startsWith("Colour")) click(colorName(out.rgb));
    else if (text.startsWith("Rumble")) click("Start");
    else if (text.startsWith("Which side")) {
      const r = dev.outputs.slice().reverse().find(o => o.weak || o.strong);
      click(!r ? "Neither" : r.strong && r.weak ? "Both" : r.strong ? "Left" : "Right");
    }
  }
  return false;
}
