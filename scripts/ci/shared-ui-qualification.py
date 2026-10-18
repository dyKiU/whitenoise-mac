#!/usr/bin/env python3
"""Hosted real raster suite counterfactual; no full or sync-native claim."""
import argparse
import copy
import difflib
import re
import signal
import stat
import time
import hashlib
import json
import os
from pathlib import Path
import subprocess

BASE = '2a60df8f95245328b43b324c325a31540b2488e5'
PREVIOUS = '5db1dc879149ec8b168baa24cb860d8d32b9c02e'
SELF = 'scripts/ci/shared-ui-qualification.py'
WORKFLOW = '.github/workflows/mac-ci.yml'
BEGIN = '  # SHARED_UI_FORMAT_JOBS_BEGIN\n'
END = '  # SHARED_UI_FORMAT_JOBS_END\n'
OPTIONS = 'options: [full, onboarding-mutations, shared-ui-format, shared-ui-raster-measure, shared-ui-raster-red-green, shared-ui-raster-pfp]'
ORIGINAL_OPTIONS = 'options: [full, onboarding-mutations]'
REF = 'refs/heads/ci/upstream-shared-ui-qualification-20261018'
OUT = Path('build/shared-ui-qualification')
FILES = [
    'whitenoise-mac/Features/AutomaticChatPresentation/AccountConversationViewModel.swift',
    'whitenoise-mac/Features/AutomaticChatPresentation/ConversationSourcePreference.swift',
    'whitenoise-mac/Features/AutomaticChatPresentation/PairedMessagePresentation.swift',
    'whitenoise-mac/Views/AutomaticChatListSection.swift',
    'whitenoise-mac/Views/AutomaticChatPeerDisplay.swift',
    'whitenoise-mac/Views/AutomaticConversationView.swift',
    'whitenoise-mac/Views/MarkdownMessageView.swift',
    'whitenoise-mac/Views/MessageMediaViews.swift',
    'whitenoise-mac/Views/MessageTextSelection.swift',
    'whitenoise-mac/Views/MessengerShellView.swift',
    'whitenoise-mac/Views/PairedChatMessageRow.swift',
    'whitenoise-mac/Views/Settings/PreferencesSettingsView.swift',
    'whitenoise-mac/Views/SidebarViews.swift',
    'whitenoise-macTests/AutomaticPendingSendTests.swift',
    'whitenoise-macTests/ConversationSourcePreferenceTests.swift',
    'whitenoise-macTests/MarkdownRendererParityTests.swift',
    'whitenoise-macTests/PairedMessagePresentationTests.swift',
]


def require(value,label):
    if not value: raise ValueError(label)


def git(*args):
    return subprocess.check_output(['git',*args]).decode().strip()


def tree(ref):
    result = {}
    for entry in subprocess.check_output(['git','ls-tree','-r','-z',ref]).split(b'\0'):
        if not entry: continue
        meta,name = entry.split(b'\t',1); mode,kind,blob = meta.decode().split()
        require(kind == 'blob' and mode in {'100644','100755','120000'},'ordinary-blob-tree')
        result[os.fsdecode(name)] = (mode,blob)
    return result


def guard():
    head = git('rev-parse','HEAD')
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == 'dyKiU/whitenoise-mac'
        and os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and os.environ.get('GITHUB_SHA') == head
        and os.environ.get('GITHUB_REF') == REF
        and os.environ.get('GITHUB_WORKFLOW_REF') == 'dyKiU/whitenoise-mac/' + WORKFLOW + '@' + REF
        and os.environ.get('SHARED_UI_BASELINE') == BASE and os.environ.get('RUNNER_OS') == 'macOS', 'owned-hosted-source')
    version = subprocess.check_output(['sw_vers','-productVersion'],text=True).strip()
    require(version.startswith('26.'),'hosted-macos26-required')
    subprocess.run(['git','merge-base','--is-ancestor',BASE,head],check=True)
    require(subprocess.run(['git','diff','--quiet','HEAD']).returncode == 0,'tracked-pristine')
    expected = tree(BASE); current = tree('HEAD')
    require(SELF not in expected and WORKFLOW in expected and set(current) == set(expected)|{SELF},'whole-source-inventory')
    for name,(mode,blob) in current.items():
        require((mode == '120000' and Path(name).is_symlink()) or (mode != '120000' and not Path(name).is_symlink()),'actual-symlink-mode')
        if mode != '120000': require(bool(Path(name).stat().st_mode & 0o111) == (mode == '100755'),'actual-executable-mode')
        data = os.fsencode(os.readlink(name)) if mode == '120000' else Path(name).read_bytes()
        require(hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == blob,'tracked-bytes:' + name)
        if name == SELF:
            require(mode == '100644','owned-metadata-mode')
        elif name == WORKFLOW:
            text = data.decode()
            require(text.count(BEGIN) == text.count(END) == text.count(OPTIONS) == 1,'one-owned-workflow-overlay')
            before,rest = text.split(BEGIN); _,after = rest.split(END)
            restored = (before + after).replace(OPTIONS,ORIGINAL_OPTIONS,1).encode()
            restored_blob = hashlib.sha1(b'blob ' + str(len(restored)).encode() + b'\0' + restored).hexdigest()
            require((mode,restored_blob) == expected[name],'exact-original-workflow-reconstruction')
        else:
            require(current[name] == expected[name],'whole-baseline-contents-modes:' + name)
    require(not git('ls-files','--others','--exclude-standard'),'no-untracked-source')
    require(git('diff','--name-only',PREVIOUS,BASE,'--','*.swift').splitlines() == FILES,'exact-seventeen-integrated-Swift-files')
    return {'source_sha':head,'source_tree':git('rev-parse','HEAD^{tree}'),'baseline':BASE,
        'baseline_tree':git('rev-parse',BASE+'^{tree}'),'whole_source_modes_exact':True,'macos_version':version,
        'inherited_sdk_manifest_sha256':hashlib.sha256(Path('Vendored/MarmotKit/Package.swift').read_bytes()).hexdigest(),
        'SDK_consumed':False,'build_or_native_qualification_claim':False}


VIEW = 'whitenoise-mac/Views/MarkdownMessageView.swift'
TEST = 'whitenoise-macTests/MarkdownRendererParityTests.swift'
OLD = 'if let document, document.timestamps != .none {'
NEW = 'if let document, false && document.timestamps != .none {'
SUITE = 'MarkdownRendererParityTests'
METHODS = {
    'sourceAttestedAndNativeTextUseTheSameRenderer': 'appearance:',
    'sourceAttestedFallbackMatchesNativeTextWithoutTokens': '',
    'sharedTimestampsRefreshForDrawLocaleRatherThanRetainingCachedText': 'appearance:',
}
TARGET = 'sharedTimestampsRefreshForDrawLocaleRatherThanRetainingCachedText'
COUNT_KEYS = ('totalTestCount','passedTests','failedTests','skippedTests')
STATUS_KEYS = {'Passed':'passedTests','Failed':'failedTests','Skipped':'skippedTests'}


def fingerprint():
    result = {}
    for name in filter(None,subprocess.check_output(['git','ls-files','-z']).decode().split('\0')):
        p = Path(name)
        data = os.fsencode(os.readlink(name)) if p.is_symlink() else p.read_bytes()
        result[name] = {'sha256':hashlib.sha256(data).hexdigest(),'mode':stat.S_IMODE(p.lstat().st_mode)}
    return result


def source_method(identifier):
    if not isinstance(identifier,str) or len(identifier) > 512: return None
    for prefix in ['whitenoise-macTests/','whitenoise_macTests/']:
        if identifier.startswith(prefix): identifier = identifier[len(prefix):]
    for name,labels in METHODS.items():
        if identifier == SUITE + '/' + name + '(' + labels + ')': return name
    return None


def native_inventory(tree,summary):
    result = {'status':'schema_unknown','definition_rows':[],'argument_leaf_rows':[],
        'definition_counts':None,'argument_leaf_counts':None,'summary_count_basis':None,
        'unknown_node_count':0,'unexpected_test_definitions':0}
    if not isinstance(tree,dict) or not isinstance(tree.get('testNodes'),list): return result
    seen = set(); node_count = 0
    def walk(value,parent=None,depth=0):
        nonlocal node_count
        node_count += 1
        if node_count > 20000 or depth > 48: raise ValueError('bounded-native-tree-limit')
        if isinstance(value,list):
            for child in value: walk(child,parent,depth+1)
        elif isinstance(value,dict):
            kind = value.get('nodeType')
            if kind == 'Test Case':
                name = source_method(value.get('nodeIdentifier',value.get('testIdentifier')))
                status = value.get('result',value.get('status'))
                if name is None or name in seen or status not in STATUS_KEYS:
                    result['unexpected_test_definitions'] += 1; parent = None
                else:
                    seen.add(name); parent = name
                    result['definition_rows'].append({'method':name,'status':status})
            elif kind == 'Test Case Run':
                status = value.get('result',value.get('status'))
                if parent not in METHODS or status not in STATUS_KEYS: result['unknown_node_count'] += 1
                else:
                    ordinal = 1 + sum(row['method'] == parent for row in result['argument_leaf_rows'])
                    result['argument_leaf_rows'].append({'method':parent,'ordinal':ordinal,'status':status})
            elif isinstance(kind,str) and kind not in {'Test Plan','Device','Test Bundle','Test Suite'}:
                result['unknown_node_count'] += 1
            for child in value.values():
                if isinstance(child,(dict,list)): walk(child,parent,depth+1)
    walk(tree['testNodes'])
    result['visited_nodes'] = node_count
    if seen != set(METHODS) or result['unexpected_test_definitions'] or result['unknown_node_count']: return result
    # A nonparameterized definition with no run node represents its one leaf.
    for row in result['definition_rows']:
        if not METHODS[row['method']] and not any(v['method'] == row['method'] for v in result['argument_leaf_rows']):
            result['argument_leaf_rows'].append({'method':row['method'],'ordinal':1,'status':row['status']})
    if any(sum(row['method'] == name for row in result['argument_leaf_rows']) != (2 if labels else 1) for name,labels in METHODS.items()):
        result['status'] = 'argument_leaf_inventory_unknown'; return result
    def counts(rows):
        data = dict.fromkeys(COUNT_KEYS,0); data['totalTestCount'] = len(rows)
        for row in rows: data[STATUS_KEYS[row['status']]] += 1
        return data
    result['definition_counts'] = counts(result['definition_rows'])
    result['argument_leaf_counts'] = counts(result['argument_leaf_rows'])
    if not isinstance(summary,dict) or not all(type(summary.get(k)) is int and summary[k] >= 0 for k in COUNT_KEYS): return result
    original = {k:summary[k] for k in COUNT_KEYS}
    if original['totalTestCount'] != sum(original[k] for k in COUNT_KEYS[1:]): return result
    for label in ['definition','argument_leaf']:
        if result[label+'_counts'] == original:
            result['summary_count_basis'] = label; result['status'] = 'complete'; break
    return result


def parser_controls():
    def definition(name,status='Passed'):
        node = {'nodeType':'Test Case','nodeIdentifier':SUITE+'/'+name+'('+METHODS[name]+')','result':status}
        if METHODS[name]: node['children'] = [{'nodeType':'Test Case Run','result':status},{'nodeType':'Test Case Run','result':status}]
        return node
    tree = {'testNodes':[{'nodeType':'Test Suite','children':[definition(name) for name in METHODS]}]}
    leaves = dict(totalTestCount=5,passedTests=5,failedTests=0,skippedTests=0)
    definitions = dict(totalTestCount=3,passedTests=3,failedTests=0,skippedTests=0)
    require(native_inventory(tree,leaves)['summary_count_basis'] == 'argument_leaf','leaf-summary-positive')
    require(native_inventory(tree,definitions)['summary_count_basis'] == 'definition','definition-summary-positive')
    bad = [copy.deepcopy(tree) for _ in range(5)]
    bad[0]['testNodes'][0]['children'].pop()
    bad[1]['testNodes'][0]['children'].append(definition(TARGET))
    bad[2]['testNodes'][0]['children'][0]['children'].pop()
    bad[3]['testNodes'][0]['children'][0]['nodeIdentifier'] = 'private payload'
    bad[4]['testNodes'][0]['children'][0]['children'][0]['result'] = 'Unknown'
    for value in bad: require(native_inventory(value,leaves)['status'] != 'complete','no-invented-native-coverage')
    wrong = dict(leaves,totalTestCount=True)
    require(native_inventory(tree,wrong)['status'] != 'complete','bool-count-not-execution')
    return {'positive':2,'negative':6,'runtime_bodies':0,'schema_fixtures_not_actual_execution':True}


def summary_safe(raw):
    return {k:raw[k] for k in COUNT_KEYS + ('result','startTime','finishTime','duration') if k in raw}


def sdk_identity(output):
    require(os.environ.get('WN_EXPERIMENTAL_DEVICE_SYNC') == '0','published-sdk-only')
    require(not Path('Vendored/MarmotKit/LOCAL_BUILD.json').exists(),'no-local-sdk-overlay')
    package = Path('Vendored/MarmotKit/Package.swift').read_text()
    version = Path('Vendored/MarmotKit/Sources/MarmotKit/MarmotKitVersion.swift').read_text()
    require('let marmotKitReleaseID = "0.13.0"' in package and 'let marmotKitLocalPath: String? = nil' in package
        and '891ab34980ee9dc2ef45bf690733a6e31d3e6778' in version,'unchanged-published-sdk-source-pin')
    return {'cohort':'published0.13','source_sha':'891ab34980ee9dc2ef45bf690733a6e31d3e6778',
        'manifest_sha256':hashlib.sha256(package.encode()).hexdigest(),'version_source_sha256':hashlib.sha256(version.encode()).hexdigest(),
        'actual_resolved_frameworks':[],'native_sync_qualified':False}


def execute(label,expected,save,result):
    require(fingerprint() == expected,'before-runtime-source-mode-pristine')
    output = OUT / label; output.mkdir(parents=True,exist_ok=True)
    bundle = output / 'Results.xcresult'; log = output / 'runtime-private.log'
    require(not bundle.exists(),'fresh-native-bundle-required')
    environment = dict(os.environ,WN_EXPERIMENTAL_DEVICE_SYNC='0',WN_TEST_JOBS='3',
        WN_TEST_DERIVED_DATA=str((OUT/'DerivedData').resolve()),WN_TEST_RESULT_BUNDLE=str(bundle.resolve()))
    command = ['scripts/test-isolated.sh','-only-testing:whitenoise-macTests/MarkdownRendererParityTests']
    row = {'phase':label,'command':command,'runtime_summary':None,'runtime_inventory':None,'actual_runtime_counts_known':False,
        'green':False,'counterfactual_RED':False,'source_expected_sha256':hashlib.sha256(json.dumps(expected,sort_keys=True).encode()).hexdigest()}
    result['phases'][label] = row; save(); start = time.monotonic()
    with log.open('x') as stream:
        process = subprocess.Popen(command,env=environment,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            row['exit_code'] = process.wait(timeout=1800)
        except subprocess.TimeoutExpired:
            row['exit_code'] = None; row['watchdog_triggered'] = True
            os.killpg(process.pid,signal.SIGTERM)
            try: process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL); process.wait()
    row['wall_seconds'] = round(time.monotonic()-start,3); row['bundle_exists'] = bundle.exists(); save()
    require(fingerprint() == expected,'after-runtime-source-mode-pristine')
    if not bundle.exists(): return row
    exports = {}
    for kind in ['summary','tests']:
        try:
            data = subprocess.check_output(['xcrun','xcresulttool','get','test-results',kind,'--path',str(bundle)],timeout=90)
            require(len(data) <= 8*1024*1024,'bounded-native-export')
            exports[kind] = json.loads(data)
        except (subprocess.SubprocessError,ValueError):
            row['native_export_failed'] = kind; save(); return row
        if kind == 'summary': row['runtime_summary'] = summary_safe(exports[kind]); save()  # Counts precede inventory parsing.
    inventory = native_inventory(exports['tests'],exports['summary']); row['runtime_inventory'] = inventory
    row['actual_runtime_counts_known'] = inventory['status'] == 'complete'; save()
    require(log.stat().st_size <= 64*1024*1024,'bounded-private-runtime-log')
    raw = log.read_text(errors='replace')
    # Only fixed source sites and static issue class survive; no assertion values or raster bytes.
    issue_lines = [line for line in raw.splitlines() if 'recorded an issue at ' in line]
    locations = []
    for line in issue_lines:
        match = re.search(r'MarkdownRendererParityTests\.swift:([0-9]+):([0-9]+):',line)
        if match: locations.append({'file':TEST,'line':int(match[1]),'column':int(match[2]),'expectation_failure':'Expectation failed' in line})
    row['safe_issue_locations'] = locations[:32]; row['unknown_issue_count'] = len(issue_lines)-len(locations)
    row['issue_locations_truncated'] = len(locations) > 32
    row['build_succeeded'] = '** TEST BUILD SUCCEEDED **' in raw
    row['sdk'] = sdk_identity(OUT)
    frameworks = sorted((OUT/'DerivedData/SourcePackages/artifacts').rglob('*.xcframework'))
    for framework in frameworks:
        files = {}
        for path in sorted(framework.rglob('*')):
            if path.is_file():
                digest = hashlib.sha256()
                with path.open('rb') as stream:
                    for block in iter(lambda:stream.read(1024*1024),b''): digest.update(block)
                files[str(path.relative_to(framework))] = digest.hexdigest()
        row['sdk']['actual_resolved_frameworks'].append({'bundle_name':framework.name,'files':files})
    app = OUT/'DerivedData/Build/Products/Debug/White Noise Unit Host.app/Contents/MacOS/White Noise Unit Host'
    test = OUT/'DerivedData/Build/Products/Debug/whitenoise-macTests.xctest/Contents/MacOS/whitenoise-macTests'
    row['binaries'] = {str(path.relative_to(OUT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in [app,test] if path.is_file()}
    if inventory['status'] == 'complete' and row['build_succeeded'] and row['sdk']['actual_resolved_frameworks']:
        definitions = inventory['definition_rows']; leaves = inventory['argument_leaf_rows']
        row['green'] = (row['exit_code'] == 0 and all(v['status'] == 'Passed' for v in definitions+leaves)
            and not issue_lines and bool(row['binaries']))
        row['counterfactual_RED'] = (row['exit_code'] not in {None,0} and not row.get('watchdog_triggered')
            and all(v['status'] == ('Failed' if v['method'] == TARGET else 'Passed') for v in definitions+leaves)
            and len(locations) == len(issue_lines) == 2 and all(v['expectation_failure'] and 63 <= v['line'] <= 66 for v in locations)
            and bool(row['binaries']))
    row['source_pristine'] = fingerprint() == expected; save(); return row


def format_feedback(result,save):
    patches = []; result['formatted_files'] = {}
    for name in FILES:
        original = Path(name).read_text()
        formatted = subprocess.check_output(['xcrun','swift-format','format','--configuration','.swift-format',name],text=True)
        require(Path(name).read_text() == original,'formatter-does-not-mutate-input')
        result['formatted_files'][name] = {'needs_format':original != formatted}
        patches.extend(difflib.unified_diff(original.splitlines(True),formatted.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
    patch = ''.join(patches).encode(); (OUT/'format.patch').write_bytes(patch)
    result['format_patch_bytes'] = len(patch); result['format_patch_sha256'] = hashlib.sha256(patch).hexdigest()
    result['format_passed'] = not patch; save(); require(not patch,'hosted-format-patch-must-be-empty')


def main(args):
    os.umask(0o077); OUT.mkdir(parents=True,exist_ok=True)
    result = {'mode':args.mode,'phases':{},'component_GREEN':False,'counterfactual_runtime_RED_verified':False,
        'component_mutation_qualified':False,'full_qualification':False,'native_sync_acceptance':False,'promotion_eligible':False,
        'historical_owner_012_RED_claim':False}
    original = None; permissions = None; before = None
    def save(): (OUT/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    try:
        result['source'] = guard(); result['parser_controls'] = parser_controls(); save()
        if args.mode == 'preflight':
            format_feedback(result,save); return
        require(Path(VIEW).read_text().count(OLD) == 1 and NEW not in Path(VIEW).read_text(),'one-exact-reviewed-renderer-condition')
        sdk_identity(OUT); before = fingerprint(); original = Path(VIEW).read_bytes(); permissions = Path(VIEW).stat().st_mode
        labels = ['measured-baseline'] if args.mode == 'measure' else ['baseline','mutant','restored'] if args.mode == 'pfp' else ['mutant','restored']
        for label in labels:
            content = original.replace(OLD.encode(),NEW.encode(),1) if label == 'mutant' else original
            Path(VIEW).write_bytes(content); Path(VIEW).chmod(permissions)
            expected = copy.deepcopy(before); expected[VIEW]['sha256'] = hashlib.sha256(content).hexdigest()
            row = execute(label,expected,save,result)
            if args.mode == 'measure':
                result['measurement_complete'] = row['actual_runtime_counts_known']; save(); continue
            require(row['counterfactual_RED'] if label == 'mutant' else row['green'],'actual-specific-raster-oracle-required')
        if args.mode == 'red-green': result['counterfactual_runtime_RED_verified'] = True
        elif args.mode == 'pfp':
            a,b,c = [result['phases'][key] for key in ['baseline','mutant','restored']]
            require(a['source_expected_sha256'] == c['source_expected_sha256'] != b['source_expected_sha256'],'exact-original-source-restoration')
            require(a['sdk'] == b['sdk'] == c['sdk'],'same-resolved-published-sdk')
            require(a['binaries'] == c['binaries'] and a['binaries'] != b['binaries'],'actual-binary-restoration-required')
            result['component_mutation_qualified'] = True
    except Exception as error:
        result['exception_type'] = type(error).__name__
        if isinstance(error,ValueError): result['failure_gate'] = str(error)
        raise
    finally:
        if original is not None: Path(VIEW).write_bytes(original); Path(VIEW).chmod(permissions)
        if before is not None: result['whole_source_modes_restored'] = fingerprint() == before
        if result.get('whole_source_modes_restored') is False:
            result['counterfactual_runtime_RED_verified'] = result['component_mutation_qualified'] = False
        save()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--mode',choices=['preflight','measure','red-green','pfp'],default='preflight')
    main(parser.parse_args())
