"""musiclib -- engine behind the `music` command and the bar's music library.

  player    one background mpv (no window) with an IPC socket. The mpv-mpris
            plugin publishes it on D-Bus as "Music", so the Quickshell bar shows
            title / artist / album / cover like any other player.
  library   every audio file under ~/Music, tags read with mutagen, cached.
  get       yt-dlp download (song name or link) -> identify -> tag -> file away.
  tag       identify any audio file (MusicBrainz, optional AcoustID fingerprint),
            write title / artist / album / year / track / genre + cover art.
"""
import base64, json, os, re, shutil, socket, subprocess, sys, tempfile, time
import unicodedata, urllib.error, urllib.parse, urllib.request

HOME = os.path.expanduser("~")
MUSIC_DIR = os.environ.get("MUSIC_DIR") or os.path.join(HOME, "Music")
INCOMING = os.path.join(MUSIC_DIR, ".incoming")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(HOME, ".cache"), "music")
LIB_CACHE = os.path.join(CACHE_DIR, "library.json")
CONF_FILE = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "music", "config.json")
RUNTIME = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
SOCK = os.path.join(RUNTIME, "music-mpv.sock")
AUDIO_EXT = {".mp3", ".flac", ".opus", ".ogg", ".oga", ".m4a", ".mp4", ".aac", ".wav", ".wma", ".aiff", ".aif", ".ape", ".wv"}
USER_AGENT = "music-cli/1.0 (personal Arch Linux music library)"


def config():
    try:
        with open(CONF_FILE, encoding="utf-8") as f:
            c = json.load(f)
    except (OSError, ValueError):
        c = {}
    c.setdefault("acoustid_key", "")
    return c


# ----------------------------------------------------------------------------
#  player: background mpv over JSON IPC
# ----------------------------------------------------------------------------
class PlayerError(Exception):
    pass


def _connect(timeout=2.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    return s


def player_running():
    try:
        _connect(0.5).close()
        return True
    except OSError:
        return False


def start_player():
    """Start the background player if it is not running. Returns True when ready."""
    if player_running():
        return True
    if not shutil.which("mpv"):
        raise PlayerError("mpv is not installed (sudo pacman -S mpv mpv-mpris)")
    try:
        os.unlink(SOCK)
    except OSError:
        pass
    cmd = ["mpv", "--idle=yes", "--no-video", "--no-terminal", "--force-window=no",
           "--audio-client-name=Music", "--title=Music", "--gapless-audio=yes",
           "--replaygain=track", "--volume=100", "--input-ipc-server=" + SOCK,
           "--msg-level=all=error"] + os.environ.get("MUSIC_MPV_EXTRA", "").split()
    subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(50):
        if player_running():
            return True
        time.sleep(0.1)
    raise PlayerError("the player did not start")


_req = 0


def ipc(*command, start=True):
    """Send one command to mpv and return its `data` (raises PlayerError on failure)."""
    global _req
    if start:
        start_player()
    elif not player_running():
        raise PlayerError("player not running")
    _req += 1
    rid = _req
    try:
        s = _connect()
    except OSError as e:
        raise PlayerError(f"cannot reach the player ({e})")
    try:
        s.sendall((json.dumps({"command": list(command), "request_id": rid}) + "\n").encode())
        buf = b""
        deadline = time.time() + 3
        while time.time() < deadline:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if msg.get("request_id") == rid:
                    if msg.get("error") not in (None, "success"):
                        raise PlayerError(msg["error"])
                    return msg.get("data")
    except socket.timeout:
        pass
    finally:
        s.close()
    raise PlayerError("no reply from the player")


def get_prop(name, default=None):
    try:
        return ipc("get_property", name, start=False)
    except PlayerError:
        return default


def play(paths, index=0):
    """Replace the queue with `paths` and start playing at `index`."""
    paths = [os.path.abspath(p) for p in paths if p]
    if not paths:
        return
    index = max(0, min(index, len(paths) - 1))
    os.makedirs(CACHE_DIR, exist_ok=True)
    m3u = os.path.join(CACHE_DIR, "queue.m3u")
    with open(m3u, "w", encoding="utf-8") as f:
        f.write("\n".join(paths) + "\n")
    ipc("loadlist", m3u, "replace")
    if index:
        ipc("set_property", "playlist-pos", index)
    ipc("set_property", "pause", False)


def enqueue(paths):
    for p in paths:
        ipc("loadfile", os.path.abspath(p), "append-play")


def toggle():
    ipc("cycle", "pause")


def next_track():
    ipc("playlist-next", "weak")


def prev_track():
    if (get_prop("time-pos", 0) or 0) > 4:
        ipc("seek", 0, "absolute")
    else:
        ipc("playlist-prev", "weak")


def seek(sec):
    ipc("seek", sec, "relative")


def volume(delta):
    v = (get_prop("volume", 100) or 100) + delta
    ipc("set_property", "volume", max(0, min(130, v)))


def stop():
    ipc("stop", start=False)


def status():
    """Current state for the UIs (never starts the player)."""
    if not player_running():
        return {"running": False}
    path = get_prop("path")
    return {
        "running": True,
        "path": path,
        "paused": bool(get_prop("pause", True)),
        "pos": get_prop("time-pos", 0) or 0,
        "duration": get_prop("duration", 0) or 0,
        "volume": get_prop("volume", 100) or 100,
        "index": get_prop("playlist-pos", -1),
        "count": get_prop("playlist-count", 0) or 0,
    }


def queue():
    pl = get_prop("playlist", []) or []
    return [{"path": e.get("filename", ""), "current": bool(e.get("current"))} for e in pl]


# ----------------------------------------------------------------------------
#  tags (mutagen)
# ----------------------------------------------------------------------------
def _mutagen():
    try:
        import mutagen  # noqa: F401
        return True
    except ImportError:
        return False


def _first(v):
    if isinstance(v, (list, tuple)):
        return str(v[0]) if v else ""
    return str(v) if v is not None else ""


def read_tags(path):
    """{title, artist, album, albumartist, track, date, genre, duration, cover} (strings / numbers)."""
    out = {"title": "", "artist": "", "album": "", "albumartist": "", "track": 0,
           "date": "", "genre": "", "duration": 0.0, "cover": False}
    if not _mutagen():
        return out
    import mutagen
    try:
        f = mutagen.File(path, easy=True)
    except Exception:
        f = None
    if f is None:
        return out
    if getattr(f, "info", None) is not None:
        out["duration"] = float(getattr(f.info, "length", 0) or 0)
    tags = f.tags or {}
    get = lambda k: _first(tags.get(k)) if hasattr(tags, "get") else ""
    out["title"] = get("title")
    out["artist"] = get("artist")
    out["album"] = get("album")
    out["albumartist"] = get("albumartist")
    out["date"] = get("date")[:4]
    out["genre"] = get("genre")
    m = re.match(r"\s*(\d+)", get("tracknumber"))
    out["track"] = int(m.group(1)) if m else 0
    try:
        raw = mutagen.File(path)
        t = raw.tags
        if t is not None:
            keys = list(t.keys()) if hasattr(t, "keys") else []
            out["cover"] = (any(k.startswith("APIC") for k in keys) or "covr" in keys
                            or "metadata_block_picture" in [k.lower() for k in keys]
                            or bool(getattr(raw, "pictures", None)))
    except Exception:
        pass
    return out


def write_tags(path, meta, cover=None, cover_mime="image/jpeg"):
    """Write meta (title, artist, album, albumartist, date, track, tracktotal, genre, mb ids)
    and an optional front cover into any common audio format."""
    import mutagen
    ext = os.path.splitext(path)[1].lower()
    track = str(meta.get("track") or "")
    if track and meta.get("tracktotal"):
        track_full = f"{track}/{meta['tracktotal']}"
    else:
        track_full = track
    text = {k: str(meta[k]) for k in ("title", "artist", "album", "albumartist", "date", "genre")
            if meta.get(k)}

    if ext == ".mp3":
        from mutagen.id3 import ID3, ID3NoHeaderError, TIT2, TPE1, TALB, TPE2, TDRC, TCON, TRCK, APIC, TXXX, UFID
        try:
            t = ID3(path)
        except ID3NoHeaderError:
            t = ID3()
        frames = {"title": TIT2, "artist": TPE1, "album": TALB, "albumartist": TPE2, "date": TDRC, "genre": TCON}
        for k, cls in frames.items():
            if k in text:
                t.setall(cls.__name__, [cls(encoding=3, text=text[k])])
        if track_full:
            t.setall("TRCK", [TRCK(encoding=3, text=track_full)])
        if meta.get("mb_recording"):
            t.setall("UFID:http://musicbrainz.org", [UFID(owner="http://musicbrainz.org", data=meta["mb_recording"].encode())])
        if meta.get("mb_release"):
            t.add(TXXX(encoding=3, desc="MusicBrainz Album Id", text=meta["mb_release"]))
        if cover:
            t.delall("APIC")
            t.add(APIC(encoding=3, mime=cover_mime, type=3, desc="Cover", data=cover))
        t.save(path, v2_version=3)
        return

    if ext in (".m4a", ".mp4", ".aac", ".alac"):
        from mutagen.mp4 import MP4, MP4Cover
        f = MP4(path)
        if f.tags is None:
            f.add_tags()
        keymap = {"title": "\xa9nam", "artist": "\xa9ART", "album": "\xa9alb", "albumartist": "aART",
                  "date": "\xa9day", "genre": "\xa9gen"}
        for k, mk in keymap.items():
            if k in text:
                f.tags[mk] = [text[k]]
        if track:
            f.tags["trkn"] = [(int(track), int(meta.get("tracktotal") or 0))]
        if meta.get("mb_recording"):
            f.tags["----:com.apple.iTunes:MusicBrainz Track Id"] = [meta["mb_recording"].encode()]
        if cover:
            fmt = MP4Cover.FORMAT_PNG if cover_mime == "image/png" else MP4Cover.FORMAT_JPEG
            f.tags["covr"] = [MP4Cover(cover, imageformat=fmt)]
        f.save()
        return

    # FLAC / Ogg Vorbis / Opus: Vorbis comments (+ picture block)
    f = mutagen.File(path)
    if f is None:
        raise ValueError("unsupported audio file")
    if f.tags is None:
        f.add_tags()
    for k, v in text.items():
        f.tags[k] = [v]
    if track:
        f.tags["tracknumber"] = [track]
        if meta.get("tracktotal"):
            f.tags["tracktotal"] = [str(meta["tracktotal"])]
    if meta.get("mb_recording"):
        f.tags["musicbrainz_trackid"] = [meta["mb_recording"]]
    if meta.get("mb_release"):
        f.tags["musicbrainz_albumid"] = [meta["mb_release"]]
    if cover:
        from mutagen.flac import Picture
        pic = Picture()
        pic.type = 3
        pic.mime = cover_mime
        pic.desc = "Cover"
        pic.data = cover
        dims = _image_size(cover)
        if dims:
            pic.width, pic.height = dims
            pic.depth = 24
        if ext == ".flac":
            f.clear_pictures()
            f.add_picture(pic)
        else:
            f.tags["metadata_block_picture"] = [base64.b64encode(pic.write()).decode("ascii")]
    f.save()


def _image_size(data):
    try:
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
        if data[:2] == b"\xff\xd8":
            i = 2
            while i < len(data) - 9:
                if data[i] != 0xFF:
                    i += 1
                    continue
                marker = data[i + 1]
                if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                    return int.from_bytes(data[i + 7:i + 9], "big"), int.from_bytes(data[i + 5:i + 7], "big")
                i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
    except Exception:
        pass
    return None


# ----------------------------------------------------------------------------
#  library
# ----------------------------------------------------------------------------
def _sort_key(t):
    a = (t["albumartist"] or t["artist"] or "~").lower()
    return (a, (t["album"] or "~").lower(), t["track"] or 999, t["title"].lower())


def scan(force=False):
    """All tracks under MUSIC_DIR (tags cached by mtime), sorted artist / album / track."""
    try:
        with open(LIB_CACHE, encoding="utf-8") as f:
            old = {t["path"]: t for t in json.load(f).get("tracks", [])}
    except (OSError, ValueError):
        old = {}
    tracks = []
    for root, dirs, files in os.walk(MUSIC_DIR):
        # hidden folders and the soundboard's clips (~/Music/Soundboard) are not music
        dirs[:] = [d for d in dirs if not d.startswith(".") and not (root == MUSIC_DIR and d == "Soundboard")]
        for name in files:
            if os.path.splitext(name)[1].lower() not in AUDIO_EXT:
                continue
            p = os.path.join(root, name)
            try:
                mt = os.path.getmtime(p)
            except OSError:
                continue
            c = old.get(p)
            if c and not force and c.get("mtime") == mt:
                tracks.append(c)
                continue
            tg = read_tags(p)
            stem = os.path.splitext(name)[0]
            guess = parse_name(stem)
            tracks.append({
                "path": p, "mtime": mt,
                "title": tg["title"] or guess["title"] or stem,
                "artist": tg["artist"] or guess["artist"] or "Unknown artist",
                "album": tg["album"], "albumartist": tg["albumartist"],
                "track": tg["track"], "date": tg["date"], "genre": tg["genre"],
                "duration": round(tg["duration"], 1), "cover": tg["cover"],
                "tagged": bool(tg["title"] and tg["artist"]),
            })
    tracks.sort(key=_sort_key)
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = LIB_CACHE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"scanned": time.time(), "tracks": tracks}, f, ensure_ascii=False)
    os.replace(tmp, LIB_CACHE)
    return tracks


def search(tracks, query):
    words = query.lower().split()
    if not words:
        return list(tracks)
    out = []
    for t in tracks:
        hay = " ".join([t["title"], t["artist"], t["album"], t["albumartist"], t["genre"]]).lower()
        if all(w in hay for w in words):
            out.append(t)
    return out


# ----------------------------------------------------------------------------
#  identification
# ----------------------------------------------------------------------------
JUNK = re.compile(
    r"[\(\[](?:[^\)\]]*?\b(?:official|lyric|lyrics|audio|video|visuali[sz]er|hd|hq|4k|remaster(?:ed)?|"
    r"explicit|clean|mv|m/v|live|performance|music video|full album|color coded|"
    r"letra|subtitulad[oa]|360)\b[^\)\]]*)[\)\]]", re.I)
FEAT = re.compile(r"\s*[\(\[]?\b(?:feat\.?|ft\.?|featuring|with)\s+[^\)\]]+[\)\]]?", re.I)


def clean_title(s):
    s = JUNK.sub("", s or "")
    s = re.sub(r"\s*\|\s*.*$", "", s)                       # "Title | Something"
    s = re.sub(r"\s*[-–—]\s*(?:topic|official.*)$", "", s, flags=re.I)
    s = re.sub(r'^["“”\']+|["“”\']+$', "", s.strip())
    return re.sub(r"\s{2,}", " ", s).strip(" -–—_")


def parse_name(s):
    """'Artist - Title (Official Video)' -> {artist, title}; works for filenames and video titles."""
    s = re.sub(r"[_]+", " ", s or "")
    s = re.sub(r"^\s*\d{1,3}\s*[.\-_)]\s+", "", s)          # "03 - " / "03. "
    s = clean_title(s)
    for sep in (" - ", " – ", " — ", " ~ ", ": "):
        if sep in s:
            a, t = s.split(sep, 1)
            return {"artist": a.strip(), "title": clean_title(t)}
    return {"artist": "", "title": s.strip()}


def _norm(s):
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    s = FEAT.sub("", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def _sim(a, b):
    """0..1 word-overlap similarity."""
    a, b = set(_norm(a).split()), set(_norm(b).split())
    if not a or not b:
        return 0.0
    return len(a & b) / max(len(a), len(b))


_last_mb = 0.0


def http_get(url, accept="application/json", timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(), r.headers.get("Content-Type", "")


def mb_get(path, **params):
    """MusicBrainz web service (JSON), politely rate limited to 1 request/second."""
    global _last_mb
    wait = 1.05 - (time.time() - _last_mb)
    if wait > 0:
        time.sleep(wait)
    params["fmt"] = "json"
    url = "https://musicbrainz.org/ws/2/" + path + "?" + urllib.parse.urlencode(params)
    for attempt in range(3):
        _last_mb = time.time()
        try:
            data, _ = http_get(url)
            return json.loads(data)
        except urllib.error.HTTPError as e:
            if e.code == 503 and attempt < 2:
                time.sleep(2)
                continue
            raise
    return {}


def _credit(ac):
    return "".join((c.get("name") or c.get("artist", {}).get("name", "")) + (c.get("joinphrase") or "")
                   for c in (ac or [])).strip()


def _lucene(s):
    return re.sub(r'([+\-!(){}\[\]^"~*?:\\/]|&&|\|\|)', r"\\\1", s)


def _release_rank(rel):
    rg = rel.get("release-group") or {}
    ptype = (rg.get("primary-type") or "").lower()
    sec = [x.lower() for x in (rg.get("secondary-types") or [])]
    score = 0
    if rel.get("status", "Official") == "Official":
        score += 4
    score += {"album": 3, "ep": 2, "single": 1}.get(ptype, 0)
    if "compilation" in sec:
        score -= 4
    if "live" in sec or "remix" in sec or "soundtrack" in sec:
        score -= 3
    date = rel.get("date") or "9999"
    return (score, -int((date + "0000")[:4]) if date[:4].isdigit() else -9999)


def best_match(recordings, artist, title, duration):
    """Pick (recording, release, confidence 0..1) from MusicBrainz search results."""
    best = None
    for r in recordings:
        ts = _sim(r.get("title", ""), title)
        if _norm(r.get("title", "")) == _norm(title):
            ts = 1.0
        asim = _sim(_credit(r.get("artist-credit")), artist) if artist else 0.6
        conf = 0.55 * ts + 0.35 * asim + 0.10 * (r.get("score", 0) / 100)
        length = (r.get("length") or 0) / 1000
        if duration and length:
            diff = abs(length - duration)
            conf += 0.1 if diff <= 3 else 0.0 if diff <= 10 else -0.25
        rels = r.get("releases") or []
        rel = max(rels, key=_release_rank) if rels else None
        if best is None or conf > best[2]:
            best = (r, rel, conf)
    return best


def acoustid_lookup(path, key):
    """Audio fingerprint -> (recording id, confidence) or None. Needs fpcalc (chromaprint) + a free API key."""
    if not key or not shutil.which("fpcalc"):
        return None
    try:
        out = subprocess.run(["fpcalc", "-json", path], capture_output=True, text=True, timeout=60).stdout
        fp = json.loads(out)
        q = urllib.parse.urlencode({"client": key, "meta": "recordings", "duration": int(fp["duration"]),
                                    "fingerprint": fp["fingerprint"]})
        data, _ = http_get("https://api.acoustid.org/v2/lookup?" + q)
        res = json.loads(data).get("results") or []
    except Exception:
        return None
    for r in sorted(res, key=lambda x: -x.get("score", 0)):
        recs = r.get("recordings") or []
        if recs and r.get("score", 0) >= 0.7:
            return recs[0]["id"], r["score"]
    return None


def identify(path, hints, log=lambda m: None):
    """hints: {artist, title, album, duration}. Returns (meta dict, cover bytes|None, mime, confidence)."""
    artist, title = hints.get("artist", ""), hints.get("title", "")
    duration = hints.get("duration") or 0
    recs, conf_boost = [], 0.0

    fp = acoustid_lookup(path, config().get("acoustid_key", ""))
    if fp:
        log("matched the audio fingerprint")
        try:
            recs = mb_get("recording", query="rid:" + fp[0], limit=1).get("recordings") or []
            conf_boost = 0.3
            if recs:
                artist = artist or _credit(recs[0].get("artist-credit"))
                title = title or recs[0].get("title", "")
        except Exception as e:
            log(f"MusicBrainz lookup failed ({e})")

    if not recs and title:
        log(f"looking up “{title}”" + (f" by {artist}" if artist else ""))
        q = f'recording:"{_lucene(title)}"'
        if artist:
            q += f' AND artist:"{_lucene(artist)}"'
        try:
            recs = mb_get("recording", query=q, limit=15).get("recordings") or []
            if not recs and artist:      # looser second try
                recs = mb_get("recording", query=f"{_lucene(title)} {_lucene(artist)}", limit=15).get("recordings") or []
        except Exception as e:
            log(f"MusicBrainz lookup failed ({e})")

    meta = {"title": title or hints.get("title", ""), "artist": artist, "album": hints.get("album", ""),
            "albumartist": "", "date": hints.get("date", ""), "genre": "", "track": hints.get("track") or "",
            "tracktotal": ""}
    cover, mime, conf = None, "image/jpeg", 0.0
    if recs:
        r, rel, conf = best_match(recs, artist, title, duration)
        conf = max(0.0, min(1.0, conf + conf_boost))
        if conf >= 0.62:
            meta.update({"title": r.get("title") or meta["title"],
                         "artist": _credit(r.get("artist-credit")) or meta["artist"],
                         "date": (r.get("first-release-date") or "")[:4], "mb_recording": r.get("id", "")})
            tags = sorted(r.get("tags") or [], key=lambda t: -t.get("count", 0))
            if tags:
                meta["genre"] = tags[0]["name"].title()
            if rel:
                meta["album"] = rel.get("title", "")
                meta["albumartist"] = _credit(rel.get("artist-credit")) or meta["artist"]
                meta["mb_release"] = rel.get("id", "")
                meta["date"] = (rel.get("date") or meta["date"])[:4] or meta["date"]
                media = rel.get("media") or []
                if media:
                    tr = (media[0].get("track") or [{}])[0]
                    num = re.match(r"\d+", str(tr.get("number") or tr.get("position") or ""))
                    meta["track"] = num.group(0) if num else ""
                    meta["tracktotal"] = media[0].get("track-count") or ""
                cover, mime = fetch_cover(rel)
            log(f"found: {meta['artist']} — {meta['title']}"
                + (f" ({meta['album']})" if meta["album"] else "") + f"  [{int(conf * 100)}% sure]")
        else:
            log(f"no confident match ({int(conf * 100)}%), keeping the names from the source")
    return meta, cover, mime, conf


def fetch_cover(rel):
    """Front cover from the Cover Art Archive (release, then its release group)."""
    ids = [("release", rel.get("id"))]
    rg = (rel.get("release-group") or {}).get("id")
    if rg:
        ids.append(("release-group", rg))
    for kind, mbid in ids:
        if not mbid:
            continue
        try:
            data, ctype = http_get(f"https://coverartarchive.org/{kind}/{mbid}/front-500", accept="image/*")
            if data:
                return data, ("image/png" if "png" in ctype else "image/jpeg")
        except Exception:
            continue
    return None, "image/jpeg"


def square_jpeg(data):
    """Any image (e.g. a 16:9 webp thumbnail) -> centre-cropped square JPEG via ffmpeg."""
    if not data or not shutil.which("ffmpeg"):
        return None
    with tempfile.TemporaryDirectory() as d:
        src, dst = os.path.join(d, "in"), os.path.join(d, "out.jpg")
        with open(src, "wb") as f:
            f.write(data)
        r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src, "-vf",
                            "crop='min(iw,ih)':'min(iw,ih)',scale=600:600", "-frames:v", "1", "-q:v", "3", dst],
                           capture_output=True)
        if r.returncode == 0 and os.path.exists(dst):
            with open(dst, "rb") as f:
                return f.read()
    return None


# ----------------------------------------------------------------------------
#  filing into the library
# ----------------------------------------------------------------------------
def _safe(s, limit=80):
    s = re.sub(r'[/\\:*?"<>|\x00-\x1f]', "_", s or "").strip(" .")
    return (s or "Unknown")[:limit]


def library_path(meta, ext):
    artist = _safe(meta.get("albumartist") or meta.get("artist") or "Unknown artist")
    album = _safe(meta.get("album") or "Singles")
    num = str(meta.get("track") or "")
    name = (f"{int(num):02d} " if num.isdigit() else "") + _safe(meta.get("title") or "Unknown")
    return os.path.join(MUSIC_DIR, artist, album, name + ext.lower())


def place(src, meta, move):
    dst = library_path(meta, os.path.splitext(src)[1])
    if os.path.abspath(src) == os.path.abspath(dst):
        return dst
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    base, ext = os.path.splitext(dst)
    n = 2
    while os.path.exists(dst):
        dst = f"{base} ({n}){ext}"
        n += 1
    (shutil.move if move else shutil.copy2)(src, dst)
    if move:   # tidy now-empty folders the file came from (inside the library only)
        d = os.path.dirname(os.path.abspath(src))
        while d.startswith(MUSIC_DIR + os.sep) and d != MUSIC_DIR:
            try:
                os.rmdir(d)
            except OSError:
                break
            d = os.path.dirname(d)
    return dst


def tag_file(path, artist="", title="", log=print, keep=False):
    """Identify + tag + file away an existing audio file. Files outside ~/Music are copied in
    (the original is left alone); files already in the library are re-tagged and moved."""
    path = os.path.abspath(path)
    if not os.path.isfile(path):
        raise FileNotFoundError(path)
    cur = read_tags(path)
    guess = parse_name(os.path.splitext(os.path.basename(path))[0])
    hints = {"artist": artist or cur["artist"] or guess["artist"],
             "title": title or cur["title"] or guess["title"],
             "album": cur["album"], "date": cur["date"], "duration": cur["duration"],
             "track": str(cur["track"]) if cur["track"] else ""}
    meta, cover, mime, conf = identify(path, hints, log)
    inside = path.startswith(MUSIC_DIR + os.sep)
    work = path
    if not inside:   # never modify the user's original
        os.makedirs(INCOMING, exist_ok=True)
        work = os.path.join(INCOMING, os.path.basename(path))
        shutil.copy2(path, work)
    write_tags(work, meta, cover, mime)
    dst = work if keep else place(work, meta, move=True)
    log(("tagged" if conf >= 0.62 else "saved (names from the file)") + ": " + dst.replace(HOME, "~"))
    return dst, meta, conf


SOURCES = os.path.join(CACHE_DIR, "sources.json")
JOBS_DIR = os.path.join(CACHE_DIR, "jobs")


def _sources():
    try:
        with open(SOURCES, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def remember_source(video_id, path):
    """Remember which library file came from which video, so the browser button knows."""
    if not video_id:
        return
    s = _sources()
    s[video_id] = path
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = SOURCES + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(s, f, ensure_ascii=False)
    os.replace(tmp, SOURCES)


def source_path(video_id):
    """Library file downloaded from this video id, if it is still there."""
    p = _sources().get(video_id or "")
    return p if p and os.path.isfile(p) else ""


def download(query, log=print, progress=None, hints=None):
    """Song name or link -> best audio via yt-dlp -> identify -> tag -> ~/Music. Returns final paths.
    hints: {"artist", "title"} known from elsewhere (e.g. YouTube Music's player) -- used first."""
    hints = hints or {}
    try:
        import yt_dlp
    except ImportError:
        raise RuntimeError("yt-dlp is not installed (sudo pacman -S yt-dlp)")
    is_url = bool(re.match(r"^[a-z]+://", query.strip(), re.I))
    target = query.strip() if is_url else "ytsearch1:" + query.strip()
    os.makedirs(INCOMING, exist_ok=True)
    tmpdir = tempfile.mkdtemp(prefix="dl-", dir=INCOMING)

    def hook(d):
        if progress and d.get("status") == "downloading":
            tot = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            if tot:
                progress(int(100 * d.get("downloaded_bytes", 0) / tot))

    opts = {
        "format": "bestaudio/best",
        "outtmpl": os.path.join(tmpdir, "%(id)s.%(ext)s"),
        "noplaylist": not ("list=" in query and "watch?" not in query),
        "quiet": True, "no_warnings": True, "noprogress": True,
        "progress_hooks": [hook],
        "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "best"}],
        "writethumbnail": False,
    }
    log(("downloading " + query) if is_url else f"searching for “{query}”")
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(target, download=True)
    entries = info.get("entries") if info.get("_type") == "playlist" or "entries" in info else [info]
    entries = [e for e in (entries or []) if e]
    results = []
    for e in entries:
        files = [os.path.join(tmpdir, f) for f in os.listdir(tmpdir)
                 if f.startswith(e.get("id", "\0") + ".") and os.path.splitext(f)[1].lower() in AUDIO_EXT]
        if not files:
            continue
        f = files[0]
        src_title = e.get("track") or ""
        src_artist = e.get("artist") or e.get("creator") or ""
        if src_artist:
            src_artist = re.split(r",\s*", src_artist)[0]
        guess = parse_name(e.get("title", ""))
        if not src_title:
            src_title = guess["title"]
            src_artist = src_artist or guess["artist"] or re.sub(r"\s*-\s*Topic$|VEVO$", "", e.get("uploader") or "")
        if len(entries) == 1 and hints.get("title"):
            src_title = hints["title"]
            src_artist = hints.get("artist") or src_artist
        log(f"got “{e.get('title', '')}”")
        found = {"artist": src_artist, "title": src_title, "album": e.get("album") or "",
                 "date": str(e.get("release_year") or "")[:4], "duration": e.get("duration") or 0}
        meta, cover, mime, conf = identify(f, found, log)
        if not cover and e.get("thumbnail"):
            try:
                data, _ = http_get(e["thumbnail"], accept="image/*")
                cover, mime = square_jpeg(data), "image/jpeg"
                if cover:
                    log("using the video thumbnail as cover")
            except Exception:
                pass
        write_tags(f, meta, cover, mime)
        dst = place(f, meta, move=True)
        remember_source(e.get("id"), dst)
        log("saved: " + dst.replace(HOME, "~"))
        results.append(dst)
    shutil.rmtree(tmpdir, ignore_errors=True)
    if not results:
        raise RuntimeError("nothing was downloaded")
    scan()
    return results


def fmt_time(sec):
    sec = int(sec or 0)
    h, m, s = sec // 3600, (sec % 3600) // 60, sec % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"
