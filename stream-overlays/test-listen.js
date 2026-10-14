// Lets the `stream-test` command poke the overlays while OBS is running.
// stream-test writes test-trigger.js in this folder; every overlay that includes this file
// re-reads it once a second and calls window.onStreamTest({type, name, ...}) for each new one.
(function () {
  let last = null;
  function check() {
    const s = document.createElement("script");
    s.src = "test-trigger.js?" + Date.now();          // no caching
    s.onload = s.onerror = () => {
      s.remove();
      const t = window.__STREAM_TEST;
      if (last === null) { last = t ? t.id : "none"; return; }   // ignore whatever was there before we loaded
      if (t && t.id !== last) {
        last = t.id;
        if (typeof window.onStreamTest === "function") window.onStreamTest(t);
      }
    };
    document.head.appendChild(s);
  }
  check();
  setInterval(check, 1000);
})();
