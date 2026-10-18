#!/usr/bin/env python3
"""Hosted real raster suite counterfactual; no full or sync-native claim."""
import argparse
import copy
import difflib
import re
import selectors
import signal
import stat
import time
import hashlib
import json
import math
import os
import plistlib
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
        'unknown_node_count':0,'unexpected_test_definitions':0,'node_type_diagnostics':{},'unknown_shapes':[],
        'argument_names_distinct_by_parent':{}}
    if not isinstance(tree,dict) or not isinstance(tree.get('testNodes'),list): return result
    seen = set(); argument_names = {name:set() for name,labels in METHODS.items() if labels}
    duplicate_arguments = set(); node_count = 0
    containers = {'Test Plan','Device','Test Bundle','Unit test bundle','Test Suite'}
    diagnostic_types = containers | {'Test Case','Test Case Run','Arguments','Argument','Test Argument','Test Iteration','Repetition','Test Case Group'}
    argument_keys = {'duration','durationInSeconds','name','nodeType','result'}
    def diagnostic(node,parent,unknown=False):
        kind = node.get('nodeType')
        category = kind if isinstance(kind,str) and kind in diagnostic_types else 'unapproved_type' if isinstance(kind,str) else 'nonstring_type'
        result['node_type_diagnostics'][category] = result['node_type_diagnostics'].get(category,0) + 1
        if unknown:
            structural_keys = {'nodeType','children','result','status','nodeIdentifier','testIdentifier','nodeIdentifierURL','duration','durationInSeconds','name'}
            status = node.get('result',node.get('status'))
            shape = {'type_category':category,'type_sha256':hashlib.sha256(kind.encode()).hexdigest() if isinstance(kind,str) else None,
                'known_structural_keys':sorted(structural_keys & set(node)),'other_key_count':len(set(node)-structural_keys),
                'closed_result':status if isinstance(status,str) and status in STATUS_KEYS else 'unknown',
                'parent_source_method_known':parent in METHODS,'children_count':len(node['children']) if isinstance(node.get('children'),list) else None}
            if len(result['unknown_shapes']) < 32: result['unknown_shapes'].append(shape)
            else: result['unknown_shape_records_truncated'] = True
    def walk(value,parent=None,parent_kind=None,depth=0):
        nonlocal node_count
        node_count += 1
        if node_count > 20000 or depth > 48: raise ValueError('bounded-native-tree-limit')
        if isinstance(value,list):
            for child in value: walk(child,parent,parent_kind,depth+1)
            return
        if not isinstance(value,dict):
            result['unknown_node_count'] += 1; return
        kind = value.get('nodeType'); status = value.get('result',value.get('status'))
        known = False; next_parent = None
        if kind == 'Test Case':
            name = source_method(value.get('nodeIdentifier',value.get('testIdentifier')))
            if parent is not None or name is None or name in seen or not isinstance(status,str) or status not in STATUS_KEYS:
                result['unexpected_test_definitions'] += 1
            else:
                seen.add(name); next_parent = name; known = True
                result['definition_rows'].append({'method':name,'status':status})
        elif kind == 'Arguments':
            name = value.get('name'); seconds = value.get('durationInSeconds'); duration = value.get('duration')
            valid = (set(value) == argument_keys and parent_kind == 'Test Case' and parent in argument_names
                and isinstance(name,str) and 0 < len(name.encode()) <= 1024
                and isinstance(duration,str) and 0 < len(duration) <= 64
                and type(seconds) in {int,float} and math.isfinite(seconds) and seconds >= 0
                and isinstance(status,str) and status in STATUS_KEYS)
            if valid:
                identity = hashlib.sha256(name.encode()).digest()  # Internal only; never exported.
                if identity in argument_names[parent]: duplicate_arguments.add(parent)
                else:
                    argument_names[parent].add(identity); known = True
                    ordinal = len(argument_names[parent])
                    result['argument_leaf_rows'].append({'method':parent,'ordinal':ordinal,'status':status})
        elif isinstance(kind,str) and kind in containers:
            known = parent is None
        # Test Case Run and every other unobserved execution schema remain unknown.
        diagnostic(value,parent,not known)
        if not known: result['unknown_node_count'] += 1
        children = value.get('children')
        if children is not None:
            if not isinstance(children,list): result['unknown_node_count'] += 1
            else: walk(children,next_parent,kind,depth+1)
        # No nested node or alternate run tree can hide under an unreviewed key.
        if any(isinstance(child,(dict,list)) for key,child in value.items() if key != 'children'):
            result['unknown_node_count'] += 1
    walk(tree['testNodes'])
    result['visited_nodes'] = node_count
    result['argument_names_distinct_by_parent'] = {name:name not in duplicate_arguments and len(names) == 2 for name,names in argument_names.items()}
    if seen != set(METHODS) or result['unexpected_test_definitions'] or result['unknown_node_count']: return result
    for row in result['definition_rows']:
        if not METHODS[row['method']]:
            result['argument_leaf_rows'].append({'method':row['method'],'ordinal':1,'status':row['status']})
    if (duplicate_arguments or not all(result['argument_names_distinct_by_parent'].values())
        or any(sum(row['method'] == name for row in result['argument_leaf_rows']) != (2 if labels else 1) for name,labels in METHODS.items())):
        result['status'] = 'argument_leaf_inventory_unknown'; return result
    for definition in result['definition_rows']:
        statuses = [row['status'] for row in result['argument_leaf_rows'] if row['method'] == definition['method']]
        aggregate = 'Failed' if 'Failed' in statuses else 'Skipped' if 'Skipped' in statuses else 'Passed'
        if definition['status'] != aggregate:
            result['status'] = 'definition_argument_status_mismatch'; return result
    def counts(rows):
        data = dict.fromkeys(COUNT_KEYS,0); data['totalTestCount'] = len(rows)
        for row in rows: data[STATUS_KEYS[row['status']]] += 1
        return data
    result['definition_counts'] = counts(result['definition_rows'])
    result['argument_leaf_counts'] = counts(result['argument_leaf_rows'])
    if not isinstance(summary,dict) or not all(type(summary.get(k)) is int and summary[k] >= 0 for k in COUNT_KEYS): return result
    original = {k:summary[k] for k in COUNT_KEYS}
    if original['totalTestCount'] != sum(original[k] for k in COUNT_KEYS[1:]): return result
    # Actual Xcode26.6.2 measurements report three definitions, not five leaves.
    if result['definition_counts'] == original:
        result['summary_count_basis'] = 'definition'; result['status'] = 'complete'
    else: result['status'] = 'definition_summary_count_mismatch'
    return result


def parser_controls():
    def argument(name,status='Passed'):
        return {'nodeType':'Arguments','name':name,'duration':'0.1s','durationInSeconds':0.1,'result':status}
    def definition(name,status='Passed'):
        node = {'nodeType':'Test Case','nodeIdentifier':SUITE+'/'+name+'('+METHODS[name]+')','result':status}
        if METHODS[name]: node['children'] = [argument('synthetic-appearance-a',status),argument('synthetic-appearance-b',status)]
        return node
    def sample():
        return {'testNodes':[{'nodeType':'Test Plan','children':[{'nodeType':'Unit test bundle','children':[
            {'nodeType':'Test Suite','children':[definition(name) for name in METHODS]}]}]}]}
    def cases(value): return value['testNodes'][0]['children'][0]['children'][0]['children']
    tree = sample(); summary = dict(totalTestCount=3,passedTests=3,failedTests=0,skippedTests=0)
    row = native_inventory(tree,summary)
    require(row['status'] == 'complete' and row['definition_counts']['passedTests'] == 3
        and row['argument_leaf_counts']['passedTests'] == 5 and row['summary_count_basis'] == 'definition','observed-three-definitions-five-distinct-leaves')
    failure = sample(); target = next(row for row in cases(failure) if source_method(row['nodeIdentifier']) == TARGET)
    target['result'] = 'Failed'
    for child in target['children']: child['result'] = 'Failed'
    failed_summary = dict(totalTestCount=3,passedTests=2,failedTests=1,skippedTests=0)
    row = native_inventory(failure,failed_summary)
    require(row['status'] == 'complete' and row['argument_leaf_counts']['passedTests'] == 3
        and row['argument_leaf_counts']['failedTests'] == 2,'observed-parameterized-failure-counts-kept-separate')
    bad = []
    def altered(change):
        value = sample(); change(value); bad.append(value)
    altered(lambda value:cases(value).pop())
    altered(lambda value:cases(value).append(copy.deepcopy(cases(value)[0])))
    altered(lambda value:cases(value)[0]['children'].pop())
    altered(lambda value:cases(value)[0]['children'].append(argument('third-distinct')))
    altered(lambda value:cases(value)[0]['children'][1].update(name='synthetic-appearance-a'))
    altered(lambda value:cases(value)[0]['children'][0].update(nodeType='Test Case Run'))
    altered(lambda value:cases(value)[0]['children'][0].update(children=[]))
    altered(lambda value:cases(value)[0]['children'][0].pop('duration'))
    altered(lambda value:cases(value)[0]['children'][0].update(extra='DO_NOT_EXPORT_VALUE'))
    altered(lambda value:cases(value)[0]['children'][0].update(result='Unknown'))
    altered(lambda value:cases(value)[0]['children'][0].update(result={}))
    altered(lambda value:cases(value)[0]['children'][0].update(name=None))
    altered(lambda value:cases(value)[0]['children'][0].update(name=''))
    altered(lambda value:cases(value)[0]['children'][0].update(durationInSeconds=True))
    altered(lambda value:cases(value)[0]['children'][0].update(duration={}))
    altered(lambda value:cases(value)[0].update(nodeIdentifier='PRIVATE_VALUE'))
    altered(lambda value:cases(value)[0].update(nodeType={}))
    altered(lambda value:cases(value)[0].update(result={}))
    altered(lambda value:cases(value)[1].update(children=[argument('synthetic-appearance-a')]))
    altered(lambda value:cases(value)[0].update(children=[{'nodeType':'Test Suite','children':cases(value)[0]['children']}]))
    altered(lambda value:cases(value)[0].update(children=[copy.deepcopy(cases(value)[0])]))
    altered(lambda value:cases(value)[0]['children'][0].update(nodeType='UnapprovedPrivateType'))
    altered(lambda value:cases(value)[0].update(result='Failed'))
    for value in bad: require(native_inventory(value,summary)['status'] != 'complete','no-unobserved-or-duplicate-execution-schema')
    for wrong in [dict(summary,totalTestCount=True),dict(totalTestCount=5,passedTests=5,failedTests=0,skippedTests=0),
        dict(totalTestCount=3,passedTests=2,failedTests=0,skippedTests=1)]:
        require(native_inventory(tree,wrong)['status'] != 'complete','native-definition-summary-source-remains-exact')
    row = native_inventory(tree,summary)
    require('synthetic-appearance-a' not in json.dumps(row) and 'synthetic-appearance-b' not in json.dumps(row), 'no-argument-name-or-internal-hash-export')
    private_type = sample(); cases(private_type)[0]['children'][0]['nodeType'] = 'UnapprovedPrivateType'
    require('UnapprovedPrivateType' not in json.dumps(native_inventory(private_type,summary)), 'unapproved-type-hash-only')
    require(binary_placement(('Debug','White Noise Unit Host.app'),'app') == 'debug_isolated_app','known-app-placement')
    require(binary_placement(('Debug','whitenoise-macTests.xctest'),'test') == 'debug_standalone_unit_test_bundle','known-standalone-placement')
    require(binary_placement(('Debug','White Noise Unit Host.app','Contents','PlugIns','whitenoise-macTests.xctest'),'test') == 'debug_isolated_app_plugins_unit_test_bundle','known-plugin-placement')
    require(binary_placement(('PRIVATE_DIRECTORY','whitenoise-macTests.xctest'),'test') == 'other_owned_products_placement','unknown-placement-remains-unknown')
    return {'observed_schema_positive':2,'execution_schema_negative':len(bad),'summary_negative':3,
        'privacy_controls':2,'placement_controls':4,'runtime_bodies':0,'schema_fixtures_not_actual_execution':True}


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


def bounded_capture(command,environment,timeout,limit,private_log=None):
    """In-flight combined output cap; only this command's own process group."""
    process = subprocess.Popen(command,env=environment,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True)
    selector = selectors.DefaultSelector(); selector.register(process.stdout,selectors.EVENT_READ)
    deadline = time.monotonic() + timeout; data = bytearray(); received = 0
    state = {'exit_code':None,'watchdog_triggered':False,'output_limit_triggered':False,'captured_bytes':0}
    stream = private_log.open('xb') if private_log is not None else None
    def stop():
        try: os.killpg(process.pid,signal.SIGTERM)
        except ProcessLookupError: pass
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                state['watchdog_triggered'] = True; stop(); break
            ready = selector.select(min(remaining,1))
            for key,_ in ready:
                chunk = os.read(key.fileobj.fileno(),65536)
                if not chunk:
                    selector.unregister(key.fileobj); continue
                if received + len(chunk) > limit:
                    state['output_limit_triggered'] = True; stop(); break
                received += len(chunk)
                if stream is not None: stream.write(chunk)
                else: data.extend(chunk)
            if state['output_limit_triggered']: break
        if not state['watchdog_triggered'] and not state['output_limit_triggered']:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                state['watchdog_triggered'] = True; stop()
            else:
                try: state['exit_code'] = process.wait(timeout=remaining)
                except subprocess.TimeoutExpired:
                    state['watchdog_triggered'] = True; stop()
        state['captured_bytes'] = received
        return state,bytes(data)
    finally:
        if process.poll() is None: stop()
        selector.close(); process.stdout.close()
        if stream is not None: stream.close()


def binary_placement(parts,role):
    if role == 'app' and tuple(parts) == ('Debug','White Noise Unit Host.app'):
        return 'debug_isolated_app'
    if role == 'test' and tuple(parts) == ('Debug','whitenoise-macTests.xctest'):
        return 'debug_standalone_unit_test_bundle'
    if role == 'test' and tuple(parts) == ('Debug','White Noise Unit Host.app','Contents','PlugIns','whitenoise-macTests.xctest'):
        return 'debug_isolated_app_plugins_unit_test_bundle'
    return 'other_owned_products_placement'


MACHO_MAGICS = {b'\xfe\xed\xfa\xce',b'\xce\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xcf\xfa\xed\xfe',
    b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca',b'\xca\xfe\xba\xbf',b'\xbf\xba\xfe\xca'}


def actual_macho_siblings(directory,expected_executable,safe_chain,products):
    names = {'executable':expected_executable,'debug_dylib':expected_executable + '.debug.dylib','preview_dylib':'__preview.dylib'}
    result = {'status':'unknown','images':{role:{'present':False,'sha256':None} for role in names},
        'unknown_macho_sibling_count':0,'uninspectable_sibling_count':0,'entries_examined':0}
    if not safe_chain(directory,products): return result
    try:
        # Bounded directory enumeration; never follow arbitrary sibling links.
        with os.scandir(directory) as entries:
            for entry in entries:
                result['entries_examined'] += 1
                if result['entries_examined'] > 32:
                    result['directory_limit_exceeded'] = True; return result
                path = Path(entry.path)
                role = next((role for role,name in names.items() if entry.name == name),None)
                if role is not None: result['images'][role]['present'] = True
                if entry.is_symlink():
                    result['uninspectable_sibling_count'] += 1; continue
                if not entry.is_file(follow_symlinks=False):
                    if role is not None: result['uninspectable_sibling_count'] += 1
                    continue
                if not safe_chain(path,products,regular=True):
                    result['uninspectable_sibling_count'] += 1; continue
                before = path.stat()
                with path.open('rb') as stream: magic = stream.read(4)
                macho = magic in MACHO_MAGICS
                if role is None:
                    if macho: result['unknown_macho_sibling_count'] += 1
                    continue
                image = result['images'][role]
                image['regular_nonsymlink'] = True; image['macho_header'] = macho
                if not macho or not 0 < before.st_size <= 1024**3:
                    result['uninspectable_sibling_count'] += 1; continue
                digest = hashlib.sha256()
                with path.open('rb') as stream:
                    for block in iter(lambda:stream.read(1024*1024),b''): digest.update(block)
                after = path.stat()
                unchanged = (before.st_size,before.st_mtime_ns,before.st_ino) == (after.st_size,after.st_mtime_ns,after.st_ino)
                if not unchanged:
                    result['uninspectable_sibling_count'] += 1; continue
                image.update(sha256=digest.hexdigest(),bytes=before.st_size,stable_during_hash=True)
    except OSError:
        result['uninspectable_sibling_count'] += 1; return result
    if result['unknown_macho_sibling_count'] or result['uninspectable_sibling_count']: return result
    if (result['images']['executable']['present'] and all(not image['present'] or image['sha256'] is not None for image in result['images'].values())):
        result['status'] = 'complete'
    return result


def actual_binary_inventory():
    derived = OUT / 'DerivedData'; products = derived / 'Build/Products'
    result = {'status':'unknown','search_root':'owned_DerivedData_Build_Products',
        'search_complete':False,'roles':{'app':{'candidate_count':0,'records':[]},'test':{'candidate_count':0,'records':[]}}}
    def safe_chain(path,root,regular=False):
        try:
            relative = path.relative_to(root)
            if root.is_symlink() or not root.is_dir(): return False
            cursor = root
            for part in relative.parts:
                cursor = cursor / part
                if cursor.is_symlink(): return False
            if not path.resolve(strict=True).is_relative_to(root.resolve(strict=True)): return False
            return stat.S_ISREG(path.lstat().st_mode) if regular else path.is_dir()
        except (OSError,ValueError): return False
    if not safe_chain(products,derived): return result
    known = {'app':('White Noise Unit Host.app','White Noise Unit Host','dev.ipf.whitenoise.mac.tests'),
        'test':('whitenoise-macTests.xctest','whitenoise-macTests','dev.ipf.whitenoise-macTests')}
    visited = 0; candidates = {'app':[],'test':[]}
    for directory,dirs,_ in os.walk(products,followlinks=False):
        visited += 1
        if visited > 10000 or len(Path(directory).relative_to(products).parts) > 16:
            result['search_limit_exceeded'] = True; return result
        retained = []
        for name in dirs:
            path = Path(directory) / name
            for role,(bundle,_,_) in known.items():
                if name == bundle: candidates[role].append(path)
            if path.is_symlink() or name.endswith(('.framework','.xcframework','.bundle','.dSYM','.xctest')): continue
            retained.append(name)
        dirs[:] = retained
    result['search_complete'] = True; result['visited_directories'] = visited
    for role,paths in candidates.items():
        bucket = result['roles'][role]; bucket['candidate_count'] = len(paths)
        if len(paths) > 16:
            bucket['candidate_records_truncated'] = True; continue
        _,expected_executable,expected_identifier = known[role]
        for path in paths:
            record = {'placement':binary_placement(path.relative_to(products).parts,role),'status':'unknown',
                'bundle_chain_nonsymlink':safe_chain(path,products),'plist_regular_nonsymlink':False,
                'known_executable':False,'known_bundle_identifier':False,'executable_regular_nonsymlink':False,'sha256':None}
            bucket['records'].append(record)
            info = path / 'Contents/Info.plist'
            if not record['bundle_chain_nonsymlink'] or not safe_chain(info,products,regular=True): continue
            record['plist_regular_nonsymlink'] = True
            if info.stat().st_size > 1024*1024: continue
            try: metadata = plistlib.loads(info.read_bytes())
            except (OSError,ValueError,plistlib.InvalidFileException): continue
            if not isinstance(metadata,dict): continue
            executable = metadata.get('CFBundleExecutable')
            record['known_executable'] = executable == expected_executable
            record['known_bundle_identifier'] = metadata.get('CFBundleIdentifier') == expected_identifier
            if not record['known_executable'] or not record['known_bundle_identifier']: continue
            binary = path / 'Contents/MacOS' / expected_executable
            record['executable_regular_nonsymlink'] = safe_chain(binary,products,regular=True)
            if not record['executable_regular_nonsymlink']: continue
            record['executable_mode'] = bool(binary.lstat().st_mode & 0o111)
            if not record['executable_mode']: continue
            digest = hashlib.sha256()
            with binary.open('rb') as stream:
                for block in iter(lambda:stream.read(1024*1024),b''): digest.update(block)
            record['sha256'] = digest.hexdigest()
            record['macho_images'] = actual_macho_siblings(path/'Contents/MacOS',expected_executable,safe_chain,products)
            if (record['placement'] != 'other_owned_products_placement' and record['macho_images']['status'] == 'complete'
                and record['macho_images']['images']['executable']['sha256'] == record['sha256']): record['status'] = 'known'
    if all(bucket['candidate_count'] == 1 and len(bucket['records']) == 1 and bucket['records'][0]['status'] == 'known'
        for bucket in result['roles'].values()): result['status'] = 'complete'
    return result


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
    capture,_ = bounded_capture(command,environment,1800,64*1024*1024,private_log=log)
    row.update(capture)
    row['wall_seconds'] = round(time.monotonic()-start,3); row['bundle_exists'] = bundle.exists(); save()
    require(fingerprint() == expected,'after-runtime-source-mode-pristine')
    if not bundle.exists() or row.get('watchdog_triggered') or row.get('output_limit_triggered'): return row
    exports = {}
    for kind in ['summary','tests']:
        try:
            capture,data = bounded_capture(['xcrun','xcresulttool','get','test-results',kind,'--path',str(bundle)],environment,90,8*1024*1024)
            row.setdefault('native_export_capture',{})[kind] = capture; save()
            require(capture['exit_code'] == 0 and not capture['watchdog_triggered'] and not capture['output_limit_triggered'],'bounded-native-export')
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
    row['binary_inventory'] = actual_binary_inventory()
    row['binaries'] = {role:bucket['records'][0]['sha256'] for role,bucket in row['binary_inventory']['roles'].items()
        if bucket['candidate_count'] == 1 and len(bucket['records']) == 1 and bucket['records'][0]['status'] == 'known'}
    row['actual_image_inventory'] = {role:bucket['records'][0]['macho_images']['images'] for role,bucket in row['binary_inventory']['roles'].items()
        if bucket['candidate_count'] == 1 and len(bucket['records']) == 1 and bucket['records'][0]['status'] == 'known'}
    if inventory['status'] == 'complete' and row['build_succeeded'] and row['sdk']['actual_resolved_frameworks']:
        definitions = inventory['definition_rows']; leaves = inventory['argument_leaf_rows']
        row['green'] = (row['exit_code'] == 0 and all(v['status'] == 'Passed' for v in definitions+leaves)
            and not issue_lines and row['binary_inventory']['status'] == 'complete' and set(row['binaries']) == {'app','test'})
        row['counterfactual_RED'] = (row['exit_code'] not in {None,0} and not row.get('watchdog_triggered')
            and all(v['status'] == ('Failed' if v['method'] == TARGET else 'Passed') for v in definitions+leaves)
            and len(locations) == len(issue_lines) == 2 and all(v['expectation_failure'] and 63 <= v['line'] <= 66 for v in locations)
            and row['binary_inventory']['status'] == 'complete' and set(row['binaries']) == {'app','test'})
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
            require(a['binaries'] == c['binaries'] and a['actual_image_inventory'] == c['actual_image_inventory']
                and a['actual_image_inventory'] != b['actual_image_inventory'],'actual-whole-image-restoration-required')
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
