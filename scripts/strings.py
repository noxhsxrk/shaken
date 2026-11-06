#!/usr/bin/env python3
"""Keeps Resources/Localizable.xcstrings in sync with the L("…") keys in the code.

  scripts/strings.py            # report keys missing a Thai translation (exit 1 if any)
  scripts/strings.py --import f # merge a {english: thai} python dict file into the catalog
"""
import glob, json, os, re, sys

ROOT = os.path.join(os.path.dirname(__file__), "..")
CATALOG = os.path.join(ROOT, "Resources", "Localizable.xcstrings")

def code_keys():
    keys = set()
    for f in glob.glob(os.path.join(ROOT, "Sources", "**", "*.swift"), recursive=True):
        s = open(f, encoding="utf-8").read()
        keys.update(m.group(1) for m in re.finditer(r'\bL\("((?:[^"\\]|\\.)*)"', s))
    reg = open(os.path.join(ROOT, "Sources", "ShakenCore", "ActionRegistry.swift"), encoding="utf-8").read()
    keys.update(re.findall(r'name = "([^"]+)"', reg))
    return keys

def load():
    if os.path.exists(CATALOG):
        return json.load(open(CATALOG, encoding="utf-8"))
    return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}

def save(cat):
    cat["strings"] = dict(sorted(cat["strings"].items()))
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(cat, f, ensure_ascii=False, indent=2)
        f.write("\n")

def main():
    cat = load()
    keys = code_keys()
    if len(sys.argv) == 3 and sys.argv[1] == "--import":
        ns = {}
        exec(open(sys.argv[2], encoding="utf-8").read(), ns)
        for en, th in ns["TH"].items():
            cat["strings"].setdefault(en, {})["localizations"] = {
                "th": {"stringUnit": {"state": "translated", "value": th}}
            }
    # Drop keys that are no longer used, add new ones.
    cat["strings"] = {k: v for k, v in cat["strings"].items() if k in keys}
    for k in keys:
        cat["strings"].setdefault(k, {})
    save(cat)
    missing = sorted(k for k in keys if "th" not in cat["strings"][k].get("localizations", {}))
    for k in missing:
        print("missing th:", k)
    print(f"{len(keys)} keys, {len(missing)} missing Thai")
    sys.exit(1 if missing else 0)

main()
