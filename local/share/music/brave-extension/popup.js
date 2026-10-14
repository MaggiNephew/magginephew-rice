// Popup: find the song in this tab, then add it to the local library through the
// native helper (~/.local/share/music/brave-host), which runs `music get` in the background.
const HOST = "com.unome.music";
const app = document.getElementById("app");
const params = new URLSearchParams(location.search);   // ?tab=ID lets the popup be tested in a tab
let poll = null;

async function native(msg) {
  try {
    const r = await chrome.runtime.sendNativeMessage(HOST, msg);
    return r || { ok: false, error: "no answer from the helper" };
  } catch (e) {
    return { ok: false, hostMissing: true, error: String(e && e.message || e) };
  }
}

async function currentTab() {
  if (params.get("tab")) return chrome.tabs.get(Number(params.get("tab")));
  const [t] = await chrome.tabs.query({ active: true, currentWindow: true });
  return t;
}

// what the page's own player says is playing (YouTube Music keeps playing while you browse)
async function pageInfo(tabId) {
  try {
    const [r] = await chrome.scripting.executeScript({
      target: { tabId },
      world: "MAIN",
      func: () => {
        const p = document.getElementById("movie_player");
        let vd = null;
        try { vd = p && typeof p.getVideoData === "function" ? p.getVideoData() : null; } catch (e) { vd = null; }
        const md = navigator.mediaSession && navigator.mediaSession.metadata;
        const art = md && md.artwork && md.artwork.length ? md.artwork[md.artwork.length - 1].src : "";
        return {
          vid: (vd && vd.video_id) || "", vtitle: (vd && vd.title) || "", vauthor: (vd && vd.author) || "",
          title: (md && md.title) || "", artist: (md && md.artist) || "", album: (md && md.album) || "", art,
        };
      },
    });
    return (r && r.result) || {};
  } catch (e) {
    return {};
  }
}

function el(tag, attrs = {}, ...kids) {
  const n = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") n.className = v;
    else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
    else n.setAttribute(k, v);
  }
  for (const c of kids) if (c != null) n.append(c);
  return n;
}

function show(...nodes) {
  app.replaceChildren(...nodes);
}

function card(song) {
  const img = el("img", { src: song.art || song.link.thumb, alt: "" });
  if (song.square) img.classList.add("square");
  img.addEventListener("error", () => { if (img.src !== song.link.thumb) img.src = song.link.thumb; });
  return el("div", { class: "card" }, img,
    el("div", { class: "meta" },
      el("div", { class: "title" }, song.title || "Unknown song"),
      song.artist ? el("div", { class: "artist" }, song.artist) : null,
      song.link.fromList ? el("span", { class: "chip" }, "from a playlist — only this song") : null));
}

function progress(pct, indet) {
  return el("div", { class: "progress" + (indet ? " indet" : "") }, el("div", { style: `width:${pct || 0}%` }));
}

async function saveJob(id, job) {
  try { await chrome.storage.session.set({ ["job:" + id]: job }); } catch (e) { /* not important */ }
}
async function loadJob(id) {
  try { return (await chrome.storage.session.get("job:" + id))["job:" + id] || null; } catch (e) { return null; }
}

function renderReady(song) {
  show(card(song),
    el("button", { class: "btn", id: "add", onclick: () => add(song, false) }, "\u{F01DA}  Add to local library"));
}

function renderInLibrary(song, title) {
  show(card(song),
    el("div", { class: "status ok" }, "✓ In your library" + (title ? ": " + title : "")),
    el("div", { class: "row" },
      el("button", { class: "btn", onclick: () => playIt(song) }, "\u{F040A}  Play"),
      el("button", { class: "btn ghost", onclick: () => add(song, true) }, "Download again")));
}

function renderJob(song, st) {
  const done = st.state === "done", failed = st.state === "error";
  const nodes = [card(song)];
  if (!done && !failed) {
    nodes.push(progress(st.pct, !st.pct), el("div", { class: "status" }, st.msg || "working…"),
      el("p", { class: "muted" }, "You can close this — you’ll get a notification when it’s added."));
  } else if (done) {
    nodes.push(el("div", { class: "status ok" }, "✓ Added: " + (st.title || "done")),
      el("div", { class: "row" }, el("button", { class: "btn", onclick: () => playIt(song) }, "\u{F040A}  Play now")));
  } else {
    nodes.push(el("div", { class: "status" }, "Could not add it: " + (st.msg || "unknown error")),
      el("div", { class: "row" }, el("button", { class: "btn ghost", onclick: () => add(song, true) }, "Try again")));
  }
  show(...nodes);
}

function renderHostMissing(err) {
  show(el("div", { class: "empty" },
    el("span", { class: "glyph" }, "\u{F0029}"),
    el("div", {}, "The music helper isn’t set up yet."),
    el("code", {}, "music setup-brave"),
    el("p", { class: "muted" }, "Run that in a terminal, then restart Brave."),
    el("p", { class: "muted", style: "font-size:10px" }, err || "")));
}

function renderNotSong(url) {
  const onPlaylist = /youtube\.com\/playlist/.test(url || "");
  show(el("div", { class: "empty" },
    el("span", { class: "glyph" }, "\u{F075A}"),
    el("div", {}, onPlaylist ? "Open a song from this playlist first" : "Open a song on YouTube or YouTube Music"),
    el("p", { class: "muted" }, onPlaylist
      ? "Only the song you are playing gets added, not the whole playlist."
      : "Then click this button to add it to your local library.")));
}

async function watch(song, job) {
  clearInterval(poll);
  const tick = async () => {
    const st = await native({ cmd: "status", job });
    if (!st.ok) return;
    renderJob(song, st);
    if (st.state === "done" || st.state === "error") {
      clearInterval(poll);
      await saveJob(song.link.id, { job, final: st });
    }
  };
  await tick();
  poll = setInterval(tick, 700);
}

async function add(song, force) {
  const msg = { cmd: "add", url: song.link.url, id: song.link.id, force };
  if (song.hintArtist && song.hintTitle) { msg.artist = song.hintArtist; msg.title = song.hintTitle; }
  show(card(song), progress(0, true), el("div", { class: "status" }, "starting…"));
  const r = await native(msg);
  if (!r.ok) return r.hostMissing ? renderHostMissing(r.error) : renderJob(song, { state: "error", msg: r.error });
  if (r.already) return renderInLibrary(song, r.title);
  await saveJob(song.link.id, { job: r.job });
  watch(song, r.job);
}

async function playIt(song) {
  const r = await native({ cmd: "play", id: song.link.id });
  if (r.ok) window.close();
}

document.getElementById("open").addEventListener("click", async () => {
  const r = await native({ cmd: "open" });
  if (r.ok) window.close();
});

async function main() {
  const tab = await currentTab();
  if (!tab || !tab.url) return renderNotSong("");
  const info = /youtube\.com|youtu\.be/.test(tab.url) ? await pageInfo(tab.id) : {};
  const link = songLink(tab.url, info.vid);
  if (!link) return renderNotSong(tab.url);

  const samePage = info.vid === link.id;
  const song = { link, title: "", artist: "", art: "", square: false };
  if (samePage && info.title) {
    song.title = info.title;
    song.artist = info.artist;
    if (link.music && info.art) { song.art = info.art; song.square = true; }
  } else if (samePage && info.vtitle) {
    song.title = info.vtitle;
    song.artist = info.vauthor;
  } else {
    song.title = (tab.title || "").replace(/\s+-\s+YouTube( Music)?$/, "");
  }
  // YouTube Music's player knows the real artist + title; regular YouTube only knows the channel
  if (link.music && samePage && info.title && info.artist) {
    song.hintTitle = info.title;
    song.hintArtist = info.artist.split(/\s*[•·]\s*/)[0];
    song.artist = song.hintArtist + (info.album ? " · " + info.album : "");
  }
  if (!link.music) song.title = tidy(song.title);

  const saved = await loadJob(link.id);
  if (saved && saved.job && !saved.final) return watch(song, saved.job);

  const r = await native({ cmd: "check", id: link.id });
  if (!r.ok && r.hostMissing) return renderHostMissing(r.error);
  if (r.ok && r.inLibrary) return renderInLibrary(song, r.title);
  if (saved && saved.final && saved.final.state === "error") return renderJob(song, saved.final);
  renderReady(song);
}

main();
