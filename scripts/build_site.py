#!/usr/bin/env python3
"""Build the static public site locally; no network or publishing actions."""
import argparse
import json
from pathlib import Path
import re
from release_safety import scan, private_policy, no_symlinks

ROOT = Path(__file__).resolve().parents[1]
FILES = {
    'site/index.html': 'index.html', 'site/styles.css': 'styles.css',
    'Assets/Brand/Web/homepage-hero.webp': 'assets/homepage-hero.webp',
    'Assets/Brand/Web/screenshot-main.webp': 'assets/screenshot-main.webp',
    'Assets/Brand/Web/screenshot-transcript.webp': 'assets/screenshot-transcript.webp',
    'Assets/Brand/Web/screenshot-compact.webp': 'assets/screenshot-compact.webp',
    'Assets/Brand/Web/favicon-64.png': 'assets/favicon-64.png',
    'Assets/Brand/Web/apple-touch-icon.png': 'assets/apple-touch-icon.png',
    'Assets/Brand/Web/social-card.webp': 'assets/social-card.webp',
    'LICENSE': 'LICENSE.txt',
    'site/fonts/InstrumentSerif-Regular.ttf': 'fonts/InstrumentSerif-Regular.ttf',
    'site/fonts/OFL.txt': 'fonts/OFL.txt',
}

RELEASE_BASE = 'https://github.com/tm-henningnt/babelfin/releases/'

def release_links(metadata):
    """Derive only official, exact-version asset links from reviewed identity."""
    if not isinstance(metadata, dict):
        raise ValueError('Invalid site release metadata')
    version, build = metadata.get('version'), metadata.get('build')
    kind = metadata.get('kind', metadata.get('artifactKind'))
    suffixes = {'local-review': '-local-review', 'unnotarized-app': '-unnotarized',
                'developer-id-notarized-app': ''}
    if (not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version)
            or not isinstance(build, str) or not re.fullmatch(r'[1-9]\d*', build)
            or kind not in suffixes or metadata.get('architecture') != 'arm64'):
        raise ValueError('Invalid site release identity')
    tag = f'v{version}-build{build}'
    if metadata.get('tag', tag) != tag:
        raise ValueError('Site release tag differs from its version')
    stem = f'Babelfin-{version}-build{build}-macOS-arm64{suffixes[kind]}'
    base = RELEASE_BASE + 'download/' + tag + '/'
    return {'dmg': base + stem + '.dmg', 'zip': base + stem + '.zip',
            'checksums': base + 'SHA256SUMS.txt'}

def build(source, destination, release_metadata=None):
    source, destination = Path(source).absolute(), Path(destination).absolute()
    if destination.exists() or any(p.is_symlink() for p in (destination, *destination.parents)):
        raise ValueError('Choose a new output directory without symlink parents')
    if destination == source or destination in source.parents:
        raise ValueError('Output cannot replace source or a source parent')
    policy = private_policy(source)
    if release_metadata is None and (source / 'PUBLIC_RELEASE.json').exists():
        manifest = source / 'PUBLIC_RELEASE.json'; no_symlinks(manifest)
        data = manifest.read_bytes(); scan('PUBLIC_RELEASE.json', data, policy)
        release_metadata = json.loads(data)
    links = release_links(release_metadata) if release_metadata is not None else None
    inputs = []
    for name in FILES:
        path = source / name
        if not path.is_file() or any(p.is_symlink() for p in (path, *path.parents)):
            raise ValueError(f'Missing or unsafe site input: {name}')
        data = path.read_bytes()
        scan(name, data, policy)
        if name == 'site/index.html' and links:
            text = data.decode('utf-8')
            for key in ('zip', 'checksums', 'dmg'):
                marker = RELEASE_BASE + 'latest' + ('' if key == 'dmg' else '#' + key)
                text = text.replace('href="' + marker + '"', 'href="' + links[key] + '"')
            if release_metadata.get('kind', release_metadata.get('artifactKind')) == 'developer-id-notarized-app':
                text, count = re.subn(r'<p class="small" data-release-security>.*?</p>',
                    '<p class="small" data-release-security>Developer ID signed and notarized by Apple. Drag Babelfin to Applications, then open it.</p>',
                    text, flags=re.DOTALL)
                if count != 1:
                    raise ValueError('Site is missing its release security notice')
            data = text.encode('utf-8'); scan(name, data, policy)
        inputs.append((FILES[name], data))
    destination.mkdir(parents=True)
    for target, data in inputs:
        path = destination / target; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    (destination / '.nojekyll').touch()
    return destination
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--output', required=True)
    args = parser.parse_args()
    try: print(build(ROOT, args.output))
    except (OSError, ValueError) as error: parser.exit(1, f'Site build stopped: {error}\n')
