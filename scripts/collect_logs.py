#!/usr/bin/env python3
"""Collects build logs into dist/diagnostics.zip with personal data removed."""
import pathlib, re, sys, zipfile

RULES = [
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", "<private-key>"),
    (r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?<!\.png)", "<email>"),
    (r"\bgh[pousr]_[A-Za-z0-9]{20,}\b|\bgithub_pat_\w{20,}", "<github-token>"),
    (r"(?i)((?:password|passwd|token|secret|authorization)[\"']?\s*[:=]\s*)(\"[^\"]*\"|(?:bearer |basic )?[^\s,;}]+)", r"\1<redacted>"),
    (r"(https?://)[^/\s:@]+(?::[^/\s@]+)?@", r"\1<credentials>@"),
    (r"(/Users/|/home/)[^/\s\"':]+", r"\1<user>"),
]
# A compiler error and the lines that show where it happened.
ERROR = re.compile(r"(\berror\b ?(\[\w+\])?:|❌|BUILD FAILED|ARCHIVE FAILED|Undefined symbols|duplicate symbol|"
                   r"ld: |Traceback|panicked at|fatal:|command not found|No such file)", re.I)

def redact(text):
    for pattern, repl in RULES:
        text = re.sub(pattern, repl, text, flags=re.S if "PRIVATE KEY" in pattern else 0)
    return text

def main(root, code, step):
    root = pathlib.Path(root)
    files = {"full.log": root / "dist/logs/full.log",
             "sidestore-xcodebuild.log": root / "SideStore/build/logs/build.log"}
    texts = {n: redact(p.read_text(errors="replace")) for n, p in files.items() if p.is_file()}
    summary = [f"exit code: {code}", f"last step: {step}"]
    for name, text in texts.items():
        lines = text.splitlines()
        hits = [i for i, line in enumerate(lines) if ERROR.search(line)]
        summary.append(f"\n##### {name}: {len(hits)} suspicious lines")
        shown = -1
        for i in hits[:40]:  # the first errors are usually the cause
            for j in range(max(i - 3, shown + 1), min(i + 9, len(lines))):
                summary.append(f"{j + 1}: {lines[j]}")
                shown = j
        summary.append(f"--- last 80 lines of {name} ---")
        summary += lines[-80:]
    texts["summary.txt"] = "\n".join(summary) + "\n"
    out = root / "dist/diagnostics.zip"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, text in texts.items():
            archive.writestr(name, text)
    (root / "dist/summary.txt").write_text(texts["summary.txt"])
    print(f"Diagnostics: {out}")

if __name__ == "__main__":
    main(*sys.argv[1:4])
