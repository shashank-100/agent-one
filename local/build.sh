#!/bin/sh
# Assembles ./public: the English phone at / and the agent page at /demo/.
set -e
cd "$(dirname "$0")"
rm -rf public
mkdir -p public
cp -R ../phone/dist/. public/
cp -R site/. public/
echo "public: $(find public -type f | wc -l | tr -d ' ') files, $(du -sh public | cut -f1)"
# App names the agent may say → simulator app ids, from each manifest.
python3 - <<'PY'
import json, re, pathlib
names = {}
root = pathlib.Path("../phone")
for m in list(root.glob("apps/*/manifest.ts")) + list(root.glob("system/*/manifest.ts")):
    t = m.read_text(encoding="utf-8")
    i = re.search(r"\bid:\s*['\"]([^'\"]+)['\"]", t)
    if not i: continue
    app = i.group(1); names[app.lower()] = app
    e = re.search(r"displayNameEn:\s*['\"]([^'\"]+)['\"]", t)
    if e: names[e.group(1).lower()] = app
    a = re.search(r"aliases:\s*\[([^\]]*)\]", t)
    if a:
        for alias in re.findall(r"['\"]([^'\"]+)['\"]", a.group(1)):
            if alias.isascii(): names[alias.lower()] = app
pathlib.Path("public/demo/apps.json").write_text(json.dumps(names, indent=1, sort_keys=True))
print("apps.json:", len(set(names.values())), "apps")
PY
