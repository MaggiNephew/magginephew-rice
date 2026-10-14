// shared logic for starting / brb / ending
// Options (as a URL ?query, or data-* on <body>):
//   min=5         starting: count down 5 minutes (from when the source loads)
//   at=20:30      starting: count down to a clock time instead
//   label=...     replace the text in the frame gap (default GENESIS 1:27)
(function () {
  const q = new URLSearchParams(location.search);
  const body = document.body;
  const opt = (k, d) => q.get(k) ?? body.dataset[k] ?? d;
  const mode = body.dataset.mode;
  const sub = document.querySelector(".sub");
  const label = document.querySelector(".frame .label");
  if (label) label.textContent = opt("label", label.textContent);

  const pad = (n) => String(n).padStart(2, "0");
  const fmt = (s) => (s >= 3600 ? Math.floor(s / 3600) + ":" : "") + pad(Math.floor(s / 60) % 60) + ":" + pad(s % 60);

  // clock in the corner
  const clock = document.querySelector("[data-clock]");
  const tickClock = () => { if (clock) { const d = new Date(); clock.textContent = pad(d.getHours()) + ":" + pad(d.getMinutes()); } };

  const t0 = Date.now();
  let end = null;
  if (mode === "starting") {
    const at = opt("at", "");
    const min = parseFloat(opt("min", "5"));
    if (/^\d{1,2}:\d{2}$/.test(at)) {
      const [h, m] = at.split(":").map(Number);
      const d = new Date(); d.setHours(h, m, 0, 0);
      if (d < new Date()) d.setDate(d.getDate() + 1);
      end = d.getTime();
    } else if (min > 0) end = t0 + min * 60000;
  }

  function tick() {
    tickClock();
    if (!sub) return;
    const now = Date.now();
    if (mode === "starting") {
      if (end === null) { sub.textContent = ""; return; }
      const left = Math.max(0, Math.round((end - now) / 1000));
      sub.textContent = left > 0 ? fmt(left) : "any second now";
    } else if (mode === "brb") {
      sub.textContent = "away " + fmt(Math.round((now - t0) / 1000));
    }
  }
  tick();
  setInterval(tick, 250);

  // the bottom line: one solid line, gently moving (a calm version of the bar's music line)
  const cv = document.querySelector("canvas.wave");
  if (cv) {
    const ctx = cv.getContext("2d");
    const dpr = window.devicePixelRatio || 1;
    const size = () => { cv.width = cv.clientWidth * dpr; cv.height = cv.clientHeight * dpr; };
    size(); addEventListener("resize", size);
    const draw = (ms) => {
      const w = cv.width, h = cv.height, mid = h / 2, t = ms / 1000;
      ctx.clearRect(0, 0, w, h);
      ctx.lineWidth = 3 * dpr;
      ctx.lineJoin = "round";
      ctx.strokeStyle = "#5a5a5a";
      ctx.beginPath();
      for (let x = 0; x <= w; x += 4 * dpr) {
        const u = x / w;
        const env = Math.sin(Math.PI * u) ** 2;              // calm at the edges, alive in the middle
        const y = mid + env * h * 0.32 * (
          0.55 * Math.sin(u * 19 + t * 1.3) +
          0.30 * Math.sin(u * 47 - t * 2.1) +
          0.15 * Math.sin(u * 97 + t * 3.7));
        x ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
      }
      ctx.stroke();
      requestAnimationFrame(draw);
    };
    requestAnimationFrame(draw);
  }
})();
