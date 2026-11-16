"""Add the missing notices and MPL source directions to the Windows package."""
import os
from pathlib import Path
import re
import sys
import tomllib


def collect(root):
    work = root / 'signing-work'
    payload = root / 'artifacts/ci-payload'
    revision = (work / 'source-commit.txt').read_text().strip()
    repository = os.environ.get('GITHUB_RELEASE_REPOSITORY') or 'wanpulse-sas/provdesk'
    if not re.fullmatch('[0-9a-f]{40}', revision) or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid public source reference')
    packages = tomllib.loads((root / 'Cargo.lock').read_text(encoding='utf-8'))['package']
    source_url = f'https://github.com/{repository}/tree/{revision}'
    parts = [
        'ProVdesk - additional third-party notices\n',
        'Existing notices remain in their original locations:\n'
        'Flutter/Dart and MPL-2.0: data/flutter_assets/NOTICES.Z\n'
        'Amyuni: usbmmidd_v2/License.txt and usbmmidd_v2/idd_instructions.txt\n'
        'WindowInjection: WindowInjection-LICENSE.txt\n'
        'Application license: LICENCE\n',
        'MPL-2.0 component sources\n'
        'The following components remain available under MPL-2.0.\n'
        'The license text is already included in the Flutter notices above.\n'
    ]
    for name in ('option-ext', 'webm', 'webm-sys'):
        for package in (p for p in packages if p['name'] == name):
            source = package['source']
            if source == 'registry+https://github.com/rust-lang/crates.io-index':
                location = f'https://crates.io/api/v1/crates/{name}/{package["version"]}/download'
            elif source.startswith('git+https://github.com/'):
                url, commit = source.removeprefix('git+').rsplit('#', 1)
                location = f'{url.split("?")[0]}/tree/{commit}'
            else:
                raise ValueError(f'Unsupported source location for {name}')
            parts.append(f'{name} {package["version"]}: {location}\n')
    parts.append('For Git sources, clone the linked repository, check out the indicated commit,\n'
                 'then run git submodule update --init --recursive.\n')
    parts.append('FFmpeg uses its GPL-2.0-or-later option under GPL version 3 in this application.\n'
                 'Sources: https://github.com/FFmpeg/FFmpeg/tree/n7.1.1\n'
                 f'Build recipe and patches: {source_url}/res/vcpkg/ffmpeg\n'
                 f'Application build scripts and patches: {source_url}/ci\n')
    for label, relative in (
        ('Tokio - MIT', 'ci/licenses/Tokio-LICENSE.txt'),
        ('Enigo - MIT', 'libs/enigo/LICENSE'),
        ('webpki-roots - CDLA-Permissive-2.0', 'ci/licenses/CDLA-Permissive-2.0.txt'),
        ('FFmpeg - GPL version 3', 'ci/licenses/FFmpeg-COPYING.GPLv3.txt'),
        ('Additional component notices', 'ci/licenses/THIRD-PARTY-NOTICES.txt'),
        ('Flutter engine corresponding sources', 'ci/licenses/FLUTTER-ENGINE-SOURCE.txt'),
    ):
        parts.append(f'\n===== {label} =====\n\n' + (root / relative).read_text(encoding='utf-8'))
    content = '\n'.join(parts)
    for directory in (work, payload):
        (directory / 'THIRD-PARTY.txt').write_text(content, encoding='utf-8')
    print('Added missing third-party notices and MPL source directions.')


if __name__ == '__main__':
    collect(Path(sys.argv[1]).resolve())
