// Turn any YouTube / YouTube Music address into a link to ONE song.
// Playlist, radio and mix parameters (list=, index=, start_radio=, pp=, si=, t=) are dropped,
// so a song opened from a playlist downloads only that song.
//   songLink("https://www.youtube.com/watch?v=abc123DEF45&list=PL...&index=4")
//     -> { id: "abc123DEF45", url: "https://www.youtube.com/watch?v=abc123DEF45", music: false, fromList: true }
// Returns null for pages that are not a single song (home, search, a playlist overview, ...).
(function (root) {
  const ID = /^[A-Za-z0-9_-]{11}$/;

  function songLink(href, pageVideoId) {
    let u;
    try { u = new URL(href); } catch (e) { return null; }
    const host = u.hostname.replace(/^www\.|^m\./, "");
    const music = host === "music.youtube.com";
    let id = null;

    if (host === "youtu.be") {
      id = u.pathname.slice(1).split("/")[0];
    } else if (host === "youtube.com" || music || host === "youtube-nocookie.com") {
      if (u.pathname === "/watch") id = u.searchParams.get("v");
      else {
        const m = u.pathname.match(/^\/(?:shorts|live|embed|v)\/([A-Za-z0-9_-]{11})/);
        if (m) id = m[1];
      }
    } else {
      return null;
    }
    // YouTube Music keeps playing while you browse, so the address may not be the song:
    // its player knows what is actually playing. (Not on regular YouTube, where the hidden
    // player keeps the last video around after you leave it.)
    if (music && (!id || !ID.test(id)) && pageVideoId && ID.test(pageVideoId)) id = pageVideoId;
    if (!id || !ID.test(id)) return null;

    const fromList = u.searchParams.has("list") || u.searchParams.has("start_radio");
    return {
      id,
      url: (music ? "https://music.youtube.com/watch?v=" : "https://www.youtube.com/watch?v=") + id,
      music,
      fromList,
      thumb: "https://i.ytimg.com/vi/" + id + "/mqdefault.jpg",
    };
  }

  // "Artist - Title (Official Video)" style cleanup for display only (the downloader does its own)
  function tidy(s) {
    return String(s || "")
      .replace(/\s*[\(\[][^\)\]]*\b(official|lyrics?|audio|video|visuali[sz]er|hd|4k|mv)\b[^\)\]]*[\)\]]/gi, "")
      .replace(/\s{2,}/g, " ").trim();
  }

  root.songLink = songLink;
  root.tidy = tidy;
  if (typeof module !== "undefined") module.exports = { songLink, tidy };
})(typeof self !== "undefined" ? self : globalThis);
