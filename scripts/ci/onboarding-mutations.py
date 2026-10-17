#!/usr/bin/env python3
"""Remote-only behavioral mutation qualification; never changes committed source."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time

BASE = 'db6bbc7ea1b72e791aa11902fd71494707b57c68'
SELF = 'scripts/ci/onboarding-mutations.py'
WORKFLOW = '.github/workflows/mac-ci.yml'
MODEL = 'whitenoise-mac/Features/Onboarding/OnboardingCoordinator.swift'
VIEW = 'whitenoise-mac/Views/Onboarding/OnboardingView.swift'
HOST = 'AddProfileRoutingTests/'
GUIDE = 'AccountSetupGuideTests/'
CASES = {
    HOST + 'testAddProfileKeepsWelcomeRouteWithExistingReadyAccount',
    HOST + 'testUnfinishedSetupCompletesThenAllowsAnotherProfile',
    HOST + 'testRemovedCheckpointClearsExistingSetupPresentation',
    GUIDE + 'aWalkedThroughSetupWaitsForOpenChats()',
    GUIDE + 'anAlreadyReadyCheckpointGoesStraightIn()',
    GUIDE + 'openChatsDoesNothingBeforeTheCheckpointIsReady()',
    GUIDE + 'anAlreadyReadyCheckpointDoesNotReplaceWelcome()',
    GUIDE + 'aWalkedThroughSetupLeavesThePaneOnceTheChatsAreEntered()',
}
MUTATIONS = [
    ('guided-ready-bypass', MODEL,
     'isDurablyReady && (!hasShownIncompleteSetup || hasConfirmedOpenChats)',
     'isDurablyReady',
     {GUIDE + 'aWalkedThroughSetupWaitsForOpenChats()',
      GUIDE + 'aWalkedThroughSetupLeavesThePaneOnceTheChatsAreEntered()',
      HOST + 'testUnfinishedSetupCompletesThenAllowsAnotherProfile'},
     'canEnterChats'),
    ('entered-chats-guard-omitted', VIEW,
     'guard let model, model.snapshot != nil, !model.hasEnteredChats else { return false }',
     'guard let model, model.snapshot != nil else { return false }',
     {GUIDE + 'aWalkedThroughSetupLeavesThePaneOnceTheChatsAreEntered()'},
     'OnboardingView.showsAccountSetup(model)'),
]


def require(condition, code):
    if not condition:
        raise RuntimeError(code)


def git(*args):
    return subprocess.check_output(['git', *args]).decode().strip()


def fingerprint():
    paths = subprocess.check_output(['git', 'ls-files', '-z']).decode().split('\0')
    digest = hashlib.sha256()
    count = 0
    for name in sorted(filter(None, paths)):
        path = Path(name)
        mode = stat.S_IMODE(path.lstat().st_mode)
        content = os.readlink(path).encode() if path.is_symlink() else path.read_bytes()
        digest.update(name.encode() + b'\0' + str(mode).encode() + b'\0')
        digest.update(hashlib.sha256(content).digest())
        count += 1
    return {'sha256': digest.hexdigest(), 'tracked_files': count}


def case_rows(tree):
    rows = []
    def visit(value):
        if isinstance(value, list):
            for child in value:
                visit(child)
        elif isinstance(value, dict):
            if value.get('nodeType') == 'Test Case':
                identifier = value.get('nodeIdentifier', value.get('testIdentifier', ''))
                for prefix in ('whitenoise-macTests/', 'whitenoise_macTests/'):
                    if identifier.startswith(prefix):
                        identifier = identifier[len(prefix):]
                if identifier.startswith(HOST) and identifier.endswith('()'):
                    identifier = identifier[:-2]
                rows.append((identifier, value.get('result', value.get('status'))))
            for child in value.values():
                if isinstance(child, (dict, list)):
                    visit(child)
    visit(tree)
    require(len(rows) == len(CASES), 'native-case-count')
    require({name for name, _ in rows} == CASES, 'native-case-identities')
    require(all(status in ('Passed', 'Failed') for _, status in rows), 'native-case-status')
    return dict(rows)


def parser_controls():
    tree = {'testNodes': [{'nodeType': 'Test Case', 'nodeIdentifier': name, 'result': 'Passed'}
                          for name in sorted(CASES)]}
    require(len(case_rows(tree)) == 8, 'parser-positive')
    negative = [[], tree['testNodes'][:-1], tree['testNodes'] + [tree['testNodes'][0]],
                [dict(row, result='Skipped') for row in tree['testNodes']],
                [dict(row, result='unknown') for row in tree['testNodes']],
                [dict(row, nodeIdentifier='WrongSuite/wrong') for row in tree['testNodes']]]
    for value in negative:
        try:
            case_rows(value)
        except RuntimeError:
            continue
        raise RuntimeError('parser-negative-accepted')
    return {'positive': 1, 'negative': len(negative)}


def preflight():
    require(os.environ.get('GITHUB_ACTIONS') == 'true', 'remote-only')
    require(os.environ.get('WN_EXPERIMENTAL_DEVICE_SYNC') != '1', 'published-cohort-only')
    require(not Path('Vendored/MarmotKit/LOCAL_BUILD.json').exists(), 'no-local-sdk-overlay')
    require(git('rev-parse', 'HEAD') == os.environ.get('GITHUB_SHA'), 'exact-checkout')
    subprocess.run(['git', 'merge-base', '--is-ancestor', BASE, 'HEAD'], check=True)
    changed = set(git('diff', '--name-only', BASE, 'HEAD').splitlines())
    require(changed <= {SELF, WORKFLOW}, 'product-inputs-differ-from-reviewed-base')
    require(not git('status', '--porcelain', '--untracked-files=no'), 'dirty-checkout')
    for _, name, old, _, _, _ in MUTATIONS:
        require(Path(name).read_text().count(old) == 1, 'exact-mutation-location')
    for command in [('test-results', 'summary'), ('test-results', 'tests')]:
        subprocess.run(['xcrun', 'xcresulttool', 'get', *command, '--help'], check=True,
                       stdout=subprocess.DEVNULL)
    return parser_controls()


def sdk_identity(output):
    frameworks = list((output / 'DerivedData/SourcePackages/artifacts').rglob('MarmotKit.xcframework'))
    require(len(frameworks) == 1, 'one-resolved-marmot-framework')
    files = {}
    for path in sorted(frameworks[0].rglob('*')):
        if path.is_file():
            digest = hashlib.sha256()
            with path.open('rb') as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(chunk)
            files[str(path.relative_to(frameworks[0]))] = digest.hexdigest()
    require(bool(files), 'resolved-sdk-inventory-empty')
    return {'cohort': 'published',
            'package_manifest_sha256': hashlib.sha256(Path('Vendored/MarmotKit/Package.swift').read_bytes()).hexdigest(),
            'framework_files': files}


def execute(label, output):
    bundle = output / (label + '.xcresult')
    env = dict(os.environ, WN_TEST_DERIVED_DATA=str(output / 'DerivedData'),
               WN_TEST_RESULT_BUNDLE=str(bundle), WN_TEST_JOBS='3')
    selectors = ['-only-testing:whitenoise-macTests/AddProfileRoutingTests']
    selectors += ['-only-testing:whitenoise-macTests/' + name
                  for name in sorted(CASES) if name.startswith(GUIDE)]
    command = ['scripts/test-isolated.sh', *selectors]
    start = time.monotonic()
    with (output / (label + '.log')).open('w') as log:
        result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT)
    row = {'command': command, 'exit': result.returncode,
           'wall_seconds': round(time.monotonic() - start, 3), 'source': fingerprint()}
    # Persist the command outcome even when compilation or XCResult export fails.
    (output / (label + '-command.json')).write_text(json.dumps(row, indent=2) + '\n')
    require(bundle.exists(), 'no-runtime-result-bundle')
    for kind in ('summary', 'tests'):
        export = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', kind,
                                 '--path', str(bundle)], capture_output=True, text=True)
        require(export.returncode == 0, 'native-export-' + kind)
        row[kind] = json.loads(export.stdout)
        (output / (label + '-' + kind + '.json')).write_text(export.stdout)
        if kind == 'summary':
            keys = ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')
            row['exported_native_counts'] = {key: row[kind].get(key) for key in keys}
        (output / (label + '-command.json')).write_text(json.dumps(row, indent=2) + '\n')
    summary = row['summary']
    keys = ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')
    require(all(type(summary.get(key)) is int for key in keys), 'native-count-schema')
    require(summary['totalTestCount'] == 8 and summary['skippedTests'] == 0, 'eight-executed-no-skips')
    require(summary['passedTests'] + summary['failedTests'] == 8, 'native-count-consistency')
    row['cases'] = case_rows(row.pop('tests'))
    require(sum(status == 'Failed' for status in row['cases'].values()) == summary['failedTests'],
            'native-failures-consistent')
    row['counts'] = {key: summary[key] for key in keys}
    row['sdk'] = sdk_identity(output)
    row.pop('summary')
    raw = (output / (label + '.log')).read_text()
    require('** TEST BUILD SUCCEEDED **' in raw, 'build-did-not-pass')
    row['runtime_expectation_marker'] = 'Expectation failed:' in raw
    row['assertion_markers'] = {marker: marker in raw for *_, marker in MUTATIONS}
    (output / (label + '-command.json')).write_text(json.dumps(row, indent=2) + '\n')
    return row


def passing(row):
    return row['exit'] == 0 and all(status == 'Passed' for status in row['cases'].values())


def main():
    arguments = argparse.ArgumentParser()
    arguments.add_argument('--preflight', action='store_true')
    options = arguments.parse_args()
    controls = preflight()
    if options.preflight:
        print(json.dumps({'parser_controls': controls, 'source': fingerprint()}))
        return
    output = Path('build/onboarding-mutations').resolve()
    output.mkdir(parents=True, exist_ok=False)
    original = fingerprint()
    report = {'source_commit': git('rev-parse', 'HEAD'), 'reviewed_product_base': BASE,
              'source_before': original, 'parser_controls': controls, 'chains': [],
              'qualified': False, 'historical_behavioral_red_claimed': False,
              'toolchain': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
              'host': subprocess.check_output(['sw_vers'], text=True).strip(),
              'execution_count_scope': 'validated native rows only; command/summary files retain exporter failures'}
    def save():
        (output / 'result.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    save()
    try:
        baseline = execute('baseline', output)
        report['baseline'] = baseline
        save()
        require(passing(baseline) and fingerprint() == original, 'baseline-not-green-and-pristine')
        for name, file, old, new, allowed, marker in MUTATIONS:
            path = Path(file)
            source = path.read_bytes()
            chain = {'name': name, 'qualified': False,
                     'baseline_label': ('baseline' if not report['chains']
                                        else report['chains'][-1]['name'] + '-restored')}
            report['chains'].append(chain)
            try:
                require(fingerprint() == original, 'source-before-mutation')
                path.write_bytes(source.replace(old.encode(), new.encode(), 1))
                chain['mutated_source'] = fingerprint()
                mutant = execute(name + '-mutant', output)
                chain['mutant'] = mutant
                failed = {case for case, status in mutant['cases'].items() if status == 'Failed'}
                chain['runtime_detected'] = (
                    mutant['exit'] == 65 and bool(failed) and failed <= allowed
                    and mutant['source'] == chain['mutated_source']
                    and GUIDE + 'aWalkedThroughSetupLeavesThePaneOnceTheChatsAreEntered()' in failed
                    and mutant['runtime_expectation_marker'] and mutant['assertion_markers'][marker])
            except Exception as error:
                chain['mutant_error'] = str(error)
            finally:
                path.write_bytes(source)
                chain['source_restored'] = fingerprint() == original
                save()
                try:
                    restored = execute(name + '-restored', output)
                    chain['restored'] = restored
                    chain['qualified'] = (chain.get('runtime_detected', False)
                                          and chain['source_restored'] and passing(restored)
                                          and fingerprint() == original
                                          and restored['sdk'] == baseline['sdk']
                                          and chain.get('mutant', {}).get('sdk') == baseline['sdk'])
                except Exception as error:
                    chain['restored_error'] = str(error)
                save()
            require(chain['source_restored'] and chain.get('restored') and passing(chain['restored']),
                    'restored-control-not-green')
        report['qualified'] = len(report['chains']) == 2 and all(row['qualified'] for row in report['chains'])
        require(report['qualified'], 'mutation-qualification-incomplete')
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        executions = [report.get('baseline')]
        for chain in report['chains']:
            executions.extend([chain.get('mutant'), chain.get('restored')])
        report['recorded_actual_executions'] = sum(row['counts']['totalTestCount'] for row in executions if row and 'counts' in row)
        report['attempt_receipts'] = []
        for receipt in sorted(output.glob('*-command.json')):
            attempt = json.loads(receipt.read_text())
            report['attempt_receipts'].append({'file': receipt.name, 'exit': attempt['exit'],
                'wall_seconds': attempt['wall_seconds'],
                'exported_native_counts': attempt.get('exported_native_counts'),
                'case_identity_validated': 'counts' in attempt})
        report['source_after'] = fingerprint()
        report['source_pristine'] = report['source_after'] == original
        save()


if __name__ == '__main__':
    main()
