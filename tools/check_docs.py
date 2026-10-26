"""Checks that every link into the docs resolves: docs/<path>.md#<anchor> in source comments and the justfile, and the
links between and within the documents. Run it from the repository root: `just docs-check`."""
import os
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
docs_dir = os.path.join(root, "docs")


def slug(heading):
    s = heading.strip().lower()
    s = re.sub(r"[`*]", "", s)
    s = re.sub(r"[^\w\s-]", "", s)
    return re.sub(r"\s+", "-", s.strip())


anchors = {}  # path relative to docs/, with forward slashes -> set of anchors
for dp, dn, fn in os.walk(docs_dir):
    for name in fn:
        if not name.endswith(".md"):
            continue
        rel = os.path.relpath(os.path.join(dp, name), docs_dir).replace("\\", "/")
        seen, out, in_code = {}, set(), False
        with open(os.path.join(dp, name), encoding="utf-8") as f:
            for line in f:
                if line.startswith("```"):
                    in_code = not in_code
                    continue
                if in_code:
                    continue
                m = re.match(r"^(#{1,6})\s+(.*?)\s*$", line)
                if m:
                    s = slug(m.group(2))
                    n = seen.get(s, 0)
                    seen[s] = n + 1
                    out.add(s if n == 0 else f"{s}-{n}")
        anchors[rel] = out

missing, checked = [], 0

pat = re.compile(r"docs/([A-Za-z0-9_./-]+\.md)(#([A-Za-z0-9_-]+))?")
for d in ["lib", "src", "tools", "samples", "justfile", "README.md"]:
    p = os.path.join(root, d)
    paths = [p] if os.path.isfile(p) else []
    if not paths:
        for dp, dn, fn in os.walk(p):
            dn[:] = [x for x in dn if x not in ("obj", "bin", ".git", "node_modules")]
            paths += [os.path.join(dp, x) for x in fn
                      if x.endswith((".odin", ".cs", ".luau", ".hlsl", ".hlsli", ".md", ".txt", ".settings", ".json", ".cpp", ".h", ".axaml", ".py"))]
    for path in paths:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in pat.finditer(text):
            checked += 1
            file, anchor = m.group(1), m.group(3)
            where = os.path.relpath(path, root)
            if file not in anchors:
                missing.append((where, f"docs/{file}", "missing file"))
            elif anchor and anchor not in anchors[file]:
                missing.append((where, f"docs/{file}#{anchor}", "missing anchor"))

link_pat = re.compile(r"\]\(([^)\s]+)\)")
for rel in anchors:
    text = open(os.path.join(docs_dir, rel), encoding="utf-8").read()
    for m in link_pat.finditer(text):
        target = m.group(1)
        if target.startswith(("http://", "https://", "mailto:")):
            continue
        checked += 1
        if target.startswith("#"):
            file, anchor = rel, target[1:]
        else:
            file, _, anchor = target.partition("#")
            file = os.path.normpath(os.path.join(os.path.dirname(rel), file)).replace("\\", "/")
            if file.startswith(".."):
                if not os.path.exists(os.path.join(docs_dir, file)):
                    missing.append((f"docs/{rel}", target, "missing file"))
                continue
            if file.endswith("/") or os.path.isdir(os.path.join(docs_dir, file)):
                file = file.rstrip("/") + "/README.md"
        if file not in anchors:
            missing.append((f"docs/{rel}", target, "missing file"))
        elif anchor and anchor not in anchors[file]:
            missing.append((f"docs/{rel}", target, "missing anchor"))

print(f"docs: checked {checked} links")
for src, target, why in missing:
    print(f"{src}: {target} ({why})")
sys.exit(1 if missing else 0)
