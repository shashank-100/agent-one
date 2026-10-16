// The agent loop, in the browser, against the phone in the frame: capture the screen, ask the model for one
// action (/api/step), perform it on the phone, repeat. Mirrors Sources/PhoneUseCore/Agent.swift.
(function () {
  "use strict";
  const DPR = 3, W = 1080, H = 2400, MAX_STEPS = 25, SETTLE_MS = 900, KEEP_IMAGES = 2;
  const SHOT_LIB = "https://cdn.jsdelivr.net/npm/modern-screenshot@4.4.39/dist/index.js";
  const RISK_WORDS = ["send", "post", "publish", "reply", "share", "pay", "buy", "purchase", "order", "checkout", "subscribe", "transfer",
    "book", "reserve", "confirm", "submit", "approve", "accept", "delete", "remove", "erase", "unsubscribe", "log out", "sign out"];

  const $ = (id) => document.getElementById(id);
  const frame = $("phone"), logEl = $("log"), statusEl = $("status");
  let stopRequested = false, running = false, apps = {};

  const win = () => frame.contentWindow;
  const doc = () => frame.contentDocument;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  function status(html) { statusEl.innerHTML = html; }

  // ---- the phone ----
  async function phoneReady() {
    for (let i = 0; i < 300; i++) {
      const w = win();
      if (w && w.__SIM_INPUT__ && w.__OS__ && w.__SIM__) return w;
      await sleep(200);
    }
    throw new Error("the phone did not start");
  }

  async function loadShotLib() {
    const w = win();
    if (w.modernScreenshot) return;
    await new Promise((resolve, reject) => {
      const s = doc().createElement("script");
      s.src = SHOT_LIB; s.onload = resolve; s.onerror = () => reject(new Error("could not load the screenshot library"));
      doc().head.appendChild(s);
    });
  }

  // The screenshot library copies a text box's inner text and its value, so a typed note showed twice (and
  // the agent "fixed" text that was fine). Stamp each box's real value, then render exactly that, once.
  function stampFieldValues() {
    for (const el of doc().querySelectorAll("input, textarea")) {
      el.setAttribute("data-a1-value", el.type === "password" ? "" : el.value);
    }
    // The copy also loses scroll positions (a time wheel showed 57 when it was at 13), so stamp them too.
    for (const el of doc().querySelectorAll("[data-a1-scroll]")) el.removeAttribute("data-a1-scroll");
    for (const el of doc().body.querySelectorAll("*")) {
      if (el.scrollTop || el.scrollLeft) el.setAttribute("data-a1-scroll", `${el.scrollLeft},${el.scrollTop}`);
    }
  }
  function onCloneNode(node) {
    if (!node || node.nodeType !== 1) return;
    const scrolled = node.matches?.("[data-a1-scroll]") ? [node] : Array.from(node.querySelectorAll?.("[data-a1-scroll]") || []);
    for (const el of scrolled) {
      const [left, top] = el.getAttribute("data-a1-scroll").split(",").map(Number);
      el.style.overflow = "hidden";
      for (const child of el.children) {
        const prev = child.style.transform && child.style.transform !== "none" ? " " + child.style.transform : "";
        child.style.transform = `translate(${-left}px, ${-top}px)${prev}`;
      }
    }
    const boxes = node.matches?.("input, textarea") ? [node] : Array.from(node.querySelectorAll?.("input, textarea") || []);
    for (const box of boxes) {
      const v = box.getAttribute("data-a1-value");
      if (v === null) continue;
      if (box.tagName === "TEXTAREA") box.textContent = v;
      else { box.setAttribute("value", v); box.value = v; }
    }
  }

  const withTimeout = (promise, ms, what) => Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error(`${what} took longer than ${ms / 1000}s`)), ms))]);

  /** JPEG base64 of the phone screen, or null when it could not be taken in time (the element list still goes). */
  async function capture() {
    try {
      await loadShotLib();
      stampFieldValues();
      const url = await withTimeout(win().modernScreenshot.domToJpeg(doc().documentElement, { width: 360, height: 800, scale: DPR, quality: 0.8, backgroundColor: "#ffffff", onCloneNode }), 20000, "the screenshot");
      return url.slice(url.indexOf(",") + 1);
    } catch (e) {
      console.warn("[agent] screenshot failed:", e.message);
      return null;
    }
  }

  async function askModel(body) {
    for (let attempt = 1; attempt <= 2; attempt++) {
      const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), 180000);
      try {
        const res = await fetch("/api/step", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), signal: ctl.signal });
        const reply = await res.json();
        if (res.ok || attempt === 2) return { res, reply };
      } catch (e) {
        if (attempt === 2) return { res: { ok: false, status: 0 }, reply: { error: e.name === "AbortError" ? "the model took longer than 180s, twice" : e.message } };
      } finally { clearTimeout(timer); }
    }
  }

  // Visible things worth tapping or reading, with boxes in screenshot pixels.
  function elements() {
    const d = doc(), out = [], seen = new Set();
    const candidates = d.querySelectorAll("[data-trigger],[data-action],button,a,input,textarea,[role=button],[role=switch],[role=tab],[contenteditable=true],span,p,div,h1,h2,h3,label");
    for (const el of candidates) {
      const r = el.getBoundingClientRect();
      if (r.width < 6 || r.height < 6 || r.bottom <= 0 || r.right <= 0 || r.top >= 800 || r.left >= 360) continue;
      const st = win().getComputedStyle(el);
      if (st.visibility === "hidden" || st.display === "none" || Number(st.opacity) === 0) continue;
      if (!onTop(d, el, r)) continue;
      const interactive = el.matches("[data-trigger],[data-action],button,a,input,textarea,select,[role=button],[role=switch],[role=tab],[role=slider],[contenteditable=true]");
      let text = "";
      if (el.matches("input,textarea")) text = el.value || el.placeholder || el.getAttribute("aria-label") || "";
      else {
        const own = Array.from(el.childNodes).filter((n) => n.nodeType === 3).map((n) => n.textContent.trim()).join(" ").trim();
        text = interactive ? (el.getAttribute("aria-label") || el.innerText || "").trim() : own;
      }
      text = text.replace(/\s+/g, " ").slice(0, 60);
      if (!text && !interactive) continue;
      const box = [Math.round(r.left * DPR), Math.round(r.top * DPR), Math.round(r.width * DPR), Math.round(r.height * DPR)];
      const key = text + box.join(",");
      if (seen.has(key)) continue;
      seen.add(key);
      const sw = el.matches("[role=switch]") ? ` (switch ${el.getAttribute("aria-checked") === "true" ? "on" : "off"})`
        : el.matches("[role=slider]") ? ` (slider at ${el.getAttribute("aria-valuenow")})` : "";
      out.push({ text, box, interactive, el, line: `${interactive ? "•" : "-"} "${text}"${sw} [x=${box[0]} y=${box[1]} w=${box[2]} h=${box[3]}]` });
    }
    out.sort((a, b) => a.box[1] - b.box[1] || a.box[0] - b.box[0]);
    return out.slice(0, 90);
  }

  // Leave out anything a finger can't reach: under the keyboard, a sheet or a dialog, or scrolled out of
  // its box. Otherwise the model taps the keyboard where the list says a field is.
  function onTop(d, el, r) {
    const left = Math.max(r.left, 0), right = Math.min(r.right, 360), top = Math.max(r.top, 0), bottom = Math.min(r.bottom, 800);
    const cx = (left + right) / 2;
    for (const y of [(top + bottom) / 2, top + 3, bottom - 3]) {
      const hit = d.elementFromPoint(cx, y);
      if (hit && (hit === el || el.contains(hit) || hit.contains(el))) return true;
    }
    return false;
  }

  function showTap(x, y) {
    const dot = $("tapdot"), bezel = $("bezel"), f = frame.getBoundingClientRect(), s = bezel.parentElement.getBoundingClientRect();
    dot.style.left = (f.left - s.left + (x / DPR) * (f.width / 360)) + "px";
    dot.style.top = (f.top - s.top + (y / DPR) * (f.height / 800)) + "px";
    dot.classList.remove("show"); void dot.offsetWidth; dot.classList.add("show");
  }

  const clamp = (v, max) => Math.max(0, Math.min(max - 1, Math.round(Number(v) || 0)));

  // The simulator's tap does not move keyboard focus between text fields, so typing went into whichever
  // field was focused first. A real finger focuses the field it lands on; do the same.
  function focusFieldAt(x, y) {
    const el = doc().elementFromPoint(x / DPR, y / DPR);
    if (!el) return false;
    const field = el.closest("input, textarea, [contenteditable='true']") || el.closest("label")?.querySelector("input, textarea");
    if (!field || field.disabled || field.type === "hidden") return false;
    if (doc().activeElement !== field) field.focus({ preventScroll: true });
    return true;
  }

  async function perform(name, input) {
    const w = win(), inp = w.__SIM_INPUT__, os = w.__OS__;
    switch (name) {
      case "tap": { const x = clamp(input.x, W), y = clamp(input.y, H); showTap(x, y); inp.tap(x / DPR, y / DPR); focusFieldAt(x, y); return "Tapped."; }
      case "long_press": { const x = clamp(input.x, W), y = clamp(input.y, H); showTap(x, y); await inp.longPress(x / DPR, y / DPR, 800); return "Held."; }
      case "swipe": await inp.swipe({ x: clamp(input.from_x, W), y: clamp(input.from_y, H) }, { x: clamp(input.to_x, W), y: clamp(input.to_y, H) }, { coords: "physical", dpr: DPR, ms: 450, inertia: false }); return "Swiped.";
      case "scroll": {
        const dy = { down: -700, up: 700, left: 0, right: 0 }[input.direction] ?? 0, dx = { left: 600, right: -600 }[input.direction] ?? 0;
        await inp.swipe({ x: W / 2 - dx / 2, y: H / 2 - dy / 2 }, { x: W / 2 + dx / 2, y: H / 2 + dy / 2 }, { coords: "physical", dpr: DPR, ms: 500, inertia: false });
        return `Scrolled ${input.direction}.`;
      }
      case "type_text": {
        if (input.x != null && input.y != null) {
          const x = clamp(input.x, W), y = clamp(input.y, H); showTap(x, y); inp.tap(x / DPR, y / DPR); await sleep(250);
          if (!focusFieldAt(x, y)) return { error: `There is no text field at ${x},${y}. Check the element list for the field's box and try again.` };
          await sleep(100);
        }
        try { await inp.type(String(input.text ?? ""), { clear: !!input.clear }); }
        catch (e) { return { error: "Nothing to type into: tap a text field first. " + e.message }; }
        const v = doc().activeElement && "value" in doc().activeElement ? doc().activeElement.value : null;
        return v != null ? `Typed. The field now holds: "${String(v).slice(0, 120)}"` : "Typed.";
      }
      case "set_value": {
        const e = (lastEls || [])[Number(input.element) - 1];
        if (!e) return { error: `There is no element ${input.element} in the list on this screen.` };
        const el = e.el, value = String(input.value ?? "");
        if (el.matches("[role=slider]")) {
          const pct = Math.min(100, Math.max(0, parseFloat(value)));
          if (Number.isNaN(pct)) return { error: "A slider needs a number from 0 to 100." };
          const r = el.getBoundingClientRect(), x = r.left + (r.width * pct) / 100, y = r.top + r.height / 2;
          const o = { bubbles: true, clientX: x, clientY: y, pointerId: 1, buttons: 1, view: w };
          el.dispatchEvent(new w.PointerEvent("pointerdown", o)); el.dispatchEvent(new w.PointerEvent("pointerup", { ...o, buttons: 0 }));
          return `Set to ${pct}%.`;
        }
        if (el.matches("input,textarea,select")) {
          const proto = el.tagName === "TEXTAREA" ? w.HTMLTextAreaElement.prototype : el.tagName === "SELECT" ? w.HTMLSelectElement.prototype : w.HTMLInputElement.prototype;
          el.focus();
          Object.getOwnPropertyDescriptor(proto, "value").set.call(el, value);
          el.dispatchEvent(new w.Event("input", { bubbles: true })); el.dispatchEvent(new w.Event("change", { bubbles: true }));
          return `Set to "${value.slice(0, 60)}".`;
        }
        return { error: "set_value works on sliders, text fields and drop-downs. Use tap or swipe here." };
      }
      case "press_enter": {
        const el = doc().activeElement || doc().body;
        for (const type of ["keydown", "keypress", "keyup"]) el.dispatchEvent(new w.KeyboardEvent(type, { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true }));
        return "Pressed Return.";
      }
      case "open_app": {
        const want = String(input.name || "").toLowerCase().replace(/\s+app$/, "").trim();
        const id = apps[want] || Object.entries(apps).find(([k]) => k.includes(want) || want.includes(k))?.[1];
        if (!id) return { error: `No installed app matches "${input.name}". Installed: ${[...new Set(Object.values(apps))].join(", ")}` };
        os.launchApp(id); await sleep(600); return `Opened ${input.name}.`;
      }
      case "go_home": os.goHome(); return "On the home screen.";
      case "go_back": (os.handleBack ? os.handleBack() : w.history.back()); return "Went back.";
      case "wait": await sleep(Math.min(10, Math.max(1, Number(input.seconds) || 2)) * 1000); return "Waited.";
      default: return { error: `unknown action ${name}` };
    }
  }

  // ---- the person ----
  function askPerson(title, detail, { input = false, yes = "Allow", no = "Don't allow" } = {}) {
    return new Promise((resolve) => {
      const box = $("ask"), field = $("ask-input");
      $("ask-title").textContent = title; $("ask-detail").textContent = detail;
      $("ask-yes").textContent = yes; $("ask-no").textContent = no;
      field.hidden = !input; field.value = "";
      box.hidden = false;
      const done = (v) => { box.hidden = true; $("ask-yes").onclick = $("ask-no").onclick = null; resolve(v); };
      $("ask-yes").onclick = () => done(input ? field.value || null : true);
      $("ask-no").onclick = () => done(input ? null : false);
      stopHooks.push(() => done(input ? null : false));
    });
  }
  let stopHooks = [];

  function needsApproval(target, flagged) {
    if (flagged) return true;
    const label = String(target || "").toLowerCase();
    const words = new Set(label.split(/[^a-z]+/));
    return RISK_WORDS.some((w) => (w.includes(" ") ? label.includes(w) : words.has(w)));
  }

  // ---- log ----
  function logStep(n, act, why, result, cls) {
    const li = document.createElement("li");
    li.innerHTML = '<span class="n"></span><span><div class="act"></div><div class="why"></div><div></div></span>';
    li.children[0].textContent = n;
    li.querySelector(".act").textContent = act;
    li.querySelector(".why").textContent = why || "";
    const r = li.children[1].children[2]; r.textContent = result || ""; r.className = cls || "res";
    logEl.appendChild(li); li.scrollIntoView({ block: "nearest" });
  }

  // The model names an element by its number in the list; the tap goes to the centre of that element's box.
  // Guessing pixels from the screenshot missed small targets like calculator keys.
  function toPoint(input, els) {
    const n = Number(input.element);
    if (input.element == null || !n) return null;
    const e = els[n - 1];
    if (!e) return { error: `There is no element ${input.element} in the list on this screen.` };
    input.x = e.box[0] + Math.round(e.box[2] / 2); input.y = e.box[1] + Math.round(e.box[3] / 2);
    if (!input.target) input.target = e.text;
    return null;
  }

  // ---- the loop ----
  let lastListed = "", lastEls = [];
  function screenText(els) {
    const list = els.map((e, i) => `${i + 1} ${e.line}`).join("\n");
    const size = `The screenshot is ${W} pixels wide and ${H} pixels high.`;
    if (list && list === lastListed) return `${size} Elements on screen: unchanged since the last list (same numbers). If you just acted, that action changed nothing: try another way.`;
    lastListed = list;
    return `${size} ${LIST_MARK}\n${list}`;
  }

  // Waits until the screen stops changing (same element list twice, about 0.3 s apart; at most ~3 s) instead of a
  // fixed pause, so the model never sees a half-loaded screen. (macos-harness does the same before every read.)
  async function settle() {
    await sleep(350);
    let prev = elements().map((e) => e.line).join("|");
    for (let i = 0; i < 9; i++) {
      await sleep(300);
      const now = elements().map((e) => e.line).join("|");
      if (now === prev) return;
      prev = now;
    }
  }

  // Only the newest screen matters: older screenshots beyond KEEP_IMAGES and every older element list are
  // replaced by a short note, so a step costs about the same at step 20 as at step 2.
  const LIST_MARK = "Elements on screen, numbered (• can be tapped):";
  function dropOldElementLists(copy) {
    let newest = true;
    for (let i = copy.length - 1; i >= 0; i--) {
      const m = copy[i];
      if (m.role !== "user" || !Array.isArray(m.content)) continue;
      const texts = [];
      for (const b of m.content) {
        if (b.type === "text") texts.push(b);
        if (b.type === "tool_result" && Array.isArray(b.content)) for (const c of b.content) if (c.type === "text") texts.push(c);
      }
      for (const t of texts) {
        const at = t.text.indexOf(LIST_MARK);
        if (at < 0) continue;
        if (!newest) t.text = t.text.slice(0, at) + "(Element list of an earlier screen, not repeated.)";
      }
      if (texts.some((t) => t.text.includes(LIST_MARK))) newest = false;
    }
    return copy;
  }

  function trimImages(messages) {
    let seen = 0;
    const copy = dropOldElementLists(JSON.parse(JSON.stringify(messages)));
    for (let i = copy.length - 1; i >= 0; i--) {
      const m = copy[i];
      if (m.role !== "user" || !Array.isArray(m.content)) continue;
      for (const b of m.content) {
        const holders = b.type === "tool_result" && Array.isArray(b.content) ? b.content : [b];
        for (let j = 0; j < holders.length; j++) {
          if (holders[j].type !== "image") continue;
          if (++seen > KEEP_IMAGES) holders[j] = { type: "text", text: "(An earlier screen, not shown again.)" };
        }
        if (b.type === "image" && seen > KEEP_IMAGES) Object.assign(b, { type: "text", text: "(An earlier screen, not shown again.)" }, { source: undefined });
      }
    }
    return copy;
  }

  async function run(task) {
    running = true; stopRequested = false; stopHooks = [];
    $("run").disabled = true; $("stop").disabled = false; logEl.innerHTML = "";
    const messages = [];
    let pending = [], misses = 0, repeat = { key: "", count: 0 }, tokens = { input: 0, output: 0 };
    const started = Date.now();
    let before = null, endText = "", stepCount = 0;
    const trail = [];
    lastListed = "";
    try { before = JSON.parse(JSON.stringify(win().__SIM__.getState())); } catch {}
    const end = (text, cls = "end") => { endText = text; stepCount = $("log").querySelectorAll("li").length; logStep("■", text, "", `${((Date.now() - started) / 1000).toFixed(0)}s · ${tokens.input} tokens in, ${tokens.output} out`, cls); status(`<b>${text}</b>`); };
    try {
      for (let step = 1; step <= MAX_STEPS; step++) {
        if (stopRequested) return end("Stopped by you.", "err");
        status(`Step ${step}: looking at the screen…`);
        const els = elements(), jpeg = await capture();
        lastEls = els;
        const img = jpeg ? { type: "image", source: { type: "base64", media_type: "image/jpeg", data: jpeg } }
          : { type: "text", text: "(The screenshot could not be taken this step; use the element list.)" };
        if (!messages.length) {
          const installed = [...new Set(Object.values(apps))].map((id) => Object.entries(apps).find(([k, v]) => v === id && /[A-Z]/.test(k[0]) === false && k.length > 2)?.[0] || id);
          messages.push({ role: "user", content: [{ type: "text", text: `Task: ${task}\n\nInstalled apps: ${installed.join(", ")}.${skillText(task)}\n\n${screenText(els)}` }, img] });
        }
        else if (!pending.length) messages.push({ role: "user", content: [{ type: "text", text: "Reply with exactly one tool call.\n\n" + screenText(els) }, img] });
        else {
          const blocks = pending.map((p, i) => {
            const last = i === pending.length - 1;
            const content = [{ type: "text", text: last ? `${p.text}\n\n${screenText(els)}` : p.text }];
            if (last) content.push(img);
            return { type: "tool_result", tool_use_id: p.id, content, ...(p.error ? { is_error: true } : {}) };
          });
          messages.push({ role: "user", content: blocks });
        }
        pending = [];

        status(`Step ${step}: deciding…`);
        // Claude Code receives the complete history; do not rewrite earlier turns.
        const { res, reply } = await askModel({ messages });
        if (!res.ok) return end(`Model call failed: ${reply.error || res.status}`, "err");
        tokens.input += reply.usage?.input || 0; tokens.output += reply.usage?.output || 0;
        messages.push({ role: "assistant", content: reply.content });
        if (reply.stop === "refusal") return end("The model declined this task.", "err");

        const why = reply.content.filter((b) => b.type === "text").map((b) => b.text).join(" ").trim();
        const calls = reply.content.filter((b) => b.type === "tool_use");
        if (!calls.length) {
          if (++misses >= 3) return end("The model stopped choosing actions.", "err");
          logStep(step, "(no action)", why, "asked again", "err");
          continue;
        }
        misses = 0;
        const call = calls[0];
        const describe = (c) => c.name + (c.input?.target ? ` "${c.input.target}"` : c.input?.text ? ` "${c.input.text}"` : c.input?.element ? ` element ${c.input.element}` : "");
        const skipped = calls.slice(1).map(describe);
        calls.slice(1).forEach((c) => pending.push({ id: c.id, text: `NOT performed: ${describe(c)}. Only one action per turn is carried out.`, error: true }));
        const skippedNote = skipped.length ? ` Only this first action was carried out; these were NOT: ${skipped.join(", ")}. Do them now, one per turn.` : "";
        const input = call.input || {};
        const picked = toPoint(input, els);
        if (picked?.error) { pending.push({ id: call.id, text: picked.error, error: true }); logStep(step, call.name, why, picked.error, "err"); continue; }
        const label = call.name + (input.target ? ` "${input.target}"` : input.name ? ` "${input.name}"` : input.text ? ` "${input.text}"` : input.direction ? ` ${input.direction}` : "") + (input.x != null ? ` @ ${input.x},${input.y}` : "");

        if (call.name === "finish") return end(`${input.success ? "Done" : "Could not finish"}: ${input.answer || ""}`, input.success ? "end" : "err");

        // stuck: the same action on an unchanged screen
        const key = call.name + JSON.stringify(input) + els.map((e) => e.text).join("|");
        repeat = key === repeat.key ? { key, count: repeat.count + 1 } : { key, count: 1 };
        if (repeat.count >= 6) return end("Stopped: the same action six times on a screen that did not change.", "err");

        let result;
        try {
          if (call.name === "tap" && needsApproval(input.target, input.irreversible)) {
            status(`Step ${step}: <b>waiting for your Allow</b>`);
            const ok = autoAllow || await askPerson("Allow this tap?", `tap "${input.target || "?"}" at ${input.x},${input.y}`);
            result = ok ? await perform(call.name, input) : "The user refused this tap. Do not try another way: call finish with success false and say what was left undone.";
          } else if (call.name === "hand_over") {
            const ok = !autoAllow && await askPerson("Your turn on the phone", input.reason || "", { yes: "Done, carry on", no: "Stop the task" });
            if (!ok) return end("Stopped by you during a hand-over.", "err");
            result = "The user has done their part. Carry on.";
          } else if (call.name === "ask_user") {
            const answer = autoAllow ? null : await askPerson(input.question || "Question", "", { input: true, yes: "Send", no: "Skip" });
            result = answer ? `The user answered: ${answer}` : "The user did not answer.";
          } else {
            status(`Step ${step}: ${label}`);
            result = await perform(call.name, input);
          }
        } catch (e) {
          result = { error: `The action failed: ${e.message}` };
        }
        const errorText = typeof result === "object" ? result.error : null;
        let text = errorText || result;
        if (repeat.count >= 3) text += " This is the same action on an unchanged screen again; it is not working. Try something else.";
        pending.push({ id: call.id, text: text + skippedNote, error: !!errorText });
        logStep(step, label, why, text + skippedNote, errorText ? "err" : "res");
        trail.push({ label: label.replace(/ @ -?\d+,-?\d+$/, ""), ok: !errorText });
        await settle();
      }
      end("Stopped: step limit reached.", "err");
    } catch (e) {
      end(`Error: ${e.message}`, "err");
    } finally {
      running = false; $("run").disabled = false; $("stop").disabled = true;
      // Graded here: the loop ends with `return end(…)`, and only a return in finally reaches the caller with the score.
      const grade = GRADERS[task];
      let pass = null;
      if (!grade && endText.startsWith("Done")) learnSkill(task, trail);
      if (grade && before) {
        try { pass = !!grade(before, win().__SIM__.getState(), endText); } catch { pass = false; }
        if (pass) learnSkill(task, trail);
        logStep("✓", pass ? "CHECK: PASS" : "CHECK: FAIL", "Graded from the phone's state, not the model's claim.", "", pass ? "end" : "err");
      }
      return { pass, skills: !!$("skills")?.checked, steps: Math.max(0, stepCount - 1), seconds: Math.round((Date.now() - started) / 1000), end: endText.slice(0, 200), tokens: { ...tokens } };
    }
  }

  // ---- skills (after Hermes's per-app skills): the path of a passing run, offered on later similar tasks ----
  const SKILLS_KEY = "agentone.skills";
  let skills = (() => { try { return JSON.parse(localStorage.getItem(SKILLS_KEY) || "[]"); } catch { return []; } })();
  const saveSkills = () => { try { localStorage.setItem(SKILLS_KEY, JSON.stringify(skills)); } catch {} };
  const words = (t) => new Set(String(t).toLowerCase().match(/[a-z0-9%]+/g) || []);
  function relevantSkills(task) {
    const w = words(task);
    return skills.map((k) => ({ k, score: [...words(k.task)].filter((x) => w.has(x)).length / Math.max(1, w.size) }))
      .filter((x) => x.score >= 0.5).sort((a, b) => b.score - a.score).slice(0, 2).map((x) => x.k);
  }
  function skillText(task) {
    const found = $("skills")?.checked ? relevantSkills(task) : [];
    if (!found.length) return "";
    return "\n\nSteps that worked before on a similar task. Follow them while the screen matches; adapt if it differs:\n"
      + found.map((k) => `Task: ${k.task}\n` + k.steps.map((x, i) => `  ${i + 1}. ${x}`).join("\n")).join("\n");
  }
  function learnSkill(task, trail) {
    const steps = [];
    for (const t of trail) if (t.ok && steps[steps.length - 1] !== t.label) steps.push(t.label);
    if (!steps.length || steps.length > 20) return;
    const old = skills.find((k) => k.task === task);
    if (old && old.steps.length <= steps.length) return;
    skills = skills.filter((k) => k.task !== task).concat({ task, steps, learned: new Date().toISOString() });
    saveSkills();
  }

  // ---- grading: from the phone's own state, never the model's claim ----
  const appState = (st, id) => (st.apps || {})[id] || {};
  const find = (o, key) => {
    if (o && typeof o === "object") {
      if (!Array.isArray(o) && key in o) return o[key];
      for (const v of Object.values(o)) { const r = find(v, key); if (r !== undefined) return r; }
    }
    return undefined;
  };
  const chatFiles = (st, id) => ((appState(st, "chats").chats || []).find((c) => c.id === id)?.messages || []).filter((m) => m.from === "me" && m.file);
  const lamp = (st) => (appState(st, "lumi").lamps || []).find((l) => l.id === "desk") || {};
  const visits = (st) => Object.fromEntries((appState(st, "visitors").visits || []).map((v) => [v.id, v.status]));
  const gym = (st) => Object.fromEntries((appState(st, "gym").bookings || []).map((b) => [b.id, b.classId]));
  const count = (st, re) => (JSON.stringify(st).match(re) || []).length;
  const GRADERS = {
    "Open the Calculator and work out 128 times 46. Tell me the result.": (b, a, end) => end.startsWith("Done") && end.replace(/,/g, "").includes("5888"),
    "Open Notes, create a new note that says: Buy milk and eggs": (b, a) => JSON.stringify(appState(a, "notes")).includes("Buy milk and eggs") || count(a, /Buy milk and eggs/g) > count(b, /Buy milk and eggs/g),
    "Open the Clock app and add an alarm for 7:30": (b, a) => {
      const re = /"(?:hour|hours)":\s*7\b[^}]*"(?:minute|minutes)":\s*30\b|07:30|"7:30"/g;
      return count(appState(a, "clock"), re) > count(appState(b, "clock"), re);
    },
    "In Messages, reply to the latest message with: Thanks, got it": (b, a) => count(a, /Thanks, got it/g) > count(b, /Thanks, got it/g),
    "Send the PDF I downloaded to my Family group in Chats": (b, a) => chatFiles(a, "family").length === chatFiles(b, "family").length + 1
      && chatFiles(a, "family").some((m) => /\.pdf$/i.test(m.file.name)) && ["flatmates", "office", "priya"].every((c) => !chatFiles(a, c).length),
    "Open my desk lamp's app and set its brightness to 30%": (b, a) => lamp(a).on === true && Math.abs((lamp(a).brightness ?? 0) - 30) <= 3,
    "Check my building's visitor app and approve the delivery person": (b, a) => visits(a).v1 === "approved" && visits(a).v2 === "waiting",
    "Turn off promotional notifications in the Shop app, but keep delivery alerts": (b, a) => {
      const n = appState(a, "shop").notifications || {};
      return ["offers", "priceDrops", "recommendations", "newsletter"].every((k) => n[k] === false) && n.deliveryAlerts === true && n.orderUpdates === true;
    },
    "Reschedule my Yoga Flow class in the gym app to Thursday morning": (b, a) => gym(a).b1 === "yoga-thu-0700",
    "Upload yesterday's receipt screenshot to my company's expense app as a meals claim and submit it": (b, a) => {
      const old = new Set((appState(b, "expenses").claims || []).map((c) => c.id));
      return (appState(a, "expenses").claims || []).some((c) => !old.has(c.id) && c.receiptId === "p1" && Math.abs(Number(c.amount) - 1240) < 1 && c.status === "Submitted" && c.category === "Meals");
    },
  };

  // ---- run every preset task N times, each on a fresh phone; approvals are allowed for these runs ----
  let autoAllow = false;
  async function freshPhone() {
    try { win().localStorage.clear(); win().sessionStorage.clear(); } catch {}
    saveSkills(); // the phone shares this page's storage; keep what was learned
    frame.src = "/?fresh=" + Date.now();
    await sleep(1500);
    const w = await phoneReady();
    w.__SIM__.setState({ os: { settings: { global: { language: "en" } } } }, { deep: true, reload: false });
    await sleep(1500);
  }
  async function runAll(times) {
    const tasks = Object.keys(GRADERS), rows = [];
    window.__results = rows;
    const out = $("results"); out.hidden = false;
    autoAllow = true;
    try {
      for (let r = 1; r <= times; r++) for (const t of tasks) {
        if (stopRequested) break;
        await freshPhone();
        $("log").innerHTML = ""; $("task").value = t;
        const res = await run(t);
        rows.push({ task: t, run: r, ...res });
        const by = {};
        for (const row of rows) { const k = row.task; by[k] = by[k] || { pass: 0, n: 0, steps: 0, secs: 0 }; by[k].n++; by[k].pass += row.pass ? 1 : 0; by[k].steps += row.steps; by[k].secs += row.seconds; }
        out.textContent = Object.entries(by).map(([k, v]) => `${v.pass}/${v.n}  ${(v.steps / v.n).toFixed(1)} steps  ${(v.secs / v.n).toFixed(0)}s  ${k}`).join("\n")
          + `\n\ntotal ${rows.filter((x) => x.pass).length}/${rows.length}`;
      }
    } finally { autoAllow = false; stopRequested = false; }
    status(`<b>All runs finished:</b> ${rows.filter((x) => x.pass).length}/${rows.length} passed.`);
  }

  // ---- wiring ----
  document.querySelectorAll(".chips button").forEach((b) => b.addEventListener("click", () => { $("task").value = b.dataset.t; }));
  $("run").addEventListener("click", () => { const t = $("task").value.trim(); if (t && !running) run(t); });
  $("stop").addEventListener("click", () => { stopRequested = true; stopHooks.forEach((f) => f()); stopHooks = []; status("Stopping after this step…"); });
  $("runall").addEventListener("click", () => { if (!running) runAll(Number($("times").value) || 1); });
  $("home").addEventListener("click", () => { try { win().__OS__.goHome(); } catch {} });

  function fit() {
    const b = $("bezel"), room = window.innerHeight - 40, need = 822;
    b.style.transform = window.innerWidth > 860 && need > room ? `scale(${Math.max(0.55, room / need)})` : "";
  }
  window.addEventListener("resize", fit); fit();

  (async () => {
    try {
      const res = await fetch("/demo/apps.json"); apps = await res.json();
      const w = await phoneReady();
      w.__SIM__.setState({ os: { settings: { global: { language: "en" } } } }, { deep: true, reload: false });
      status("<b>Phone ready.</b> Pick a task and press Run.");
    } catch (e) { status(`<b>${e.message}</b>`); }
  })();
})();
