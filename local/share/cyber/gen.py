#!/usr/bin/env python3
"""Build tools.json: every installed package in a blackarch-* pacman group.

pacman is the source of truth (installed set, categories, full descriptions,
URLs, binaries, man pages). GitHub star counts are merged in from the
~/BlackArch-tools/*.txt lists when a tool appears there.
`cyber` reruns this automatically whenever the pacman database changes.
"""
import glob, json, os, re, subprocess, time

HERE = os.path.dirname(os.path.realpath(__file__))
OUT = os.path.join(HERE, "tools.json")
BA_DIR = os.path.expanduser("~/BlackArch-tools")
PACMAN_DB = "/var/lib/pacman/local"

# "   1. [  28,159]  trufflehog  -  desc...  (url)"
DATA_DIR_RE = re.compile(r"^((?:/usr/share|/opt)/([^/]+))/")
SKIP_SHARE = {"doc", "licenses", "man", "info", "applications", "icons", "pixmaps",
              "bash-completion", "zsh", "fish", "locale", "metainfo", "mime", "dbus-1"}
LINE_RE = re.compile(r"^\s*\d+\.\s+\[\s*([\d,]+|n/a)\s*\]\s+(\S+)")


def pacman(*args):
    return subprocess.run(["pacman", *args], capture_output=True, text=True).stdout


def load_stars():
    """name -> GitHub stars, from the category lists (full lists first, then top lists)."""
    stars = {}
    files = glob.glob(os.path.join(BA_DIR, "_FULL_CATEGORIES", "*.txt")) + glob.glob(os.path.join(BA_DIR, "*.txt"))
    for fp in files:
        with open(fp, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = LINE_RE.match(line)
                if m and m.group(1) != "n/a":
                    stars[m.group(2)] = int(m.group(1).replace(",", ""))
    stars.setdefault("rtl-433", stars.get("rtl", 0))   # listed as "rtl" in the txt files
    return stars


def parse_qi(text):
    """pacman -Qi output -> {name: {field: value}}; handles wrapped continuation lines."""
    pkgs, cur, key = {}, {}, None
    for line in text.splitlines():
        if not line.strip():
            if cur.get("Name"):
                pkgs[cur["Name"]] = cur
            cur, key = {}, None
            continue
        if line[:1] != " " and " : " in line:
            key, val = line.split(" : ", 1)
            key = key.strip()
            cur[key] = val.strip()
        elif key:
            cur[key] += " " + line.strip()
    if cur.get("Name"):
        pkgs[cur["Name"]] = cur
    return pkgs


def build():
    # installed package -> its blackarch categories
    cats = {}
    for line in pacman("-Qg").splitlines():
        group, _, pkg = line.partition(" ")
        if group.startswith("blackarch-"):
            cats.setdefault(pkg, []).append(group[len("blackarch-"):])
    names = sorted(cats)

    info, bins, mans, dirs = {}, {}, {}, {}
    for i in range(0, len(names), 100):
        chunk = names[i:i + 100]
        info.update(parse_qi(pacman("-Qi", *chunk)))
        for line in pacman("-Ql", *chunk).splitlines():
            pkg, _, path = line.partition(" ")
            if path.startswith("/usr/bin/") and not path.endswith("/"):
                bins.setdefault(pkg, set()).add(os.path.basename(path))
            elif path.startswith("/usr/share/man/man") and not path.endswith("/"):
                page = os.path.basename(path).split(".")[0]
                mans.setdefault(pkg, set()).add(page)
            else:
                # where data-only packages (wordlists, templates, …) keep their files
                m = DATA_DIR_RE.match(path)
                if m and m.group(2) not in SKIP_SHARE:
                    dirs.setdefault(pkg, set()).add(m.group(1))

    stars = load_stars()
    tools = []
    for name in names:
        qi = info.get(name, {})
        b = bins.get(name, set())
        # main command first: exact package name, then ones that start with it, then the rest
        order = sorted(b, key=lambda x: (x != name, not x.startswith(name.split("-")[0]), x.lower()))
        url = qi.get("URL", "")
        tools.append({
            "name": name,
            "version": qi.get("Version", ""),
            "desc": qi.get("Description", ""),
            "url": "" if url == "None" else url,
            "cats": sorted(cats[name]),
            "stars": stars.get(name, 0),
            "explicit": qi.get("Install Reason", "").startswith("Explicitly"),
            "bins": order,
            "man": sorted(mans.get(name, set())),
            "paths": [] if b else sorted(dirs.get(name, set()))[:3],
        })

    data = {"generated": time.time(), "tools": tools}
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=0)
    os.replace(tmp, OUT)
    return data


def is_stale():
    try:
        return os.path.getmtime(PACMAN_DB) > os.path.getmtime(OUT)
    except OSError:
        return True


if __name__ == "__main__":
    d = build()
    t = d["tools"]
    print(f"wrote {len(t)} tools to {OUT}")
    print(f"  {sum(1 for x in t if x['stars'])} with star counts, "
          f"{sum(1 for x in t if not x['bins'])} without a command, "
          f"{sum(1 for x in t if not x['explicit'])} installed as dependencies")
