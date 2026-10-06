// PaloAlly landing page: language, copy buttons, and the three living marks
// (hero, the phone in "A day", and the state legend).
(function () {
  "use strict";

  const $ = (s, r) => (r || document).querySelector(s);
  const $$ = (s, r) => Array.from((r || document).querySelectorAll(s));
  const root = document.documentElement;
  const lang = () => root.getAttribute("data-lang") || "en";
  const reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------------------------------------------------------------- language

  function setLang(l) {
    root.setAttribute("data-lang", l);
    root.lang = l === "zh" ? "zh-CN" : "en";
    try { localStorage.setItem("paloally-lang", l); } catch (e) {}
    labelCanvases();
  }
  $$("[data-lang-toggle]").forEach((b) => b.addEventListener("click", () => setLang(lang() === "zh" ? "en" : "zh")));

  function labelCanvases() {
    const zh = lang() === "zh";
    const hero = $("#hero-drops");
    if (hero) hero.setAttribute("aria-label", zh ? "PaloAlly 的标志：两滴彩色玻璃，大的是它，小的是你" : "The PaloAlly mark: two drops of colored glass, the large one is the assistant, the small one is you");
    const st = $("#states-drops");
    if (st) st.setAttribute("aria-label", zh ? "两滴玻璃演示当前选中的状态" : "The two drops acting out the selected state");
  }
  labelCanvases();

  // ---------------------------------------------------------------- copy

  let onCopy = null;
  $$("[data-copy]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const code = btn.closest("[data-cmd]").querySelector("code").textContent.trim();
      let ok = false;
      try { await navigator.clipboard.writeText(code); ok = true; } catch (e) {
        const ta = document.createElement("textarea");
        ta.value = code; ta.style.position = "fixed"; ta.style.opacity = "0";
        document.body.appendChild(ta); ta.select();
        try { ok = document.execCommand("copy"); } catch (e2) {}
        ta.remove();
      }
      if (!ok) return;
      const zh = btn.querySelector(".zh"), en = btn.querySelector(".en");
      btn.classList.add("done");
      zh.textContent = "已复制"; en.textContent = "Copied";
      clearTimeout(btn._t);
      btn._t = setTimeout(() => { btn.classList.remove("done"); zh.textContent = "复制"; en.textContent = "Copy"; }, 1800);
      if (onCopy) onCopy();
    });
  });

  if (!window.Drops) return;
  const make = (sel, opts) => {
    const c = $(sel);
    if (!c) return null;
    try { return new window.Drops(c, opts); } catch (e) { c.classList.add("drops-fallback"); return null; }
  };
  const rand = (a, b) => a + Math.random() * (b - a);

  // ---------------------------------------------------------------- hero

  // Left alone, it lives: mostly together and breathing, now and then it
  // thinks for a while and comes back, says hello, mulls something over in
  // the background — never on a fixed loop.
  const hero = make("#hero-drops", { maxPixels: 1000, seed: 0x51a7, frameZoom: 0.9 });
  if (hero) {
    const s = hero.state;
    let next = rand(3, 6), scene = null, sceneT = 0, hovering = false;
    const target = { x: 0, y: 0 };
    const scenes = [
      { w: 3, dur: [3.2, 5], on: () => { s.inputs.thinking = true; s.inputs.busyness = rand(0.2, 0.7); }, off: () => { s.inputs.thinking = false; s.send("done"); } },
      { w: 2, dur: [3, 4.2], on: () => { s.inputs.streaming = true; }, tick: () => { if (Math.random() < 0.06) s.send("chunk"); }, off: () => { s.inputs.streaming = false; s.send("done"); } },
      { w: 1.4, dur: [5, 7], on: () => { s.inputs.background = true; }, off: () => { s.inputs.background = false; } },
      { w: 1, dur: [2.4, 2.4], on: () => s.send("appOpen"), off: () => {} },
      { w: 1, dur: [3.2, 4], on: () => { s.inputs.thinking = true; s.inputs.busyness = 0.4; }, off: () => { s.inputs.thinking = false; s.send("deliverable"); } },
    ];
    const pick = () => {
      const tot = scenes.reduce((a, x) => a + x.w, 0);
      let r = Math.random() * tot;
      for (const x of scenes) { if ((r -= x.w) <= 0) return x; }
      return scenes[0];
    };
    hero.onFrame = (dt) => {
      if (!hovering) {
        if (scene) {
          sceneT -= dt;
          if (scene.tick) scene.tick();
          if (sceneT <= 0) { scene.off(); scene = null; next = rand(5, 10); }
        } else if ((next -= dt) <= 0) {
          scene = pick(); scene.on(); sceneT = rand(scene.dur[0], scene.dur[1]);
        }
      }
      s.lean.x += (target.x - s.lean.x) * Math.min(1, dt * 2.5);
      s.lean.y += (target.y - s.lean.y) * Math.min(1, dt * 2.5);
    };
    if (!reduce) {
      window.addEventListener("pointermove", (e) => {
        const r = hero.canvas.getBoundingClientRect();
        const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        target.x = Math.max(-1, Math.min(1, (e.clientX - cx) / (r.width * 0.9)));
        target.y = Math.max(-1, Math.min(1, -(e.clientY - cy) / (r.height * 0.9)));
      }, { passive: true });
      document.addEventListener("pointerleave", () => { target.x = 0; target.y = 0; });
    }
    // the command: hovering it is like typing to it; copying it is like sending
    const cmd = $(".cmd-hero");
    if (cmd) {
      const stopScene = () => { if (scene) { scene.off(); scene = null; next = rand(4, 8); } };
      cmd.addEventListener("pointerenter", () => { hovering = true; stopScene(); s.inputs.typing = true; });
      cmd.addEventListener("pointerleave", () => { hovering = false; s.inputs.typing = false; });
      cmd.addEventListener("pointermove", () => s.send("keystroke"));
    }
    onCopy = () => { s.inputs.typing = false; s.send("send"); setTimeout(() => s.send("done"), 900); };
  }

  // ---------------------------------------------------------------- a day

  const steps = $$(".step");
  const scenesEls = $$(".scene");
  // on narrow screens each step carries its own copy of the moment
  steps.forEach((st) => {
    const sc = scenesEls.find((x) => x.dataset.scene === st.dataset.scene);
    const slot = st.querySelector(".inline-scene");
    if (sc && slot) {
      const c = sc.cloneNode(true);
      c.classList.add("on");
      slot.appendChild(c);
    }
  });

  const phone = make("#phone-drops", { maxPixels: 320, seed: 0x7e11, frameZoom: 1.28 });
  const thread = $(".thread");
  let timers = [];
  let voiceUntil = 0;
  const later = (ms, fn) => timers.push(setTimeout(fn, ms));
  function playScene(name) {
    timers.forEach(clearTimeout); timers = [];
    // one conversation through the day: earlier moments scroll up, later ones wait below
    const idx = scenesEls.findIndex((x) => x.dataset.scene === name);
    let below = 0;
    scenesEls.forEach((x, k) => {
      x.classList.toggle("later", k > idx);
      if (k > idx) below += x.offsetHeight + 22;
    });
    if (thread) thread.style.transform = `translateY(${below}px)`;
    if (!phone) return;
    const s = phone.state, i = s.inputs;
    Object.assign(i, { speaking: false, thinking: false, streaming: false, approval: false, background: false, typing: false });
    switch (name) {
      case "brief": i.background = true; s.send("appOpen"); break;
      case "ask":
        i.speaking = true; voiceUntil = performance.now() + 1800;
        later(1800, () => { i.speaking = false; s.send("send"); });
        later(2300, () => { i.thinking = true; i.busyness = 0.5; });
        break;
      case "approve": i.approval = true; break;
      case "done": s.send("done"); later(1500, () => s.send("deliverable")); break;
      case "wechat": s.send("send"); later(700, () => { i.streaming = true; }); later(2000, () => { i.streaming = false; s.send("done"); }); break;
    }
    phone.refresh();
  }
  if (phone) {
    phone.onFrame = (dt, s) => {
      if (s.inputs.speaking) {
        const t = performance.now() / 1000;
        const env = 0.55 + 0.45 * Math.sin(t * 2.3) * Math.sin(t * 0.9 + 1);
        s.inputs.voiceLevel = Math.max(0, Math.min(1, env * (0.55 + 0.45 * Math.abs(Math.sin(t * 9.1) * Math.sin(t * 5.3)))));
      } else s.inputs.voiceLevel = 0;
    };
  }

  // the step nearest the middle of the screen is the one the phone shows
  let current = null, ticking = false;
  function pickStep() {
    ticking = false;
    let best = null, bestD = Infinity;
    const mid = window.innerHeight * 0.5;
    for (const st of steps) {
      const r = st.getBoundingClientRect();
      const c = r.top + Math.min(r.height, 360) / 2;
      const d = Math.abs(c - mid);
      if (d < bestD) { best = st; bestD = d; }
    }
    if (best && best !== current) {
      current = best;
      steps.forEach((x) => x.classList.toggle("on", x === best));
      playScene(best.dataset.scene);
    }
  }
  window.addEventListener("scroll", () => { if (!ticking) { ticking = true; requestAnimationFrame(pickStep); } }, { passive: true });
  window.addEventListener("resize", pickStep, { passive: true });
  if (steps.length) pickStep();

  // ---------------------------------------------------------------- it and you

  const legend = make("#states-drops", { maxPixels: 900, seed: 0x3c2d, frameZoom: 0.95 });
  const buttons = $$(".states button");
  if (legend && buttons.length) {
    const s = legend.state, i = s.inputs;
    const order = ["idle", "speaking", "thinking", "done", "approval", "deliverable", "quiet", "offline"];
    let active = "idle", lastTouch = -1e9, dwell = 0, inView = false;
    const flags = ["offline", "speaking", "approval", "typing", "streaming", "thinking", "background", "quiet"];
    function show(name) {
      active = name;
      buttons.forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.state === name)));
      const wasOffline = i.offline;
      flags.forEach((f) => { i[f] = false; });
      if (wasOffline && name !== "offline") s.send("reconnect");
      if (name === "done" || name === "deliverable") s.send(name);
      else if (name !== "idle") { i[name] = true; if (name === "thinking") i.busyness = 0.55; }
      dwell = 0;
      legend.refresh();
    }
    buttons.forEach((b) => b.addEventListener("click", () => { lastTouch = performance.now(); show(b.dataset.state); }));
    new IntersectionObserver((es) => { for (const e of es) inView = e.isIntersecting; }, { threshold: 0.35 }).observe($(".drops-sec"));
    legend.onFrame = (dt) => {
      if (i.speaking) {
        const t = performance.now() / 1000;
        const env = 0.55 + 0.45 * Math.sin(t * 2.1) * Math.sin(t * 0.7 + 2);
        i.voiceLevel = Math.max(0, Math.min(1, env * (0.5 + 0.5 * Math.abs(Math.sin(t * 8.7) * Math.sin(t * 4.9)))));
      } else i.voiceLevel = 0;
      // walk through the states by itself until someone picks one
      if (inView && performance.now() - lastTouch > 14000) {
        dwell += dt;
        const hold = active === "done" || active === "deliverable" ? 2.6 : 4.2;
        if (dwell > hold) show(order[(order.indexOf(active) + 1) % order.length]);
      }
    };
    show("idle");
  }

  // ---------------------------------------------------------------- reveal

  const revealables = $$(".section-head, .facts > div, .install-steps li, .route, .note, .drops-copy .body, .states");
  if (!reduce && "IntersectionObserver" in window) {
    revealables.forEach((el) => el.classList.add("reveal"));
    const rio = new IntersectionObserver((es) => {
      for (const e of es) if (e.isIntersecting) { e.target.classList.add("in"); rio.unobserve(e.target); }
    }, { rootMargin: "0px 0px -8% 0px" });
    revealables.forEach((el) => rio.observe(el));
  }
})();
