#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$project_dir"

# Cron and the tests run these files directly, so each one needs the execute bit.
for program in bin/* install.sh scripts/*.sh; do
    if [[ ! -x "$program" ]]; then
        printf 'verify.sh: %s is not executable; run chmod 0755 on it\n' "$program" >&2
        exit 1
    fi
done

shellcheck -x bin/* install.sh scripts/*.sh test/*.sh

python3 - <<'PY'
from pathlib import Path
import sys

files = [
    p for p in Path(".").rglob("*")
    if p.is_file() and ".git" not in p.parts
]
crlf = [str(p) for p in sorted(files) if b"\r\n" in p.read_bytes()]
if crlf:
    print(f"CRLF line endings found: {', '.join(crlf)}", file=sys.stderr)
    sys.exit(1)

skill_roots = [
    Path(".claude/skills"),
    Path(".agents/skills"),
    Path(".gemini/skills"),
]
expected_skills = ("pr-review", "pr-code-review")
for skill_name in expected_skills:
    trees = []
    for root in skill_roots:
        skill_dir = root / skill_name
        if not skill_dir.is_dir():
            print(f"Missing skill directory: {skill_dir}", file=sys.stderr)
            sys.exit(1)
        entries = {
            str(p.relative_to(skill_dir)): p.read_bytes()
            for p in sorted(skill_dir.rglob("*"))
            if p.is_file()
        }
        if "SKILL.md" not in entries:
            print(f"Missing SKILL.md in {skill_dir}", file=sys.stderr)
            sys.exit(1)
        trees.append(entries)
    if any(tree != trees[0] for tree in trees[1:]):
        print(
            f"Skill copies for {skill_name} under .claude, .agents, and .gemini must match",
            file=sys.stderr,
        )
        sys.exit(1)
PY

for test_script in test/*.sh; do
    bash "$test_script"
done
