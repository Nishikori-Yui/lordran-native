#!/usr/bin/env python3
"""Prepare a local, sanitized issue draft from an exported report or build log."""
import argparse
import html
import json
import re
from datetime import datetime, timezone
from pathlib import Path

from player_support_common import REPO, private_path, profile, print_json

MAX_BYTES = 32 * 1024 * 1024
SLOT = re.compile(r"<!-- player-support:([a-z_]+) -->(.*?)<!-- /player-support:\1 -->", re.S)
INLINE = re.compile(r"<!-- player-support:([a-z_]+) -->")
UNKNOWN = "待补充"


def sanitize(text):
    """Redact common identifiers and credentials before selecting any excerpts."""
    text = re.sub(r"-----BEGIN [^\r\n]*PRIVATE KEY-----.*?(?:-----END [^\r\n]*PRIVATE KEY-----|$)",
                  "<redacted-private-key>", text, flags=re.S)
    text = re.sub(
        r'(?im)^(\s*"?(?:[\w.-]*(?:password|passwd|token|secret|api_key|private_key|'
        r'header_key|master_key|titlekek|key_area_key|team_id|device_id|udid)[\w.-]*)"?\s*[:=]\s*).*$',
        r"\1<redacted>", text)
    text = re.sub(
        r'''(?ix)(\b[\w.-]*(?:password|passwd|token|secret|api_key|private_key|header_key|
        master_key|titlekek|key_area_key|team_id|device_id|udid)[\w.-]*["']?\s*[:=]\s*)
        (?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;]+)''', r"\1<redacted>", text)
    text = re.sub(r"(?m)^(\s*[\w.-]+\s*=\s*)[0-9a-fA-F]{32,}\s*$",
                  r"\1<redacted>", text)
    text = re.sub(r"(?i)\bBearer\s+\S+", "Bearer <redacted>", text)
    text = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "<email>", text)
    text = re.sub(r'(["\'])(?:/[^\r\n"\']*|[A-Za-z]:[\\/][^\r\n"\']*)\1',
                  '"<path>"', text)
    text = re.sub(r"(?i)\b[A-Z]:[\\/](?:[^\s\"'<>]|\\ )+", "<path>", text)
    text = re.sub(r"(?<![\w/])/(?:Users|home|private|var|Volumes|mnt|tmp)/[^\s\"'<>]+",
                  "<path>", text)
    text = re.sub(r"\b[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\b",
                  "<uuid>", text)
    text = re.sub(r"\b(?:[0-9a-fA-F]{8}-[0-9a-fA-F]{16}|[0-9a-fA-F]{40})\b",
                  "<device-id>", text)
    text = re.sub(r"\b[\w.-]+@(?=\d+\.\d+\.)", "<user>@", text)
    text = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<ip>", text)
    text = re.sub(r"(?i)\b(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b", "<mac-address>", text)
    import ipaddress
    def ipv6(match):
        try:
            ipaddress.IPv6Address(match[0].split("%")[0])
            return "<ip>"
        except ValueError:
            return match[0]
    text = re.sub(r"(?<!\w)(?:[0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F:.%]+", ipv6, text)
    return text


def read_report(path):
    path = Path(path)
    if path.stat().st_size > MAX_BYTES:
        raise ValueError("Report exceeds 32 MiB; provide an exported diagnostic report or a smaller selected build log")
    text = path.read_text(encoding="utf-8-sig", errors="replace")
    metadata, end = {}, 0
    start = text.find("{")
    if 0 <= start < 256:
        try:
            value, length = json.JSONDecoder().raw_decode(text[start:])
            if isinstance(value, dict):
                metadata, end = value, start + length
        except json.JSONDecodeError:
            pass
    text = sanitize(text[end:])
    parts = re.split(r"(?m)^===== ([^\r\n]+) =====\s*$", text)
    sections = [(parts[i], parts[i + 1]) for i in range(1, len(parts) - 1, 2)]
    if not sections:
        sections = [("provided log", text)]
    return metadata, sections


def evidence(sections, limit=60):
    chosen, observations = [], []
    budget = 18000 // max(1, min(len(sections), 8))
    for name, content in sections[:8]:
        lines = content.splitlines()
        errors = [i for i, line in enumerate(lines) if re.search(
            r"\[(?:ERROR|FATAL)\]|\b(?:fatal error|Traceback|Build failed|CRASH|EXC_BAD_ACCESS)\b",
            line, re.I)]
        metrics = [i for i, line in enumerate(lines) if any(term in line for term in (
            "Timing through frame", "Memory through frame", "[long-frame]",
            "Session started", "Translation details through frame"))]
        indices = set()
        # Preserve both initial errors and the end of a session; one repeated error
        # must not consume the whole report or hide a later failure.
        for i in errors[:5] + errors[-5:] + metrics[-8:] + list(range(max(0, len(lines) - 5), len(lines))):
            indices.update(range(max(0, i - 1), min(len(lines), i + 2)))
        selected = [lines[i][:800] for i in sorted(indices)][:limit]
        if selected:
            text = "\n".join(selected)
            if len(text) > budget:
                text = text[:budget // 2] + "\n[excerpt shortened]\n" + text[-budget // 2:]
            chosen.append(f"===== {name} (selected, sanitized) =====\n" + text)
        observations.append(f"- {plain(name)}: {len(errors)} 条错误/致命候选记录（可能包含重复输出），共 {len(lines)} 行。")
    if len(sections) > 8:
        observations.append("- 仅提取前 8 个日志分段，请按需要查看原始报告中的其他分段。")
    return "\n\n".join(chosen), "\n".join(observations)


def plain(value):
    value = sanitize(str(value)).replace("\r", " ").replace("\n", " ")
    value = re.sub(r"([\\`\[\]()])", r"\\\1", value)
    return html.escape(value, quote=False)


def fenced(text):
    length = max([2] + [len(x) for x in re.findall(r"`+", text)]) + 1
    fence = "`" * length
    return f"{fence}text\n{text}\n{fence}"


def related_issues(path, symptom):
    if not path or not symptom:
        return UNKNOWN
    if Path(path).stat().st_size > 2 * 1024 * 1024:
        raise ValueError("Issue snapshot exceeds 2 MiB")
    rows = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if not isinstance(rows, list):
        raise ValueError("Issue snapshot must be a JSON list from gh issue list")
    def terms(text):
        english = set(re.findall(r"[a-z][a-z0-9_-]{2,}", text.lower()))
        chinese = re.findall(r"[\u4e00-\u9fff]+", text)
        return english | {word[i:i + 2] for word in chinese for i in range(len(word) - 1)}
    wanted = terms(symptom)
    found = []
    for row in rows[:500]:
        if not isinstance(row, dict) or type(row.get("number")) is not int or row["number"] <= 0:
            continue
        title = str(row.get("title", ""))
        score = len(wanted & terms(title))
        if score >= 2:
            found.append((score, row["number"], title))
    return "\n".join(f"- #{number}: {plain(title)}（候选关联，未确认重复）"
                     for _, number, title in sorted(found, reverse=True)[:5]) or "未发现标题匹配；不代表不存在重复 issue。"


def render(template, fields):
    if template.startswith("---\n"):
        template = template.split("---", 2)[2].lstrip()
    def replace(match):
        return fields.get(match[1], match[2].strip())
    text = SLOT.sub(replace, template)
    text = INLINE.sub(lambda match: fields.get(match[1], UNKNOWN), text)
    return re.sub(r"<!--.*?-->", "", text, flags=re.S).strip() + "\n"


def prepare(path, *, kind="bug", symptom="", steps=(), expected="", actual="",
            build="", game_version="", frequency="", issues_json=None, out_dir=None):
    metadata, sections = read_report(path)
    excerpt, observations = evidence(sections)
    fields = {key: UNKNOWN for key in (
        "device", "os", "build", "game_version", "install", "controller", "time",
        "frequency", "last_good", "restart", "target_fps", "actual_fps", "duration",
        "settings", "thermal", "memory", "comparison")}
    for key, source in (("device", "device_model"), ("os", "os"), ("time", "exported_at")):
        if source in metadata:
            fields[key] = plain(metadata[source])
    # A verified Git SHA and an older device UDID can both be 40 hex digits.
    fields["build"] = (build.lower() if re.fullmatch(r"[0-9a-fA-F]{7,40}", build)
                       else plain(build)) if build else "源码 commit 未由本报告确认"
    if metadata.get("app_version") or metadata.get("app_build"):
        fields["build"] += f"；App {plain(metadata.get('app_version', UNKNOWN))} / build {plain(metadata.get('app_build', UNKNOWN))}"
    fields["game_version"] = plain(game_version) if game_version else UNKNOWN
    fields["frequency"] = plain(frequency) if frequency else UNKNOWN
    perf = metadata.get("performance")
    if isinstance(perf, dict):
        values = [f"{key}={plain(perf[key])}" for key in
                  ("game_fps", "display_fps", "frame_ms", "gpu_ms") if key in perf]
        if values:
            fields["actual_fps"] = "导出瞬间的快照（不是整个运行阶段的平均值）：" + ", ".join(values)
        if "width" in perf and "height" in perf:
            fields["settings"] = f"导出瞬间 {plain(perf['width'])}x{plain(perf['height'])}；MSAA 待补充"
    if "thermal_state" in metadata:
        fields["thermal"] = f"导出瞬间 thermal_state={plain(metadata['thermal_state'])}；不代表出错当时"
    if isinstance(metadata.get("app_memory_bytes"), (int, float)):
        fields["memory"] = f"导出瞬间驻留内存约 {metadata['app_memory_bytes'] / 2**20:.1f} MiB"
    fields.update(
        guidance="",
        summary=plain(symptom) if symptom else "请补充遇到的具体异常表现。",
        steps="\n".join(f"{i}. {plain(step)}" for i, step in enumerate(steps, 1)) or "1. 待补充触发问题的操作步骤。",
        expected=plain(expected) if expected else UNKNOWN,
        actual=plain(actual or symptom) if (actual or symptom) else UNKNOWN,
        logs=fenced(excerpt or "没有提取到日志正文，请补充报告。"),
        observed=observations,
        suspected="尚未确认根因；错误记录或日志突然结束本身不足以确定系统终止原因。",
        missing="请核对复现步骤、实际构建、安装方式和复现频率；待补充项不可视为已经验证。",
        related=related_issues(issues_json, symptom),
    )
    filename = "performance_compatibility.md" if kind == "performance" else "bug_report.md"
    template = (REPO / ".github/ISSUE_TEMPLATE" / filename).read_text(encoding="utf-8")
    if not SLOT.search(template):
        raise ValueError("Current issue template has no player-support fields")
    draft = render(template, fields)
    title = ("perf: " if kind == "performance" else "bug: ") + plain(symptom or "待补充问题标题")[:150]
    draft = f"建议标题：{title}\n\n{draft}"
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    output = private_path(out_dir or REPO / "game" / profile().id / "support")
    output.mkdir(parents=True, exist_ok=True)
    files = {}
    for name, contents in (("issue-draft", draft), ("diagnostics-excerpt", excerpt + "\n")):
        target = output / f"{name}-{stamp}.{'md' if name == 'issue-draft' else 'txt'}"
        with target.open("x", encoding="utf-8", newline="\n") as stream:
            stream.write(contents)
        target.chmod(0o600)
        files[name] = str(target)
    return dict(status="draft-created", files=files,
                review_required="Check redactions, fill missing facts and preview before pasting. Nothing was submitted.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--kind", choices=("bug", "performance"), default="bug")
    parser.add_argument("--symptom", default="")
    parser.add_argument("--step", action="append", default=[])
    parser.add_argument("--expected", default="")
    parser.add_argument("--actual", default="")
    parser.add_argument("--build", default="", help="Only give a source revision you have independently verified")
    parser.add_argument("--game-version", default="")
    parser.add_argument("--frequency", default="")
    parser.add_argument("--issues-json", type=Path, help="Optional local gh issue list JSON; no network or login is required")
    parser.add_argument("--out-dir", type=Path, help="Private output directory under game/")
    args = parser.parse_args(argv)
    try:
        result = prepare(args.log, kind=args.kind, symptom=args.symptom, steps=args.step,
                         expected=args.expected, actual=args.actual, build=args.build,
                         game_version=args.game_version, frequency=args.frequency,
                         issues_json=args.issues_json, out_dir=args.out_dir)
    except (OSError, ValueError, TypeError) as error:
        parser.exit(1, f"Issue draft failed: {sanitize(str(error))}\n")
    print_json(result)


if __name__ == "__main__":
    main()
