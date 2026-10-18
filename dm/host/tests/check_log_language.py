"""Audit every Han-containing literal in native runtime sources."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
ALLOWLIST = Path(__file__).with_name("log_localization_allowlist.json")
PATTERN = r"\p{Han}"
TOKEN = re.compile(r"""//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'""", re.MULTILINE)
REASON = re.compile(
    r'\bHLE_FORCE(?:_BIG)?\s*\(\s*"(?:\\.|[^"\\])*"\s*,\s*("(?:\\.|[^"\\])*")'
)


def main():
    # Search the complete source text first. No logging function, field name,
    # or known Chinese word participates in candidate discovery.
    command = ["rg", "--json", "-n", PATTERN, "dm/host", "dm/gfx", "dm/ios"]
    for extension in ("c", "h", "m", "mm", "inc", "S"):
        command += ["--glob", f"*.{extension}"]
    for directory in ("gen", "Gen", "build", "tests", "third_party"):
        command += ["--glob", f"!**/{directory}/**"]
    command += ["--glob", "!test_*"]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    if result.returncode not in (0, 1):
        sys.stderr.write(result.stderr)
        return 1
    matches = [json.loads(line)["data"] for line in result.stdout.splitlines()
        if json.loads(line)["type"] == "match"]
    allowed = {(row["file"], row["source"].strip()) for row in json.loads(ALLOWLIST.read_text())}
    literals = []
    for filename in sorted({match["path"]["text"] for match in matches}):
        source = (ROOT / filename).read_text()
        reasons = [match.span(1) for match in REASON.finditer(source)]
        for token in TOKEN.finditer(source):
            if not token[0].startswith(('"', "'")) or token[0].isascii():
                continue
            line = source.count("\n", 0, token.start()) + 1
            start = source.rfind("\n", 0, token.start()) + 1
            end = source.find("\n", token.end())
            context = source[start:end if end >= 0 else len(source)].strip()
            category = "unreviewed"
            if any(begin <= token.start() and token.end() <= end for begin, end in reasons):
                # These strings are stored in the import registry, never emitted.
                category = "internal_override_reason"
            elif (filename, context) in allowed:
                category = "reviewed_localization_or_legacy_input"
            literals.append((filename, line, token[0], category))
    # Ask the same Unicode-property regex about all literals. Do not replace
    # this with a list of logging calls or message fragments.
    payload = "".join(f"{index}\t{json.dumps(row[2], ensure_ascii=False)}\n"
        for index, row in enumerate(literals))
    found = subprocess.run(["rg", PATTERN], input=payload, capture_output=True, text=True)
    if found.returncode not in (0, 1):
        sys.stderr.write(found.stderr)
        return 1
    indices = [int(line.split("\t", 1)[0]) for line in found.stdout.splitlines()]
    failures = 0
    for index in indices:
        filename, line, literal, category = literals[index]
        if category == "unreviewed":
            failures += 1
            print(f"{filename}:{line}: unreviewed Han literal: {literal}")
    print(f"Source language audit: pattern={PATTERN} files={len({m['path']['text'] for m in matches})} "
        f"matched_lines={len(matches)} Han_literals={len(indices)} unreviewed={failures}")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
