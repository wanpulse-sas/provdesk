import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('collect_legal', Path(__file__).parents[1] / 'Collect-Legal.py')
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class LegalDeliveryTests(unittest.TestCase):
    def test_only_missing_notices_and_mpl_source_directions_are_added(self):
        repository = Path(__file__).parents[2]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            work = root / 'signing-work'
            payload = root / 'artifacts/ci-payload'
            work.mkdir()
            payload.mkdir(parents=True)
            (work / 'source-commit.txt').write_text('a' * 40)
            originals = {
                'data/flutter_assets/NOTICES.Z': b'existing Flutter and MPL notices',
                'usbmmidd_v2/License.txt': b'existing Amyuni license',
                'WindowInjection-LICENSE.txt': b'existing WindowInjection license',
            }
            for name, data in originals.items():
                target = payload / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            license_files = ('ci/licenses/Tokio-LICENSE.txt', 'libs/enigo/LICENSE',
                             'ci/licenses/CDLA-Permissive-2.0.txt', 'ci/licenses/FFmpeg-COPYING.GPLv3.txt',
                             'ci/licenses/THIRD-PARTY-NOTICES.txt', 'ci/licenses/FLUTTER-ENGINE-SOURCE.txt')
            for name in ('Cargo.lock', *license_files):
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(repository / name, target)
            collector.collect(root)
            text = (payload / 'THIRD-PARTY.txt').read_text(encoding='utf-8')
            for name in license_files:
                self.assertEqual(text.count((root / name).read_text(encoding='utf-8')), 1)
            for name, data in originals.items():
                self.assertEqual((payload / name).read_bytes(), data)
                self.assertNotIn(data.decode(), text)
            self.assertIn('https://crates.io/api/v1/crates/option-ext/0.2.0/download', text)
            self.assertIn('https://github.com/rustdesk-org/rust-webm/tree/d2c4d3ac133c7b0e4c0f656da710b48391981e64', text)
            self.assertIn('/tree/' + 'a' * 40 + '/res/vcpkg/ffmpeg', text)
            self.assertNotIn('/ports/ffmpeg', text)
            for attribution in ('Rich Tibbett', 'JCraft', 'Brian Smith', 'Alliance for Open Media',
                                'UNICODE LICENSE V3', 'Project Nayuki'):
                self.assertIn(attribution, text)
            self.assertEqual((work / 'THIRD-PARTY.txt').read_bytes(), (payload / 'THIRD-PARTY.txt').read_bytes())
            self.assertEqual({p.name for p in work.iterdir()}, {'source-commit.txt', 'THIRD-PARTY.txt'})


if __name__ == '__main__':
    unittest.main()
