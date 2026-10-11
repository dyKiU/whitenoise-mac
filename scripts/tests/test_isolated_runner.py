"""Run the actual isolated wrapper with process argument recording, no SDK build."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'test-isolated.sh'


class IsolatedRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        for name in ['test-isolated.sh', 'local-device-sync-settings.sh']:
            shutil.copy2(SCRIPT.parent / name, self.root / 'scripts' / name)
        (self.root / 'tools').mkdir()
        tool = self.root / 'tools/xcodebuild'
        tool.write_text('''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as output:
    output.write(json.dumps(args) + '\\n')
if args[0] == 'build-for-testing':
    if os.environ.get('FAIL_BUILD'): sys.exit(65)
    host = pathlib.Path(next(a.split('=', 1)[1] for a in args if a.startswith('TEST_HOST=')))
    plist = host.parent.parent / 'Info.plist'
    plist.parent.mkdir(parents=True, exist_ok=True)
    plist.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.ipf.whitenoise.mac.tests'}))
''')
        tool.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.root / 'tools') + ':' + os.environ['PATH'],
                        CALLS=str(self.root / 'calls.jsonl'), WN_TEST_DERIVED_DATA=str(self.root / 'derived'),
                        WN_TEST_RESULT_BUNDLE=str(self.root / 'results.xcresult'), WN_EXPERIMENTAL_DEVICE_SYNC='0')
        self.env.pop('WN_TEST_JOBS', None)

    def run_script(self, *args):
        result = subprocess.run(['/bin/bash', str(self.root / 'scripts/test-isolated.sh'), *args],
                                env=self.env, capture_output=True, text=True)
        calls = [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]
        return result, calls

    def check_jobs(self, calls, value):
        self.assertEqual([call[0] for call in calls], ['build-for-testing', 'test-without-building'])
        for call in calls:
            self.assertEqual(call.count('-jobs'), 1)
            self.assertEqual(call[call.index('-jobs') + 1], value)

    def test_environment_budget_reaches_both_phases(self):
        self.env['WN_TEST_JOBS'] = '1'
        result, calls = self.run_script('-only-testing:whitenoise-macTests/TimelineTests')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.check_jobs(calls, '1')
        self.assertIn('-only-testing:whitenoise-macTests/TimelineTests', calls[1])
        self.assertNotIn('-only-testing:whitenoise-macTests/TimelineTests', calls[0])

    def test_explicit_budget_overrides_environment(self):
        self.env['WN_TEST_JOBS'] = '1'
        result, calls = self.run_script('-jobs', '2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.check_jobs(calls, '2')

    def test_explicit_budget_reaches_build_without_environment(self):
        result, calls = self.run_script('-jobs', '3')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.check_jobs(calls, '3')

    def test_unset_budget_preserves_defaults(self):
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        for call in calls: self.assertNotIn('-jobs', call)

    def test_build_failure_never_executes_tests(self):
        self.env['FAIL_BUILD'] = '1'
        result, calls = self.run_script()
        self.assertEqual(result.returncode, 65)
        self.assertEqual([call[0] for call in calls], ['build-for-testing'])


if __name__ == '__main__':
    unittest.main()
