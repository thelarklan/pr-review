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

skills = [
    Path(".claude/skills/pr-review/SKILL.md"),
    Path(".agents/skills/pr-review/SKILL.md"),
    Path(".gemini/skills/pr-review/SKILL.md"),
]
contents = [p.read_bytes() for p in skills]
if any(c != contents[0] for c in contents[1:]):
    print("Skill copies under .claude, .agents, and .gemini must match", file=sys.stderr)
    sys.exit(1)
PY

for test_script in test/*.sh; do
    bash "$test_script"
done
