#!/usr/bin/env python3
"""Verify the exact public source/site and release assets before Pages deployment."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from release_safety import no_symlinks, safe_path, scan

PUBLIC_REPOSITORY = 'tm-henningnt/babelfin'
BUNDLE_ID = 'no.tallmaker.Babelfin'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def canonical(value):
    return json.dumps(value, sort_keys=True, indent=2).encode() + b'\n'

def command(args, cwd=None):
    result = subprocess.run([str(x) for x in args], cwd=cwd, capture_output=True)
    if result.returncode:
        raise ValueError(f'{Path(str(args[0])).name} failed; command output withheld')
    return result.stdout

def file_map(directory, scan_contents=True, ignored=()):
    directory = Path(directory); no_symlinks(directory)
    result = {}
    for path in sorted(directory.rglob('*')):
        relative = path.relative_to(directory)
        if any(relative == Path(name) or Path(name) in relative.parents for name in ignored):
            continue
        no_symlinks(path)
        if path.is_file():
            name = relative.as_posix(); safe_path(name)
            data = path.read_bytes()
            if scan_contents: scan(name, data)
            result[name] = digest(data)
    return result

def verify_files(directory, expected, scan_contents=True, ignored=()):
    if not isinstance(expected, dict) or not expected:
        raise ValueError('Empty or invalid file manifest')
    if file_map(directory, scan_contents, ignored) != expected:
        raise ValueError('Files differ from the reviewed manifest; prepare and approve again')

def validate_identity(value):
    if value.get('repository') != PUBLIC_REPOSITORY or value.get('bundleID') != BUNDLE_ID:
        raise ValueError('Unexpected public repository or application identity')
    version, build = value.get('version', ''), value.get('build', '')
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'\d+', build):
        raise ValueError('Invalid release version or build')
    if value.get('tag') != f'v{version}-build{build}' or value.get('architecture') != 'arm64':
        raise ValueError('Release tag or architecture does not match identity')
    if not re.fullmatch(r'[0-9a-f]{40}', value.get('sourceCommit', '')):
        raise ValueError('A committed source snapshot is required')

def remote_tag(tag):
    response = json.loads(command(['gh', 'api', f'repos/{PUBLIC_REPOSITORY}/git/ref/tags/{tag}']))
    if response['object']['type'] != 'commit':
        raise ValueError('Expected a lightweight release tag pointing directly at the reviewed commit')
    return response['object']['sha']

def verify_remote_assets(manifest, commit, draft, allow_missing=False):
    validate_identity(manifest)
    if not re.fullmatch(r'[0-9a-f]{40}', commit) or remote_tag(manifest['tag']) != commit:
        raise ValueError('Remote tag differs from the reviewed public commit')
    response = json.loads(command(['gh', 'api', f"repos/{PUBLIC_REPOSITORY}/releases/tags/{manifest['tag']}"]))
    if (draft is not None and response['draft'] is not draft) or response['tag_name'] != manifest['tag']:
        raise ValueError('Unexpected remote release state')
    if response.get('prerelease') or response.get('name') != f"Babelfin {manifest['version']}" or digest(response.get('body', '').encode()) != manifest['notesSHA256']:
        raise ValueError('Remote release title or notes differ from approval')
    if response['draft'] is False:
        latest = json.loads(command(['gh', 'api', f'repos/{PUBLIC_REPOSITORY}/releases/latest']))
        if latest.get('tag_name') != manifest['tag']:
            raise ValueError('A different release is latest; deploying this review would roll back the site')
    assets = response['assets']
    names = [asset['name'] for asset in assets]
    if len(set(names)) != len(names) or not set(names).issubset(manifest['artifacts']) or (not allow_missing and set(names) != set(manifest['artifacts'])):
        raise ValueError('Remote release assets differ from the reviewed asset list')
    for asset in assets:
        if not isinstance(asset['id'], int): raise ValueError('Invalid remote asset identity')
        data = command(['gh', 'api', f"repos/{PUBLIC_REPOSITORY}/releases/assets/{asset['id']}", '-H', 'Accept: application/octet-stream'])
        if digest(data) != manifest['artifacts'][asset['name']]:
            raise ValueError('Remote asset digest differs from approval; publication stopped')
    return response

def verify_public(source, site, tag, commit, remote=False):
    source = Path(source)
    manifest = json.loads((source / 'PUBLIC_RELEASE.json').read_text())
    validate_identity(manifest)
    if tag != manifest['tag'] or not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Pages requires the approved release tag and exact commit')
    if command(['git', 'rev-parse', 'HEAD'], source).decode().strip() != commit:
        raise ValueError('Pages checkout is not the approved public commit')
    verify_files(source, manifest['source'], ignored=('.git', '_site', 'PUBLIC_RELEASE.json'))
    verify_files(site, manifest['site'])
    if remote: verify_remote_assets(manifest, commit, draft=False)
    return manifest

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', default='.')
    parser.add_argument('--site', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--verify-remote', action='store_true')
    args = parser.parse_args()
    try:
        verify_public(args.source, args.site, args.tag, args.commit, args.verify_remote)
        print('Approved source, site and release identity verified.')
    except (ValueError, OSError, KeyError) as error:
        parser.exit(1, f'Publication verification stopped: {error}\n')
