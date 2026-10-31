#!/usr/bin/env python3
"""Conservative raw-byte checks shared by source export, packaging and Pages.

This is a tripwire, not a proof that arbitrary text is public. It does not decrypt,
unpack archives, OCR images, classify confidential prose or recognize every key.
Tests construct fake credentials at runtime; there is no suppression/allow-secret flag.
"""
import argparse
import json
from pathlib import Path, PurePosixPath
import re

RULES = (
    ("API credential", rb"\bsk-(?:proj-|svcacct-|ant-api[0-9]+-)?[A-Za-z0-9_-]{24,}"),
    ("Google credential", rb"\bAIza[A-Za-z0-9_-]{30,}"),
    ("GitHub credential", rb"\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{30,}"),
    ("AWS credential", rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    ("private key", rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"),
    ("personal home path", rb"(?<![A-Za-z0-9_])(?:/(?:Users|home)|Users)/[A-Za-z0-9._-]+\b|(?:^|[\s\"'])~/[A-Za-z][A-Za-z0-9._/-]{2,}"),
    ("Windows home path", rb"[A-Za-z]:\\Users\\[^\\\r\n]+\\"),
    # Azure, ElevenLabs, Fish and many other providers have no reliable token prefix.
    # Match literal assignments/headers, not variable names or interpolated source code.
    ("assigned credential", rb"(?i)[\"']?(?:api[_-]?key|subscription[_-]?key|ocp-apim-subscription-key|xi-api-key|x-goog-api-key|access[_-]?token|client[_-]?secret)[\"']?\s*[:=]\s*[\"']([A-Za-z0-9_./+=-]{20,})[\"']"),
    ("unquoted credential", rb"(?i)\b(?:api[_-]?key|subscription[_-]?key|access[_-]?token|client[_-]?secret)\s*[:=]\s*(?=[A-Za-z0-9_./+=-]*[0-9])[A-Za-z0-9_./+=-]{24,}(?=\s|$)"),
    ("authorization credential", rb"(?i)\b(?:Bearer|Basic) [A-Za-z0-9_./+=-]{24,}"),
    ("private network URL", rb"(?i)https?://(?:[a-z0-9-]+\.)+(?:internal|local|corp)(?=[:/\s\"']|$)"),
)
TRIGGERS = {
    'API credential': (b'sk-',), 'Google credential': (b'aiza',),
    'GitHub credential': (b'ghp_', b'gho_', b'ghu_', b'ghs_', b'ghr_', b'github_pat_'),
    'AWS credential': (b'akia', b'asia'), 'private key': (b'private key',),
    'personal home path': (b'users/', b'/home/', b'~/'), 'Windows home path': (b':\\users\\',),
    'assigned credential': (b'key', b'token', b'secret'),
    'unquoted credential': (b'key', b'token', b'secret'),
    'authorization credential': (b'bearer', b'basic'),
    'private network URL': (b'.internal', b'.local', b'.corp'),
}

def safe_path(name):
    if not isinstance(name, str) or not name or "\\" in name or "\0" in name:
        raise ValueError("Unsafe export path")
    path = PurePosixPath(name)
    if path.is_absolute() or str(path) != name or any(
        part.casefold() in {".", "..", ".git", ".env", "__pycache__"}
        or part.casefold().startswith(".env.") for part in path.parts
    ):
        raise ValueError("Unsafe export path")
    if path.suffix.lower() in {".pem", ".key", ".p12", ".pfx", ".wav", ".pcm"}:
        raise ValueError("Private file type")
    return path

def no_symlinks(path):
    path = Path(path).absolute()
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError("Symlinks are not allowed in release inputs or destination")

def scan(name, data, policy=None):
    safe_path(name)
    lower_data = data.lower()
    # Never print the name if it itself contains a recognized secret/reference.
    for label, pattern in RULES:
        if re.search(pattern, name.encode()):
            raise ValueError("Sensitive filename blocked; name withheld")
        if any(trigger in lower_data for trigger in TRIGGERS[label]) and re.search(pattern, data):
            raise ValueError(f"Blocked {label}; filename and matching content withheld")
    if policy:
        if any(name.casefold() == p.casefold() or name.casefold().startswith(p.casefold().rstrip('/') + '/') for p in policy.get('paths', [])):
            raise ValueError("Private export path; filename withheld")
        for term in policy.get('terms', []):
            if term.casefold().encode() in lower_data or term.casefold() in name.casefold():
                raise ValueError("Private project data; filename and matching content withheld")

def private_policy(root):
    """Private development adds its local denylist; public exports never contain it."""
    path = Path(root) / 'private-paths.json'
    no_symlinks(path)
    return json.loads(path.read_text()) if path.is_file() else None

def scan_tree(root, policy=None):
    root = Path(root); no_symlinks(root)
    if not root.is_dir(): raise ValueError('Release scan requires an existing directory')
    for path in sorted(root.rglob('*')):
        no_symlinks(path)
        if path.is_file():
            scan(path.relative_to(root).as_posix(), path.read_bytes(), policy)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory')
    args = parser.parse_args()
    try:
        scan_tree(args.directory)
        print('Known credential and private-path checks passed; content review is still required.')
    except (OSError, ValueError) as error:
        parser.exit(1, f'Release scan stopped: {error}\n')
