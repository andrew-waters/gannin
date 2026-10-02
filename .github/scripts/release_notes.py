#!/usr/bin/env python3
"""The release's notes, from the tag's message: its first line is the title,
the rest the notes. Prints them as Markdown (--markdown, for the GitHub
release) or as small HTML (for Sparkle, which shows them in a web view with
no stylesheet): blank-line paragraphs, `- ` bullets, `code` and **bold**.

Usage: release_notes.py [--markdown] < message
"""
import html
import re
import sys


def inline(text: str) -> str:
    text = html.escape(text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)


def to_html(body: str) -> str:
    out, bullets, para = [], [], []

    def flush():
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para.clear()
        if bullets:
            out.append("<ul>" + "".join(f"<li>{inline(b)}</li>" for b in bullets) + "</ul>")
            bullets.clear()

    for line in body.splitlines():
        stripped = line.strip()
        if not stripped:
            flush()
        elif stripped.startswith(("- ", "* ")):
            if para:
                flush()
            bullets.append(stripped[2:])
        elif bullets and line.startswith("  "):
            bullets[-1] += " " + stripped
        else:
            if bullets:
                flush()
            para.append(stripped)
    flush()
    return "\n".join(out)


def main() -> None:
    lines = sys.stdin.read().strip().splitlines()
    body = "\n".join(lines[1:]).strip()
    if "--markdown" in sys.argv:
        print(body)
    else:
        print(to_html(body))


if __name__ == "__main__":
    main()
