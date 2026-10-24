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
from pathlib import Path, PurePosixPath
import subprocess
import shutil
import zipfile
import urllib.parse

BASE = '2a60df8f95245328b43b324c325a31540b2488e5'
PREVIOUS = '5db1dc879149ec8b168baa24cb860d8d32b9c02e'
SELF = 'scripts/ci/shared-ui-qualification.py'
WORKFLOW = '.github/workflows/mac-ci.yml'
BEGIN = '  # SHARED_UI_FORMAT_JOBS_BEGIN\n'
END = '  # SHARED_UI_FORMAT_JOBS_END\n'
OPTIONS = 'options: [full, onboarding-mutations, shared-ui-format, shared-ui-raster-measure, shared-ui-raster-red-green, shared-ui-raster-pfp, shared-ui-cli-schema, shared-ui-native-calibration, shared-ui-archive-summary]'
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
        'argument_names_distinct_by_parent':{},'failed_argument_message_count':0,'_private_failure_message_hashes':[]}
    if not isinstance(tree,dict) or not isinstance(tree.get('testNodes'),list): return result
    seen = set(); argument_names = {name:set() for name,labels in METHODS.items() if labels}
    duplicate_arguments = set(); node_count = 0
    containers = {'Test Plan','Device','Test Bundle','Unit test bundle','Test Suite'}
    diagnostic_types = containers | {'Test Case','Test Case Run','Arguments','Argument','Test Argument','Test Iteration','Repetition','Test Case Group','Failure Message'}
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
            failed_message = None
            keys = argument_keys | {'children'} if status == 'Failed' else argument_keys
            children = value.get('children')
            failure_child_known = status != 'Failed'
            if status == 'Failed' and isinstance(children,list) and len(children) == 1:
                child = children[0]
                if (isinstance(child,dict) and set(child) == {'nodeType','name'} and child.get('nodeType') == 'Failure Message'
                    and isinstance(child.get('name'),str) and 0 < len(child['name'].encode()) <= 1024*1024):
                    failed_message = child['name']; failure_child_known = True
            valid = (set(value) == keys and failure_child_known and parent_kind == 'Test Case' and parent in argument_names
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
                    if failed_message is not None:
                        result['failed_argument_message_count'] += 1
                        result['_private_failure_message_hashes'].append(hashlib.sha256(failed_message.encode()).hexdigest())
        elif isinstance(kind,str) and kind in containers:
            known = parent is None
        # Test Case Run and every other unobserved execution schema remain unknown.
        diagnostic(value,parent,not known)
        if not known: result['unknown_node_count'] += 1
        children = value.get('children')
        if children is not None:
            if not isinstance(children,list): result['unknown_node_count'] += 1
            elif kind == 'Arguments' and known and status == 'Failed':
                # Exactly one observed Failure Message was checked above; it is a diagnostic, never an execution leaf.
                for child in children: diagnostic(child,parent)
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
    for child in target['children']:
        child['result'] = 'Failed'; child['children'] = [{'nodeType':'Failure Message','name':'SYNTHETIC_CALIBRATED_NATIVE_FAILURE_DISPLAY'}]
    failed_summary = dict(totalTestCount=3,passedTests=2,failedTests=1,skippedTests=0)
    row = native_inventory(failure,failed_summary)
    require(row['status'] == 'complete' and row['argument_leaf_counts']['passedTests'] == 3
        and row['argument_leaf_counts']['failedTests'] == 2,'observed-parameterized-failure-counts-kept-separate')
    failed_bad = []
    def bad_failure(change):
        value = copy.deepcopy(failure); change(next(row for row in cases(value) if source_method(row['nodeIdentifier']) == TARGET)['children'][0]); failed_bad.append(value)
    bad_failure(lambda child:child.pop('children'))
    bad_failure(lambda child:child['children'].append(copy.deepcopy(child['children'][0])))
    bad_failure(lambda child:child['children'][0].update(nodeType='Source Code Reference'))
    bad_failure(lambda child:child['children'][0].update(name=None))
    bad_failure(lambda child:child['children'][0].update(name=''))
    bad_failure(lambda child:child['children'][0].update(children=[]))
    bad_failure(lambda child:child.update(result='Passed'))
    for value in failed_bad: require(native_inventory(value,failed_summary)['status'] != 'complete','strict-observed-failure-message-child')
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
    row = native_inventory(tree,summary); row.pop('_private_failure_message_hashes',None)
    require('synthetic-appearance-a' not in json.dumps(row) and 'synthetic-appearance-b' not in json.dumps(row), 'no-argument-name-or-internal-hash-export')
    private_type = sample(); cases(private_type)[0]['children'][0]['nodeType'] = 'UnapprovedPrivateType'
    require('UnapprovedPrivateType' not in json.dumps(native_inventory(private_type,summary)), 'unapproved-type-hash-only')
    require(binary_placement(('Debug','White Noise Unit Host.app'),'app') == 'debug_isolated_app','known-app-placement')
    require(binary_placement(('Debug','whitenoise-macTests.xctest'),'test') == 'debug_standalone_unit_test_bundle','known-standalone-placement')
    require(binary_placement(('Debug','White Noise Unit Host.app','Contents','PlugIns','whitenoise-macTests.xctest'),'test') == 'debug_isolated_app_plugins_unit_test_bundle','known-plugin-placement')
    require(binary_placement(('PRIVATE_DIRECTORY','whitenoise-macTests.xctest'),'test') == 'other_owned_products_placement','unknown-placement-remains-unknown')
    return {'observed_schema_positive':2,'execution_schema_negative':len(bad),'failed_argument_schema_negative':len(failed_bad),'summary_negative':3,
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


def legacy_type(value,name):
    return isinstance(value,dict) and isinstance(value.get('_type'),dict) and value['_type'].get('_name') == name


def legacy_string(value,limit):
    if not legacy_type(value,'String') or not isinstance(value.get('_value'),str) or len(value['_value'].encode()) > limit:
        raise ValueError('closed-legacy-string-shape')
    return value['_value']


def legacy_array(value):
    if not legacy_type(value,'Array') or not isinstance(value.get('_values',[]),list) or len(value.get('_values',[])) > 64:
        raise ValueError('bounded-legacy-array-shape')
    return value.get('_values',[])


def legacy_case_method(value):
    if not isinstance(value,str) or len(value.encode()) > 2048: return None
    for prefix in ['whitenoise-macTests.','whitenoise_macTests.','whitenoise-macTests/','whitenoise_macTests/']:
        if value.startswith(prefix): value = value[len(prefix):]; break
    # Native issue identity retains the exact known suite+source method; parameter display values remain internal.
    for name,labels in METHODS.items():
        for separator in ['.','/']:
            base = SUITE + separator + name
            if value == base + '(' + labels + ')': return name
            if labels and value.startswith(base + '(' + labels) and value.endswith(')') and '\n' not in value and '\r' not in value:
                return name
    return None


def native_document_location(value):
    row = {'status':'unknown','file':None,'starting_line':None,'ending_line':None,
        'starting_column':None,'ending_column':None,'only_original_shared_assertion':False,
        'coordinate_source':'unmodified_native_DocumentLocation_fragment_no_offset_conversion',
        'typed_document_location':False,'file_scheme':False,'known_file_suffix':False,'fragment_key_count':None,
        'known_fragment_keys':[],'other_fragment_key_count':None}
    try:
        if not legacy_type(value,'DocumentLocation'): return row
        row['typed_document_location'] = True
        url = legacy_string(value.get('url'),4096)
        legacy_string(value.get('concreteTypeName'),256)  # Type name is validated, never exported.
        parsed = urllib.parse.urlsplit(url)
        path = urllib.parse.unquote(parsed.path)
        row['file_scheme'] = parsed.scheme == 'file'
        row['known_file_suffix'] = path.endswith('/' + TEST)
        if (parsed.scheme != 'file' or parsed.netloc not in {'','localhost'} or parsed.query
            or not path.endswith('/' + TEST) or '..' in Path(path).parts or '%' in path): return row
        row['file'] = TEST
        fields = urllib.parse.parse_qs(parsed.fragment,keep_blank_values=True,strict_parsing=True)
        allowed = {'StartingLineNumber','EndingLineNumber','StartingColumnNumber','EndingColumnNumber','CharacterRangeLoc','CharacterRangeLen'}
        row['fragment_key_count'] = len(fields)
        row['known_fragment_keys'] = sorted(set(fields)&allowed)
        row['other_fragment_key_count'] = len(set(fields)-allowed)
        if set(fields)-allowed or not {'StartingLineNumber','EndingLineNumber'} <= set(fields): return row
        for key,values in fields.items():
            if len(values) != 1 or re.fullmatch(r'[0-9]{1,8}',values[0]) is None: return row
        row['starting_line'] = int(fields['StartingLineNumber'][0]); row['ending_line'] = int(fields['EndingLineNumber'][0])
        for source,target in [('StartingColumnNumber','starting_column'),('EndingColumnNumber','ending_column')]:
            if source in fields: row[target] = int(fields[source][0])
        row['status'] = 'known_source_url'
        row['only_original_shared_assertion'] = 63 <= row['starting_line'] <= row['ending_line'] <= 66
    except (ValueError,UnicodeError): pass
    return row


def legacy_native_issues(document):
    report = {'status':'schema_unknown','issues':[],'unknown_issue_count':0,'root_error_summary_count':None,
        'test_failure_summary_count':None,'source_site_RED_proven':False,'no_native_failure_issues':False,
        'raw_messages_URLs_values_or_argument_names_exported':False}
    payloads = []
    try:
        if not legacy_type(document,'ActionsInvocationRecord') or not legacy_type(document.get('issues'),'ResultIssueSummaries'):
            return report,payloads
        issues = document['issues']
        errors = legacy_array(issues['errorSummaries']) if 'errorSummaries' in issues else []
        failures = legacy_array(issues['testFailureSummaries']) if 'testFailureSummaries' in issues else []
        report['root_error_summary_count'] = len(errors); report['test_failure_summary_count'] = len(failures)
        report['test_failure_array_field_present'] = 'testFailureSummaries' in issues
        report['error_summary_array_field_present'] = 'errorSummaries' in issues
        for value in failures:
            row = {'typed_test_failure':False,'method':None,'expectation_failed':False,'producing_target_known':False,'native_source':None,'known':False}
            report['issues'].append(row)
            try:
                if not legacy_type(value,'TestFailureIssueSummary'): raise ValueError('typed-native-test-failure-required')
                row['typed_test_failure'] = True
                row['known_issue_keys'] = sorted(set(value)&{'_type','issueType','message','testCaseName','producingTarget','documentLocationInCreatingWorkspace','compactMessage'})
                row['other_issue_key_count'] = len(set(value)-set(row['known_issue_keys']))
                message = legacy_string(value.get('message'),1024*1024)
                issue_type = legacy_string(value.get('issueType'),256)
                row['issue_class'] = issue_type if issue_type in {'Assertion Failure','Swift Testing Failure','Uncategorized'} else 'other_native_issue_class'
                row['expectation_failed'] = message.startswith('Expectation failed:')
                row['method'] = legacy_case_method(legacy_string(value.get('testCaseName'),2048))
                target = value.get('producingTarget')
                row['producing_target_known'] = target is None or legacy_string(target,256) in {'whitenoise-macTests','whitenoise_macTests'}
                row['native_source'] = native_document_location(value.get('documentLocationInCreatingWorkspace'))
                row['known'] = (row['method'] == TARGET and row['issue_class'] in {'Assertion Failure','Swift Testing Failure'} and row['expectation_failed'] and row['producing_target_known']
                    and row['native_source']['status'] == 'known_source_url' and row['native_source']['only_original_shared_assertion'])
                if row['known']: payloads.append(hashlib.sha256(message.encode()).hexdigest())
            except ValueError: pass
            if not row['known']: report['unknown_issue_count'] += 1
        report['status'] = 'complete' if not report['unknown_issue_count'] else 'unknown_native_issue'
        report['no_native_failure_issues'] = report['status'] == 'complete' and not errors and not failures
        report['source_site_RED_proven'] = (report['status'] == 'complete' and not errors and len(failures) == len(payloads) == 2)
    except ValueError: pass
    return report,payloads


def modern_details_shape(document):
    result = {'status':'unknown','known_test_identity':False,'node_type_counts':{},'source_reference_shapes':[],
        'source_locations_interpreted':False,'raw_names_details_values_exported':False}
    if not isinstance(document,dict): return result
    result['known_test_identity'] = source_method(document.get('testIdentifier')) == TARGET
    if not isinstance(document.get('testRuns'),list): return result
    known_types = {'Test Plan','Unit test bundle','UI test bundle','Test Suite','Test Case','Device','Test Plan Configuration',
        'Arguments','Repetition','Test Case Run','Failure Message','Source Code Reference','Attachment','Expression','Test Value','Runtime Warning'}
    pending = [(document['testRuns'],0)]; visited = 0
    while pending:
        value,depth = pending.pop(); visited += 1
        if visited > 20000 or depth > 48: result['status'] = 'schema_limit'; return result
        if isinstance(value,list): pending.extend((v,depth+1) for v in value)
        elif isinstance(value,dict):
            kind = value.get('nodeType')
            category = kind if isinstance(kind,str) and kind in known_types else 'unknown_type'
            result['node_type_counts'][category] = result['node_type_counts'].get(category,0) + 1
            if kind == 'Source Code Reference' and len(result['source_reference_shapes']) < 16:
                keys = {'nodeIdentifier','nodeIdentifierURL','nodeType','name','details','duration','durationInSeconds','result','tags','children'}
                result['source_reference_shapes'].append({'known_keys':sorted(set(value)&keys),'other_key_count':len(set(value)-keys)})
            pending.extend((child,depth+1) for child in value.values() if isinstance(child,(dict,list)))
    result['status'] = 'closed_shape_only'; return result


def native_issue_exports(bundle,environment,row,save):
    closed = {'legacy':{'status':'export_unknown','source_site_RED_proven':False,'no_native_failure_issues':False},
        'modern_details':{'status':'export_unknown'},'capture':{},'message_representation_comparison':'not_yet_compared',
        'message_equality_is_qualification_gate':False}
    row['native_issue_provenance'] = closed; save()
    hashes = []
    commands = [
        ('legacy',['xcrun','xcresulttool','get','object','--legacy','--format','json','--path',str(bundle)],4*1024*1024),
        ('modern_details',['xcrun','xcresulttool','get','test-results','test-details','--path',str(bundle),'--test-id',SUITE+'/'+TARGET+'(appearance:)'],2*1024*1024),
    ]
    for label,command,limit in commands:
        capture,data = bounded_capture(command,environment,90,limit)
        closed['capture'][label] = capture; save()
        if capture['exit_code'] != 0 or capture['watchdog_triggered'] or capture['output_limit_triggered']: continue
        try:
            document = json.loads(data)
            if label == 'legacy':
                closed['legacy'],hashes = legacy_information_only(document)
                calibration_legacy_walk(bundle,document,environment,save,None,app_row=row)
            else: closed['modern_details'] = modern_details_shape(document)
        except (ValueError,UnicodeError): closed[label]['status'] = 'json_schema_unknown'
        save()  # Closed actual issue facts persist BEFORE test-tree/oracle parsing.
    return hashes


def native_issue_parser_controls():
    def string(value): return {'_type':{'_name':'String'},'_value':value}
    def array(values): return {'_type':{'_name':'Array'},'_values':values}
    def issue():
        return {'_type':{'_name':'TestFailureIssueSummary'},'issueType':string('Assertion Failure'),
            'message':string('Expectation failed: SYNTHETIC_PRIVATE_VALUE'),
            'testCaseName':string(SUITE+'.'+TARGET+'(appearance:)'),'producingTarget':string('whitenoise-macTests'),
            'documentLocationInCreatingWorkspace':{'_type':{'_name':'DocumentLocation'},
                'concreteTypeName':string('DVTTextDocumentLocation'),
                'url':string('file:///synthetic-checkout/'+TEST+'#StartingLineNumber=63&EndingLineNumber=66')}}
    def document(values):
        return {'_type':{'_name':'ActionsInvocationRecord'},'issues':{'_type':{'_name':'ResultIssueSummaries'},
            'testFailureSummaries':array(values),'errorSummaries':array([])}}
    good = document([issue(),issue()]); report,hashes = legacy_native_issues(good)
    require(report['source_site_RED_proven'] and len(hashes) == 2,'typed-two-native-expectations-positive')
    empty,_ = legacy_native_issues(document([])); require(empty['no_native_failure_issues'],'native-empty-control-positive')
    bad = []
    def altered(change):
        value = copy.deepcopy(good); change(value); bad.append(value)
    def failures(value): return value['issues']['testFailureSummaries']['_values']
    altered(lambda value:failures(value).pop())
    altered(lambda value:failures(value).append(issue()))
    altered(lambda value:failures(value)[0]['message'].update(_value='Other failure: SYNTHETIC_PRIVATE_VALUE'))
    altered(lambda value:failures(value)[0]['testCaseName'].update(_value='ForeignSuite.'+TARGET+'(appearance:)'))
    altered(lambda value:failures(value)[0]['producingTarget'].update(_value='ForeignTarget'))
    altered(lambda value:failures(value)[0]['documentLocationInCreatingWorkspace']['url'].update(_value='file:///synthetic/'+TEST+'#StartingLineNumber=60&EndingLineNumber=62'))
    altered(lambda value:failures(value)[0]['documentLocationInCreatingWorkspace']['url'].update(_value='file:///synthetic/'+TEST+'#StartingLineNumber=55&EndingLineNumber=59'))
    altered(lambda value:failures(value)[0]['documentLocationInCreatingWorkspace']['url'].update(_value='file:///synthetic/Foreign.swift#StartingLineNumber=63&EndingLineNumber=66'))
    altered(lambda value:failures(value)[0]['documentLocationInCreatingWorkspace']['url'].update(_value='https://private.invalid/'+TEST+'#StartingLineNumber=63&EndingLineNumber=66'))
    altered(lambda value:failures(value)[0]['documentLocationInCreatingWorkspace']['url'].update(_value='file:///synthetic/'+TEST+'#StartingLineNumber=63&StartingLineNumber=64&EndingLineNumber=66'))
    altered(lambda value:failures(value)[0]['documentLocationInCreatingWorkspace'].pop('url'))
    altered(lambda value:failures(value)[0]['documentLocationInCreatingWorkspace']['url'].update(_value='file:///synthetic/'+TEST+'#StartingLineNumber=63&EndingLineNumber=66&PRIVATE=1'))
    altered(lambda value:value['issues']['errorSummaries'].update(_values=[{'_type':{'_name':'IssueSummary'}}]))
    altered(lambda value:value['_type'].update(_name='ForeignObject'))
    altered(lambda value:value['issues'].update(errorSummaries=None))
    altered(lambda value:value['issues'].update(testFailureSummaries=None))
    altered(lambda value:failures(value)[0]['issueType'].update(_value='Unknown native class'))
    altered(lambda value:failures(value)[0]['issueType'].update(_value='Uncategorized'))
    for value in bad: require(not legacy_native_issues(value)[0]['source_site_RED_proven'],'no-false-native-issue-site-RED')
    require('SYNTHETIC_PRIVATE_VALUE' not in json.dumps(report) and 'synthetic-checkout' not in json.dumps(report),'no-private-native-issue-export')
    return {'positive':2,'negative':len(bad),'privacy':1,'runtime_bodies':0}


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
    exports = {}; legacy_message_hashes = []
    for kind in ['summary','tests']:
        try:
            capture,data = bounded_capture(['xcrun','xcresulttool','get','test-results',kind,'--path',str(bundle)],environment,90,8*1024*1024)
            row.setdefault('native_export_capture',{})[kind] = capture; save()
            require(capture['exit_code'] == 0 and not capture['watchdog_triggered'] and not capture['output_limit_triggered'],'bounded-native-export')
            exports[kind] = json.loads(data)
        except (subprocess.SubprocessError,ValueError):
            row['native_export_failed'] = kind; save(); return row
        if kind == 'summary':
            row['runtime_summary'] = summary_safe(exports[kind]); save()  # Actual counts precede every issue/inventory parser.
            legacy_message_hashes = native_issue_exports(bundle,environment,row,save)
    inventory = native_inventory(exports['tests'],exports['summary'])
    modern_message_hashes = inventory.pop('_private_failure_message_hashes',[])
    provenance = row['native_issue_provenance']
    provenance['message_representation_comparison'] = ('same_multiset' if sorted(legacy_message_hashes) == sorted(modern_message_hashes)
        else 'different_tool_representations') if legacy_message_hashes and modern_message_hashes else 'unknown_or_no_failures'
    provenance['legacy_known_message_count'] = len(legacy_message_hashes)
    provenance['modern_known_failure_message_count'] = len(modern_message_hashes)
    # Internal message hashes are discarded; source/target/counts qualify, serialization equality is informative only.
    row['runtime_inventory'] = inventory
    row['actual_runtime_counts_known'] = inventory['status'] == 'complete'; save()
    require(log.stat().st_size <= 64*1024*1024,'bounded-private-runtime-log')
    raw = log.read_text(errors='replace')
    # Only fixed source sites and static issue class survive; no assertion values or raster bytes.
    issue_lines = [line for line in raw.splitlines() if 'recorded an issue at ' in line]
    locations = []
    for line in issue_lines:
        match = re.search(r'MarkdownRendererParityTests\.swift:([0-9]+):([0-9]+):',line)
        if match: locations.append({'file':TEST,'line':int(match[1]),'column':int(match[2]),'expectation_failure':'Expectation failed' in line})
    row['console_issue_locations_are_diagnostic_only'] = True
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
            and row.get('typed_legacy_failure_sources',{}).get('no_native_failure_issues') is True and row['binary_inventory']['status'] == 'complete' and set(row['binaries']) == {'app','test'})
        row['counterfactual_RED'] = (row['exit_code'] not in {None,0} and not row.get('watchdog_triggered')
            and all(v['status'] == ('Failed' if v['method'] == TARGET else 'Passed') for v in definitions+leaves)
            and inventory['failed_argument_message_count'] == 2
            and row.get('typed_legacy_failure_sources',{}).get('source_site_RED_proven') is True
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


def cli_schema_metadata(result,save):
    output = OUT / 'cli-schema'; output.mkdir(parents=True,exist_ok=True)
    environment = dict(os.environ)
    commands = [
        ('format-description-get-help',['xcrun','xcresulttool','help','formatDescription','get'],256*1024),
        ('legacy-format-schema',['xcrun','xcresulttool','formatDescription','get','--legacy','--format','json'],2*1024*1024),
    ]
    result['cli_metadata'] = {'commands':{},'maximum_total_output_bytes':4*1024*1024,
        'App_build_or_test_executed':False,'SDK_consumed':False,'actual_native_schema_claim':False}
    total = 0
    for label,command,limit in commands:
        require(total + limit <= 4*1024*1024,'fixed-total-cli-output-cap')
        capture,data = bounded_capture(command,environment,30,limit)
        total += len(data)
        row = dict(capture,command=command,output_sha256=hashlib.sha256(data).hexdigest(),output_bytes=len(data),
            successful_static_CLI_output=capture['exit_code'] == 0 and not capture['watchdog_triggered'] and not capture['output_limit_triggered'])
        result['cli_metadata']['commands'][label] = row; save()
        # Static CLI help/schema only, no result-bundle path or private input supplied.
        try:
            text = data.decode('utf-8')
            require('\x00' not in text,'static-cli-text-only')
            (output/(label+'.txt')).write_text(text)
            try:
                document = json.loads(text)
                row['output_json'] = True
                row['top_level_JSON_kind'] = type(document).__name__
                if isinstance(document,dict): row['top_level_schema_keys'] = sorted(document)
            except ValueError: row['output_json'] = False
        except (UnicodeError,ValueError): row['output_text_unavailable'] = True
        row['supported_schema_export'] = label == 'legacy-format-schema' and row['successful_static_CLI_output'] and row.get('output_json') is True
        save()
    result['cli_metadata']['output_bytes'] = total
    result['cli_metadata']['capture_complete'] = all(not row['watchdog_triggered'] and not row['output_limit_triggered'] for row in result['cli_metadata']['commands'].values())
    result['cli_metadata']['unsupported_commands_are_closed_evidence'] = True
    save(); require(result['cli_metadata']['capture_complete'],'bounded-static-cli-capture-required')


CALIBRATION_SWIFT = '''import Testing

@Suite
struct NativeIssueCalibration {
    @Test
    func passingControl() {
        #expect(2 + 2 == 4)
    }

    @Test(arguments: [0, 1])
    func knownSourceFailure(value: Int) {
        #expect(value == 99)
    }
}
'''
CALIBRATION_FILE = 'NativeIssueCalibration.swift'
CALIBRATION_LINE = 12
CALIBRATION_PROJECT = '''// !$*UTF8*$!
{
 archiveVersion = 1;
 classes = {};
 objectVersion = 56;
 objects = {
  A00000000000000000000001 = { isa = PBXBuildFile; fileRef = A00000000000000000000002; };
  A00000000000000000000002 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = NativeIssueCalibration.swift; sourceTree = "<group>"; };
  A00000000000000000000003 = { isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = NativeIssueCalibration.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
  A00000000000000000000004 = { isa = PBXGroup; children = (A00000000000000000000002, A00000000000000000000005); sourceTree = "<group>"; };
  A00000000000000000000005 = { isa = PBXGroup; children = (A00000000000000000000003); name = Products; sourceTree = "<group>"; };
  A00000000000000000000006 = { isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
  A00000000000000000000007 = { isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
  A00000000000000000000008 = { isa = PBXNativeTarget; buildConfigurationList = A0000000000000000000000C; buildPhases = (A00000000000000000000006,A00000000000000000000007); buildRules = (); dependencies = (); name = NativeIssueCalibration; productName = NativeIssueCalibration; productReference = A00000000000000000000003; productType = "com.apple.product-type.bundle.unit-test"; };
  A00000000000000000000009 = { isa = PBXProject; attributes = { LastUpgradeCheck = 2600; }; buildConfigurationList = A0000000000000000000000B; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = A00000000000000000000004; productRefGroup = A00000000000000000000005; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000008); };
  A0000000000000000000000A = { isa = XCBuildConfiguration; buildSettings = { SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 15.0; }; name = Debug; };
  A0000000000000000000000B = { isa = XCConfigurationList; buildConfigurations = (A0000000000000000000000A); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
  A0000000000000000000000C = { isa = XCConfigurationList; buildConfigurations = (A0000000000000000000000D); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
  A0000000000000000000000D = { isa = XCBuildConfiguration; buildSettings = { CODE_SIGNING_ALLOWED = NO; CODE_SIGNING_REQUIRED = NO; GENERATE_INFOPLIST_FILE = YES; PRODUCT_BUNDLE_IDENTIFIER = org.example.NativeIssueCalibration; PRODUCT_NAME = NativeIssueCalibration; SWIFT_VERSION = 6.0; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; DEBUG_INFORMATION_FORMAT = dwarf; ENABLE_TESTABILITY = YES; TEST_HOST = ""; BUNDLE_LOADER = ""; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @loader_path/../Frameworks"; }; name = Debug; };
 };
 rootObject = A00000000000000000000009;
}
'''
CALIBRATION_SCHEME = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
 <BuildAction parallelizeBuildables="NO" buildImplicitDependencies="NO">
  <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000008" BuildableName="NativeIssueCalibration.xctest" BlueprintName="NativeIssueCalibration" ReferencedContainer="container:NativeIssueCalibration.xcodeproj"/>
  </BuildActionEntry></BuildActionEntries>
 </BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO">
  <Testables><TestableReference skipped="NO" parallelizable="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000008" BuildableName="NativeIssueCalibration.xctest" BlueprintName="NativeIssueCalibration" ReferencedContainer="container:NativeIssueCalibration.xcodeproj"/></TestableReference></Testables>
 </TestAction>
</Scheme>
'''


def calibration_string(value,limit=2048):
    return legacy_string(value,limit)


def calibration_integer(value):
    require(legacy_type(value,'Int') and isinstance(value.get('_value'),str)
        and re.fullmatch(r'[0-9]{1,8}',value['_value']) is not None,'calibration-typed-integer')
    return int(value['_value'])


def calibration_role(value):
    if not isinstance(value,str) or len(value.encode()) > 2048: return 'unknown'
    for role,name in [('failing_parameterized','knownSourceFailure(value:)'),('passing_control','passingControl()')]:
        if value in {name,'NativeIssueCalibration/'+name,'NativeIssueCalibration.'+name,'NativeIssueCalibration/NativeIssueCalibration/'+name}:
            return role
    return 'unknown'


def calibration_modern_details(document):
    report = {'known_target_identity':False,'nodes':[],'source_reference_count':0,
        'distinct_source_run_count':0,'unknown_node_count':0,'complete':False,
        'only_synthetic_fixed_file_suffixes_exported':True}
    if not isinstance(document,dict): return report
    report['known_target_identity'] = calibration_role(document.get('testIdentifier')) == 'failing_parameterized'
    pending = [(document.get('testRuns'),None,None,0)]; runs = set(); visited = 0
    known_types = {'Arguments','Test Case Run','Source Code Reference','Failure Message','Test Value','Expression'}
    while pending:
        value,parent,run,depth = pending.pop(); visited += 1
        if visited > 1024 or depth > 24: report['limit_reached'] = True; return report
        if isinstance(value,list):
            pending.extend((child,parent,run,depth+1) for child in reversed(value)); continue
        if not isinstance(value,dict): report['unknown_node_count'] += 1; continue
        kind = value.get('nodeType'); known_kind = isinstance(kind,str) and kind in known_types
        index = len(report['nodes']); status = value.get('result')
        row = {'index':index,'parent':parent,'type':kind if known_kind else 'unknown',
            'closed_result':status if isinstance(status,str) and status in STATUS_KEYS else 'unknown',
            'known_keys':sorted(set(value)&{'nodeType','name','children','result','duration','durationInSeconds','nodeIdentifier','details'}),
            'other_key_count':len(set(value)-{'nodeType','name','children','result','duration','durationInSeconds','nodeIdentifier','details'})}
        report['nodes'].append(row)
        if not known_kind: report['unknown_node_count'] += 1
        if kind == 'Test Case Run': run = index
        if kind == 'Source Code Reference':
            report['source_reference_count'] += 1; row['run_index'] = run
            name = value.get('name'); row['fixed_file_name_present'] = isinstance(name,str) and name.count(CALIBRATION_FILE) == 1
            # All calibration source is synthetic. Prefix paths are never exported; retain only bounded known-file suffix syntax.
            if row['fixed_file_name_present']:
                suffix = name.split(CALIBRATION_FILE,1)[1]
                if len(suffix) <= 256 and re.fullmatch(r'[A-Za-z0-9_:;()./#=& +\-]*',suffix): row['synthetic_source_suffix'] = suffix
                else: row['synthetic_source_suffix_unknown'] = True
            if run is not None: runs.add(run)
        children = value.get('children')
        if children is not None:
            if not isinstance(children,list): report['unknown_node_count'] += 1
            else: pending.append((children,index,run,depth+1))
    report['distinct_source_run_count'] = len(runs)
    report['complete'] = report['known_target_identity'] and report['source_reference_count'] == len(runs) == 2 and not report['unknown_node_count']
    return report


def calibration_summary_valid(summary):
    return isinstance(summary,dict) and all(type(summary.get(k)) is int and summary[k] == v
        for k,v in {'totalTestCount':2,'passedTests':1,'failedTests':1,'skippedTests':0}.items())


def calibration_sources_complete(report,pending):
    rows = report['typed_failure_sources']
    return (not pending and not report['unknown_shapes']
        and not any(report.get(flag) for flag in ['watchdog_reached','byte_limit_reached','reference_limit_reached','node_limit_reached'])
        and len(rows) == 2 and all(row['known_fixed_file'] and row['matches_literal_line'] and row['typed_record_uuid_present'] for row in rows))


def calibration_parser_controls():
    summary = dict(totalTestCount=2,passedTests=1,failedTests=1,skippedTests=0)
    require(calibration_summary_valid(summary),'calibration-exact-count-positive')
    bad_counts = []
    for key in COUNT_KEYS:
        for bad in [True,False,None,-1,'1']:
            bad_counts.append(dict(summary,**{key:bad}))
    for value in bad_counts: require(not calibration_summary_valid(value),'calibration-no-bool-null-counts')
    row = {'known_fixed_file':True,'matches_literal_line':True,'typed_record_uuid_present':True}
    report = {'typed_failure_sources':[dict(row),dict(row)],'unknown_shapes':0}
    require(calibration_sources_complete(report,False),'calibration-complete-sources-positive')
    negatives = 0
    for flag in ['watchdog_reached','byte_limit_reached','reference_limit_reached','node_limit_reached']:
        require(not calibration_sources_complete(dict(report,**{flag:True}),False),'calibration-truncation-never-complete'); negatives += 1
    require(not calibration_sources_complete(report,True),'calibration-pending-work-never-complete'); negatives += 1
    require(not calibration_sources_complete(dict(report,unknown_shapes=1),False),'calibration-unknown-source-never-complete'); negatives += 1
    require(not calibration_sources_complete(dict(report,typed_failure_sources=[dict(row)]),False),'calibration-exact-source-count'); negatives += 1
    details = {'testIdentifier':'NativeIssueCalibration/knownSourceFailure(value:)','testRuns':[
        {'nodeType':'Test Case Run','children':[{'nodeType':'Source Code Reference','name':'SYNTHETIC_PRIVATE_PREFIX/'+CALIBRATION_FILE+':12'}]},
        {'nodeType':'Test Case Run','children':[{'nodeType':'Source Code Reference','name':'SYNTHETIC_PRIVATE_PREFIX/'+CALIBRATION_FILE+':12'}]}]}
    observed = calibration_modern_details(details)
    require(observed['complete'],'calibration-two-distinct-runs-positive')
    require('SYNTHETIC_PRIVATE_PREFIX' not in json.dumps(observed),'calibration-no-source-prefix-export')
    bad_details = []
    value = copy.deepcopy(details); value['testRuns'][0]['children'].extend(value['testRuns'].pop()['children']); bad_details.append(value)
    value = copy.deepcopy(details); value['testRuns'][0]['nodeType'] = 'Unobserved'; bad_details.append(value)
    value = copy.deepcopy(details); value['testIdentifier'] = 'OtherSuite/knownSourceFailure(value:)'; bad_details.append(value)
    value = copy.deepcopy(details); value['testRuns'][0]['children'] = {}; bad_details.append(value)
    for value in bad_details: require(not calibration_modern_details(value)['complete'],'calibration-run-shape-failclosed')
    return {'positive':3,'count_negative':len(bad_counts),'source_completion_negative':negatives,
        'run_shape_negative':len(bad_details),'privacy':1,'actual_native_bodies':0}


def legacy_information_only(document):
    try:
        report,hashes = legacy_native_issues(document)
    except (ValueError,UnicodeError):
        report,hashes = {'status':'informational_export_rejected','source_site_RED_proven':False,'no_native_failure_issues':False},[]
    report['root_aggregate_is_informational_not_qualification_authority'] = True
    return report,hashes


def app_record_uuid(records,uuid,provenance):
    require(isinstance(uuid,str) and 0 < len(uuid.encode()) <= 256 and bool(uuid.strip()),'nonempty-typed-failure-uuid')
    if uuid in records:
        require(records[uuid] == provenance,'conflicting-native-failure-uuid-provenance')
        return False
    records[uuid] = provenance
    return True


def app_legacy_method(value):
    if not isinstance(value,str) or len(value.encode()) > 2048: return None
    known = source_method(value)
    if known is not None: return known
    for method,labels in METHODS.items():
        signature = method+'('+labels+')'
        if value in {signature,SUITE+'.'+signature,SUITE+'/'+SUITE+'/'+signature}: return method
    return None


def app_typed_route_known(report):
    if report.get('traversal_complete') is not True: return False
    objects = report.get('objects',[]); shapes = report.get('node_shapes',[])
    return (any(row.get('via') == 'ActionResult.testsRef' for row in objects)
        and any(row.get('type') == 'ActionTestPlanRunSummaries' and row.get('via') == 'referenced' for row in shapes)
        and {row.get('role') for row in shapes if row.get('type') == 'ActionTestMetadata'} == set(METHODS))


def app_typed_source_verdict(report):
    verdict = {'source_site_RED_proven':False,'no_native_failure_issues':False}
    if (not app_typed_route_known(report) or type(report.get('root_error_summary_count')) is not int
        or report['root_error_summary_count'] != 0 or not isinstance(report.get('typed_failure_sources'),list)): return verdict
    rows = report['typed_failure_sources']
    verdict['no_native_failure_issues'] = not rows
    references = {row['ordinal'] for row in report.get('objects',[]) if row.get('via') == 'ActionTestMetadata.summaryRef'
        and row.get('context_role') == TARGET and type(row.get('ordinal')) is int and row['ordinal'] > 0}
    if len(rows) != 2 or len(references) != 2: return verdict
    if any(row.get('role') != TARGET or row.get('known_fixed_file') is not True
        or row.get('typed_record_uuid_present') is not True or type(row.get('native_line_number')) is not int
        or not 63 <= row['native_line_number'] <= 66 or type(row.get('summary_reference_ordinal')) is not int for row in rows): return verdict
    verdict['source_site_RED_proven'] = {row['summary_reference_ordinal'] for row in rows} == references
    return verdict


def app_typed_issue_parser_controls():
    report = {'traversal_complete':True,'root_error_summary_count':0,
        'node_shapes':[{'type':'ActionTestPlanRunSummaries','via':'referenced'}]+[{'type':'ActionTestMetadata','role':method} for method in METHODS],
        'objects':[{'ordinal':1,'via':'ActionResult.testsRef','context_role':'unknown'},
        {'ordinal':2,'via':'ActionTestMetadata.summaryRef','context_role':TARGET},
        {'ordinal':3,'via':'ActionTestMetadata.summaryRef','context_role':TARGET}],
        'typed_failure_sources':[{'role':TARGET,'known_fixed_file':True,'typed_record_uuid_present':True,
            'native_line_number':63,'summary_reference_ordinal':2},
            {'role':TARGET,'known_fixed_file':True,'typed_record_uuid_present':True,'native_line_number':65,'summary_reference_ordinal':3}]}
    require(app_typed_source_verdict(report)['source_site_RED_proven'],'calibrated-typed-per-argument-source-positive')
    empty = dict(report,typed_failure_sources=[])
    require(app_typed_source_verdict(empty)['no_native_failure_issues'],'complete-typed-empty-source-positive')
    route_bad = []
    value = copy.deepcopy(empty); value['objects'] = [row for row in value['objects'] if row['via'] != 'ActionResult.testsRef']; route_bad.append(value)
    value = copy.deepcopy(empty); value['node_shapes'] = [row for row in value['node_shapes'] if row['type'] != 'ActionTestPlanRunSummaries']; route_bad.append(value)
    value = copy.deepcopy(empty); value['node_shapes'].pop(); route_bad.append(value)
    value = copy.deepcopy(empty); value['node_shapes'][-1]['role'] = 'unknown'; route_bad.append(value)
    for value in route_bad: require(not app_typed_source_verdict(value)['no_native_failure_issues'],'missing-typed-tests-route-is-not-empty-GREEN')
    bad = []
    def altered(change):
        value = copy.deepcopy(report); change(value); bad.append(value)
    altered(lambda value:value.update(traversal_complete=False))
    altered(lambda value:value.update(root_error_summary_count=1))
    altered(lambda value:value.update(root_error_summary_count=False))
    altered(lambda value:value.update(root_error_summary_count=None))
    altered(lambda value:value['typed_failure_sources'].pop())
    altered(lambda value:value['typed_failure_sources'].append(copy.deepcopy(value['typed_failure_sources'][0])))
    for field,wrong in [('role',next(name for name in METHODS if name != TARGET)),('known_fixed_file',False),
        ('typed_record_uuid_present',False),('native_line_number',62),('native_line_number',67),('native_line_number',True),
        ('summary_reference_ordinal',3),('summary_reference_ordinal',True)]:
        altered(lambda value,field=field,wrong=wrong:value['typed_failure_sources'][0].update({field:wrong}))
    altered(lambda value:value['objects'][1].update(context_role='unknown'))
    altered(lambda value:value['objects'][1].update(via='ActionResult.testsRef'))
    for value in bad: require(not app_typed_source_verdict(value)['source_site_RED_proven'],'no-foreign-or-ambiguous-typed-source-RED')
    for method,labels in METHODS.items():
        require(app_legacy_method(method+'('+labels+')') == method,'calibrated-bare-summary-name')
        require(app_legacy_method(SUITE+'/'+method+'('+labels+')') == method,'calibrated-qualified-summary-identifier')
    require(app_legacy_method('ForeignSuite/'+TARGET+'(appearance:)') is None,'no-foreign-summary-role')
    require(app_legacy_method(TARGET+'(appearance: PRIVATE_VALUE)') is None,'no-argument-display-as-method-authority')
    provenance = ('SYNTHETIC_FIXED_FILE',63,TARGET,2); records = {}
    require(app_record_uuid(records,'synthetic-native-uuid',provenance),'new-native-uuid-positive')
    require(not app_record_uuid(records,'synthetic-native-uuid',provenance),'identical-native-record-repeat-positive')
    uuid_negatives = 0
    for bad_uuid in ['', ' ',None]:
        rejected = False
        try: app_record_uuid({},bad_uuid,provenance)
        except (ValueError,UnicodeError): rejected = True
        require(rejected,'no-empty-native-uuid'); uuid_negatives += 1
    for index,wrong in enumerate(['OTHER_FILE',64,'OTHER_METHOD',3]):
        conflicting = list(provenance); conflicting[index] = wrong; rejected = False
        try: app_record_uuid(dict(records),'synthetic-native-uuid',tuple(conflicting))
        except ValueError: rejected = True
        require(rejected,'no-hidden-conflicting-native-uuid'); uuid_negatives += 1
    malformed_information = {'_type':{'_name':'ActionsInvocationRecord'},'issues':{'_type':{'_name':'ResultIssueSummaries'},
        'testFailureSummaries':{'_type':{'_name':'Array'},'_values':[{'_type':{'_name':'TestFailureIssueSummary'},
            'message':{'_type':{'_name':'String'},'_value':'\ud800'}}]}}}
    informational,_ = legacy_information_only(malformed_information)
    require(informational['source_site_RED_proven'] is False and app_typed_source_verdict(report)['source_site_RED_proven'],
        'unknown-aggregate-display-never-gates-authoritative-source')
    return {'source_positive':2,'source_negative':len(bad),'identity_positive':len(METHODS)*2,'identity_negative':2,
        'uuid_positive':2,'uuid_negative':uuid_negatives,'empty_GREEN_route_negative':len(route_bad),'aggregate_independence':1,'runtime_bodies':0}


def calibration_legacy_walk(bundle,root,environment,save,result,app_row=None):
    report = {'objects':[],'typed_failure_sources':[],'references_requested':0,'maximum_references':16,
        'maximum_reference_bytes':8*1024*1024,'reference_captured_bytes':0,'unknown_shapes':0,'complete':False,
        'raw_reference_ids_names_messages_paths_exported':False}
    if app_row is None: result['calibration']['legacy_traversal'] = report
    else:
        app_row['typed_legacy_failure_sources'] = report
        report['root_error_summary_count'] = None
        report['required_source'] = {'file':TEST,'line_range':[63,66],'method':TARGET,'coordinate_source':'calibrated_typed_ActionTestFailureSummary_lineNumber_no_conversion'}
    save()
    queue = [(root,'root','unknown')]; seen = set(); references = []; visited = 0; source_records = set(); app_uuid_provenance = {}
    allowed_types = {'ActionsInvocationRecord','ActionRecord','ActionResult','ActionTestPlanRunSummaries','ActionTestPlanRunSummary',
        'ActionTestableSummary','ActionTestSummaryGroup','ActionTestMetadata','ActionTestSummary','ActionTestFailureSummary'}
    child_fields = {'ActionsInvocationRecord':['actions'],'ActionRecord':['actionResult'],
        'ActionTestPlanRunSummaries':['summaries'],'ActionTestPlanRunSummary':['testableSummaries'],
        'ActionTestableSummary':['tests','failureSummaries'],'ActionTestSummaryGroup':['subtests','failureSummaries'],
        'ActionTestSummary':['failureSummaries']}
    deadline = time.monotonic()+180
    while queue or references:
        if time.monotonic() >= deadline: report['watchdog_reached'] = True; break
        if not queue:
            reference,parent_type,parent_role = references.pop(0)
            if reference in seen: continue
            if len(seen) >= 16: report['reference_limit_reached'] = True; break
            seen.add(reference); report['references_requested'] += 1
            remaining = deadline-time.monotonic(); byte_budget = 8*1024*1024-report['reference_captured_bytes']
            if remaining <= 0: report['watchdog_reached'] = True; break
            if byte_budget <= 0: report['byte_limit_reached'] = True; break
            capture,data = bounded_capture(['xcrun','xcresulttool','get','object','--legacy','--path',str(bundle),'--id',reference,'--format','json'],environment,min(30,remaining),min(2*1024*1024,byte_budget))
            report['reference_captured_bytes'] += len(data)
            report['objects'].append({'ordinal':len(seen),'via':parent_type,'context_role':parent_role,'capture':capture}); save()
            if capture['exit_code'] != 0 or capture['watchdog_triggered'] or capture['output_limit_triggered']: report['unknown_shapes'] += 1; break
            try: queue.append((json.loads(data),'referenced',parent_role))
            except ValueError: report['unknown_shapes'] += 1; break
            continue
        value,via,role = queue.pop(0); visited += 1
        if visited > 2048: report['node_limit_reached'] = True; break
        if not isinstance(value,dict) or not isinstance(value.get('_type'),dict): report['unknown_shapes'] += 1; continue
        kind = value['_type'].get('_name')
        if not isinstance(kind,str) or kind not in allowed_types: report['unknown_shapes'] += 1; continue
        try:
            for field in ['identifier','name']:
                if field in value:
                    identified = calibration_role(calibration_string(value[field])) if app_row is None else app_legacy_method(calibration_string(value[field])) or 'unknown'
                    if identified != 'unknown': role = identified
            if kind == 'ActionsInvocationRecord' and app_row is not None:
                issues = value.get('issues'); require(legacy_type(issues,'ResultIssueSummaries'),'typed-root-issue-container')
                report['root_error_summary_count'] = len(legacy_array(issues['errorSummaries'])) if 'errorSummaries' in issues else 0
            shape = {'ordinal':visited,'type':kind,'role':role,'via':via,
                'known_keys':sorted(set(value)&{'_type','actions','actionResult','testsRef','summaries','testableSummaries','tests','subtests','identifier','identifierURL','name','testStatus','summaryRef','failureSummaries','fileName','lineNumber','sourceCodeContext','arguments'}),
                'other_key_count':len(set(value)-{'_type','actions','actionResult','testsRef','summaries','testableSummaries','tests','subtests','identifier','identifierURL','name','testStatus','summaryRef','failureSummaries','fileName','lineNumber','sourceCodeContext','arguments'})}
            report.setdefault('node_shapes',[]).append(shape)
            if app_row is not None and kind == 'ActionTestMetadata' and 'summaryRef' not in value:
                report['unknown_shapes'] += 1
            if kind == 'ActionTestFailureSummary':
                filename = calibration_string(value.get('fileName')); line = calibration_integer(value.get('lineNumber'))
                if app_row is None: known_file = filename == CALIBRATION_FILE or filename.endswith('/'+CALIBRATION_FILE)
                else:
                    basename = Path(TEST).name
                    known_file = filename in {TEST,basename,'whitenoise_macTests/'+basename} or filename.endswith('/'+TEST)
                # Distinct native failure UUIDs establish two actual records, but identifiers never leave memory.
                uuid = calibration_string(value.get('uuid'),256) if 'uuid' in value else None
                identity = (uuid,filename,line)
                keep = identity not in source_records if app_row is None else app_record_uuid(app_uuid_provenance,uuid,(filename,line,role,len(seen)))
                if keep:
                    if app_row is None: source_records.add(identity)
                    if app_row is None:
                        report['typed_failure_sources'].append({'role':role,'known_fixed_file':known_file,'native_line_number':line,
                            'matches_literal_line':known_file and line == CALIBRATION_LINE,'line_delta_from_literal':line-CALIBRATION_LINE,
                            'typed_record_uuid_present':uuid is not None})
                    else:
                        report['typed_failure_sources'].append({'role':role,'known_fixed_file':known_file,'native_line_number':line,
                            'typed_record_uuid_present':uuid is not None,'summary_reference_ordinal':len(seen)})
            for field in child_fields.get(kind,[]):
                if app_row is not None and field == 'failureSummaries' and kind != 'ActionTestSummary': continue
                if field not in value: continue
                if field == 'actionResult': queue.append((value[field],field,role))
                else: queue.extend((child,field,role) for child in legacy_array(value[field]))
            for field in ['testsRef','summaryRef']:
                if field not in value: continue
                reference = value[field]; require(legacy_type(reference,'Reference'),'typed-calibration-reference')
                token = calibration_string(reference.get('id'),1024)
                require(bool(token) and '\n' not in token and '\x00' not in token,'bounded-calibration-reference-token')
                references.append((token,kind+'.'+field,role))
        except ValueError: report['unknown_shapes'] += 1
        save()
    report['visited_nodes'] = visited
    if app_row is None: report['complete'] = calibration_sources_complete(report,bool(queue or references))
    else:
        report['traversal_complete'] = (not queue and not references and not report['unknown_shapes']
            and not any(report.get(flag) for flag in ['watchdog_reached','byte_limit_reached','reference_limit_reached','node_limit_reached']))
        report['complete'] = report['traversal_complete']
        report.update(app_typed_source_verdict(report))
    save(); return report


def native_calibration(result,save):
    result['calibration_parser_controls'] = calibration_parser_controls(); save()
    root = OUT/'native-calibration'; require(not root.exists(),'fresh-owned-calibration-root')
    root.mkdir(); project = root/'NativeIssueCalibration.xcodeproj'; scheme = project/'xcshareddata/xcschemes/NativeIssueCalibration.xcscheme'
    scheme.parent.mkdir(parents=True)
    files = {root/CALIBRATION_FILE:CALIBRATION_SWIFT,project/'project.pbxproj':CALIBRATION_PROJECT,scheme:CALIBRATION_SCHEME}
    require(CALIBRATION_SWIFT.splitlines()[CALIBRATION_LINE-1].strip() == '#expect(value == 99)','literal-calibration-source-line')
    before = fingerprint(); manifest = {}
    for path,data in files.items():
        path.write_text(data); path.chmod(0o600)
        manifest[str(path.relative_to(root))] = {'sha256':hashlib.sha256(data.encode()).hexdigest(),'mode':stat.S_IMODE(path.stat().st_mode)}
    result['calibration'] = {'project_files':manifest,'expected_source_line':CALIBRATION_LINE,'App_build_executed':False,
        'MarmotKit_or_private_SDK_consumed':False,'account_or_relay_data_used':False,'product_behavior_qualification':False,
        'native_typed_source_calibration_verified':False}
    save(); bundle = root/'Results.xcresult'
    environment = dict(os.environ)
    command = ['xcodebuild','test','-project',str(project),'-scheme','NativeIssueCalibration','-configuration','Debug',
        '-destination','platform=macOS,arch=arm64','-derivedDataPath',str(root/'DerivedData'),'-resultBundlePath',str(bundle),
        '-parallel-testing-enabled','NO','-disableAutomaticPackageResolution','-skipPackageUpdates',
        'ARCHS=arm64','ONLY_ACTIVE_ARCH=YES','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO']
    capture,synthetic_output = bounded_capture(command,environment,120,4*1024*1024)
    (root/'synthetic-build-output.txt').write_bytes(synthetic_output)
    result['calibration']['synthetic_build_output'] = {'bytes':len(synthetic_output),'sha256':hashlib.sha256(synthetic_output).hexdigest(),
        'source':'only_owned_synthetic_xcodebuild_stdout_stderr_no_App_or_environment_dump'}
    result['calibration']['build_test_capture'] = capture; save()
    require(fingerprint() == before,'calibration-original-whole-source-modes-pristine')
    result['calibration']['generated_inputs_pristine'] = all(not path.is_symlink() and path.read_text() == data and stat.S_IMODE(path.stat().st_mode) == 0o600 for path,data in files.items())
    save(); require(bundle.is_dir() and not capture['watchdog_triggered'] and not capture['output_limit_triggered'],'actual-bounded-calibration-result-required')
    exports = {}
    commands = [('summary',['get','test-results','summary']),('tests',['get','test-results','tests']),
        ('details',['get','test-results','test-details','--test-id','NativeIssueCalibration/knownSourceFailure(value:)']),
        ('legacy',['get','object','--legacy','--format','json'])]
    for label,args in commands:
        capture,data = bounded_capture(['xcrun','xcresulttool',*args,'--path',str(bundle)],environment,30,2*1024*1024)
        result['calibration'].setdefault('export_capture',{})[label] = capture; save()
        if capture['exit_code'] != 0 or capture['watchdog_triggered'] or capture['output_limit_triggered']: continue
        try: exports[label] = json.loads(data)
        except ValueError: continue
        if label == 'summary': result['calibration']['actual_summary'] = summary_safe(exports[label]); save()
        elif label == 'details': result['calibration']['modern_details'] = calibration_modern_details(exports[label]); save()
    if 'legacy' in exports: calibration_legacy_walk(bundle,exports['legacy'],environment,save,result)
    if 'tests' in exports:
        # Closed structural projection only; names, arguments, failure text and host paths are not exported.
        counts = {}; shapes = []; nodes = 0; pending = [exports['tests']]
        while pending:
            value = pending.pop(); nodes += 1
            if nodes > 2048: result['calibration']['modern_tree_limit_reached'] = True; break
            if isinstance(value,list): pending.extend(value)
            elif isinstance(value,dict):
                kind = value.get('nodeType')
                if isinstance(kind,str):
                    category = kind if kind in {'Test Plan','Unit test bundle','Test Suite','Test Case','Arguments','Failure Message','Test Case Run'} else 'other'
                    counts[category] = counts.get(category,0)+1
                    if len(shapes) < 128:
                        children = value.get('children')
                        row = {'type':category,'known_keys':sorted(set(value)&{'nodeType','name','children','result','duration','durationInSeconds','nodeIdentifier','nodeIdentifierURL'}),
                            'other_key_count':len(set(value)-{'nodeType','name','children','result','duration','durationInSeconds','nodeIdentifier','nodeIdentifierURL'}),
                            'closed_result':value.get('result') if isinstance(value.get('result'),str) and value['result'] in STATUS_KEYS else 'unknown',
                            'name_nonempty_string':isinstance(value.get('name'),str) and bool(value['name']),
                            'children_count':len(children) if isinstance(children,list) else None}
                        if kind == 'Failure Message': row['expectation_prefix_present_in_synthetic_name'] = isinstance(value.get('name'),str) and value['name'].startswith('Expectation failed:')
                        shapes.append(row)
                pending.extend(child for child in value.values() if isinstance(child,(dict,list)))
        result['calibration']['modern_tree_type_counts'] = counts
        result['calibration']['modern_tree_node_shapes'] = shapes
    summary = result['calibration'].get('actual_summary',{})
    result['calibration']['whole_source_modes_pristine'] = fingerprint() == before
    result['calibration']['native_typed_source_calibration_verified'] = (result['calibration']['whole_source_modes_pristine']
        and result['calibration']['build_test_capture']['exit_code'] not in {None,0}
        and calibration_summary_valid(summary)
        and result['calibration'].get('modern_details',{}).get('complete') is True
        and result['calibration'].get('legacy_traversal',{}).get('complete') is True
        and result['calibration']['generated_inputs_pristine'])
    save(); require(result['calibration']['native_typed_source_calibration_verified'],'synthetic-typed-native-source-calibration-pending')


ARCHIVE_RUN = 39127424696
ARCHIVE_ID = 12136628289
ARCHIVE_BYTES = 103432154
ARCHIVE_SHA256 = '7c38636fd89b8ee9420bc1366adaec5fc7a1f053b2de9ba4aa04406edccbd691'
ARCHIVE_SOURCE = '2a60df8f95245328b43b324c325a31540b2488e5'
ARCHIVE_MERGE = 'b2585ba68cee4f896d96fe563d2fab59d8a7cf1b'
ARCHIVE_BASE = '42c88ab5a4c9cc28521c503e26737d6e27b0694f'
ARCHIVE_TREE = '986c763da53e4c7d1db4e81f33c2ee776dfb1dc8'


def archive_closed_summary(raw):
    result = {'status':'unknown','native_summary':{},'devicesAndConfigurations':[],
        'configuration_status':'unknown','configuration_counts_are_not_summed':True,
        'raw_device_configuration_or_test_identifiers_exported':False}
    if not isinstance(raw,dict): return result
    if not all(type(raw.get(key)) is int and raw[key] >= 0 for key in COUNT_KEYS): return result
    if raw['totalTestCount'] != sum(raw[key] for key in COUNT_KEYS[1:]) or not raw['totalTestCount']: return result
    result['native_summary'] = {key:raw[key] for key in COUNT_KEYS}
    if isinstance(raw.get('result'),str) and raw['result'] in {'Passed','Failed','Skipped'}: result['native_summary']['result'] = raw['result']
    else: return result
    for key in ['expectedFailures']:
        if key in raw:
            if type(raw[key]) is not int or raw[key] < 0: return result
            result['native_summary'][key] = raw[key]
    for key in ['startTime','finishTime']:
        if type(raw.get(key)) in {int,float} and math.isfinite(raw[key]): result['native_summary'][key] = raw[key]
    configurations = raw.get('devicesAndConfigurations')
    if 'devicesAndConfigurations' not in raw: result['configuration_status'] = 'not_present'
    elif isinstance(configurations,list) and len(configurations) <= 32:
        result['configuration_status'] = 'complete'
        for index,row in enumerate(configurations):
            closed = {'ordinal':index+1}
            if not isinstance(row,dict): result['configuration_status'] = 'unknown'; break
            for key in ['totalTestCount','passedTests','failedTests','skippedTests','expectedFailures']:
                if key in row:
                    if type(row[key]) is not int or row[key] < 0: result['configuration_status'] = 'unknown'; break
                    closed[key] = row[key]
            if not {'passedTests','failedTests','skippedTests'} <= set(closed): result['configuration_status'] = 'unknown'
            result['devicesAndConfigurations'].append(closed)
    if result['configuration_status'] == 'unknown': return result
    result['status'] = 'complete'; return result


def archive_member_parts(name):
    require(isinstance(name,str) and 0 < len(name.encode()) <= 4096 and '\\' not in name and '\x00' not in name,'bounded-safe-archive-member')
    parts = PurePosixPath(name).parts
    require(parts and not name.startswith('/') and all(part not in {'.','..',''} for part in parts)
        and '/'.join(parts) == name.rstrip('/'),'no-archive-path-normalization-or-traversal')
    return parts


def archive_summary_parser_controls():
    raw = dict(totalTestCount=3,passedTests=3,failedTests=0,skippedTests=0,result='Passed',
        devicesAndConfigurations=[dict(passedTests=5,failedTests=0,skippedTests=0)])
    good = archive_closed_summary(raw)
    require(good['status'] == 'complete' and good['native_summary']['totalTestCount'] == 3
        and good['devicesAndConfigurations'][0]['passedTests'] == 5,'native-config-definition-counts-stay-separate')
    negative = []
    for key in COUNT_KEYS:
        for bad in [None,True,-1,'0']: negative.append(dict(raw,**{key:bad}))
    negative.append(dict(raw,totalTestCount=0,passedTests=0))
    negative.append(dict(raw,totalTestCount=4))
    negative.append(dict(raw,result={}))
    negative.append(dict(raw,devicesAndConfigurations=None))
    negative.append(dict(raw,devicesAndConfigurations=[dict(passedTests=True,failedTests=0,skippedTests=0)]))
    for value in negative: require(archive_closed_summary(value)['status'] != 'complete','invalid-native-archive-counts-rejected')
    require(archive_member_parts('TestResults.xcresult/Data/public-synthetic') == ('TestResults.xcresult','Data','public-synthetic'),'wrapped-safe-archive-path')
    require(archive_member_parts('Info.plist') == ('Info.plist',),'bare-safe-archive-path')
    path_negative = 0
    for name in ['../private','/absolute','Data/../escape','./Info.plist','Data//normalized','Data\\private','Data/\x00bad']:
        rejected = False
        try: archive_member_parts(name)
        except ValueError: rejected = True
        require(rejected,'unsafe-archive-member-rejected'); path_negative += 1
    return {'summary_positive':1,'summary_negative':len(negative),'path_positive':2,'path_negative':path_negative,'actual_tests_executed':0}


def archive_summary_export(result,save):
    result['archive_summary_parser_controls'] = archive_summary_parser_controls(); save()
    root = OUT/'archive-summary'; require(not root.exists(),'fresh-owned-archive-export-root'); root.mkdir()
    before = fingerprint(); environment = dict(os.environ)
    require(bool(environment.get('GH_TOKEN')),'read-only-Actions-token-required')
    record = {'source_run':ARCHIVE_RUN,'source_artifact':ARCHIVE_ID,'source_head_sha':ARCHIVE_SOURCE,
        'source_PR_merge_sha':ARCHIVE_MERGE,'source_tree':ARCHIVE_TREE,'App_build_or_test_executed':False,
        'SDK_download_or_packaging_executed':False,'archive_summary_complete':False,
        'full_or_native_sync_qualification_claim':False,'raw_bundle_or_private_output_uploaded':False}
    result['archive_summary_export'] = record; save()
    def api(path):
        capture,data = bounded_capture(['gh','api','repos/dyKiU/whitenoise-mac/'+path],environment,30,256*1024)
        require(capture['exit_code'] == 0 and not capture['watchdog_triggered'] and not capture['output_limit_triggered'],'bounded-readonly-GitHub-metadata')
        return json.loads(data)
    run = api('actions/runs/'+str(ARCHIVE_RUN))
    require(run.get('id') == ARCHIVE_RUN and run.get('head_sha') == ARCHIVE_SOURCE and run.get('status') == 'completed'
        and run.get('conclusion') == 'success' and run.get('event') == 'pull_request' and run.get('path') == WORKFLOW
        and run.get('repository',{}).get('full_name') == 'dyKiU/whitenoise-mac','immutable-successful-original-CI-run')
    artifact = api('actions/artifacts/'+str(ARCHIVE_ID))
    require(artifact.get('id') == ARCHIVE_ID and artifact.get('name') == 'mac-unit-test-results'
        and artifact.get('size_in_bytes') == ARCHIVE_BYTES and artifact.get('digest') == 'sha256:'+ARCHIVE_SHA256
        and artifact.get('expired') is False and artifact.get('workflow_run',{}).get('id') == ARCHIVE_RUN
        and artifact.get('workflow_run',{}).get('head_sha') == ARCHIVE_SOURCE,'exact-pinned-native-artifact')
    source = api('git/commits/'+ARCHIVE_SOURCE); merge = api('git/commits/'+ARCHIVE_MERGE)
    require(source.get('tree',{}).get('sha') == merge.get('tree',{}).get('sha') == ARCHIVE_TREE
        and [parent.get('sha') for parent in merge.get('parents',[])] == [ARCHIVE_BASE,ARCHIVE_SOURCE], 'exact-tested-PR-merge-tree')
    record['source_and_artifact_metadata_verified'] = True
    record['artifact'] = {'id':ARCHIVE_ID,'bytes':ARCHIVE_BYTES,'sha256':ARCHIVE_SHA256,'run_url':run.get('html_url')}; save()
    require(shutil.disk_usage(root).free >= ARCHIVE_BYTES+3*1024**3,'archive-export-disk-reserve')
    archive = root/'source-artifact.zip'
    capture,_ = bounded_capture(['gh','api','repos/dyKiU/whitenoise-mac/actions/artifacts/'+str(ARCHIVE_ID)+'/zip'],environment,120,ARCHIVE_BYTES,private_log=archive)
    record['archive_download_capture'] = capture; save()
    require(capture['exit_code'] == 0 and not capture['watchdog_triggered'] and not capture['output_limit_triggered']
        and archive.stat().st_size == ARCHIVE_BYTES,'complete-bounded-original-artifact-download')
    digest = hashlib.sha256()
    with archive.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''): digest.update(block)
    record['archive_sha256_verified'] = digest.hexdigest() == ARCHIVE_SHA256; save()
    require(record['archive_sha256_verified'],'original-artifact-ZIP-digest')
    bundle = root/'TestResults.xcresult'; bundle.mkdir(); members = []; total = 0
    with zipfile.ZipFile(archive) as zip_file:
        infos = zip_file.infolist(); require(0 < len(infos) <= 50000,'bounded-XCResult-ZIP-inventory')
        paths = [archive_member_parts(info.filename) for info in infos]
        wrapped = all(parts[0] == 'TestResults.xcresult' for parts in paths)
        relative = [parts[1:] if wrapped else parts for parts in paths]
        require(('Info.plist',) in relative,'known-XCResult-root-anchor')
        seen = set()
        for info,parts in zip(infos,relative):
            if not parts:
                require(info.is_dir(),'wrapped-root-directory-only'); continue
            require(parts not in seen and not info.flag_bits & 1,'unique-unencrypted-archive-members'); seen.add(parts)
            kind = stat.S_IFMT(info.external_attr >> 16)
            require(kind in {0,stat.S_IFREG,stat.S_IFDIR} and (kind != stat.S_IFDIR or info.is_dir()),'no-archive-symlink-or-special-files')
            require(0 <= info.file_size <= 256*1024*1024,'bounded-native-archive-member-size')
            total += info.file_size; require(total <= 1024**3,'bounded-native-archive-total-size')
            members.append((info,parts))
        record['archive_inventory'] = {'entries':len(infos),'uncompressed_bytes':total,'layout':'wrapped_known_bundle' if wrapped else 'bare_bundle_contents',
            'safe_relative_regular_files_only':True}; save()
        require(shutil.disk_usage(root).free >= total+2*1024**3,'native-extraction-disk-reserve')
        for info,parts in members:
            path = bundle.joinpath(*parts)
            if info.is_dir(): path.mkdir(parents=True,exist_ok=True); continue
            path.parent.mkdir(parents=True,exist_ok=True)
            written = 0
            with zip_file.open(info) as source_stream,path.open('xb') as output:
                for block in iter(lambda:source_stream.read(1024*1024),b''):
                    written += len(block); require(written <= info.file_size,'exact-member-extraction-size'); output.write(block)
            require(written == info.file_size,'complete-member-extraction-size')
    capture,data = bounded_capture(['xcrun','xcresulttool','get','test-results','summary','--path',str(bundle)],environment,90,2*1024*1024)
    record['native_summary_capture'] = capture; save()
    require(capture['exit_code'] == 0 and not capture['watchdog_triggered'] and not capture['output_limit_triggered'],'bounded-existing-native-summary-export')
    record['counts'] = archive_closed_summary(json.loads(data)); save()
    require(record['counts']['status'] == 'complete','actual-existing-native-summary-counts-required')
    skipped = record['counts']['native_summary']['skippedTests']
    record['skips'] = {'count':skipped,'identifiers':[] if skipped == 0 else None,
        'identifiers_complete':skipped == 0,'raw_test_identifiers_exported':False}
    record['tested_source_declared_SDK'] = sdk_identity(OUT)
    record['tested_source_declared_SDK']['actual_binary_digest_available_in_original_summary'] = None
    record['tested_source_declared_SDK']['this_exporter_consumed_SDK'] = False
    record['whole_source_modes_pristine'] = fingerprint() == before
    record['archive_summary_complete'] = record['whole_source_modes_pristine']; save()
    require(record['archive_summary_complete'],'source-pristine-after-archive-export')


def main(args):
    os.umask(0o077); OUT.mkdir(parents=True,exist_ok=True)
    result = {'mode':args.mode,'phases':{},'component_GREEN':False,'counterfactual_runtime_RED_verified':False,
        'component_mutation_qualified':False,'full_qualification':False,'native_sync_acceptance':False,'promotion_eligible':False,
        'historical_owner_012_RED_claim':False}
    original = None; permissions = None; before = None
    def save(): (OUT/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    try:
        result['source'] = guard(); save()
        if args.mode == 'archive-summary':
            archive_summary_export(result,save); return
        if args.mode == 'native-calibration':
            native_calibration(result,save); return
        if args.mode == 'cli-schema':
            cli_schema_metadata(result,save); return
        result['parser_controls'] = parser_controls(); result['native_issue_parser_controls'] = native_issue_parser_controls(); result['app_typed_issue_parser_controls'] = app_typed_issue_parser_controls(); save()
        if args.mode == 'preflight':
            format_feedback(result,save); return
        require(Path(VIEW).read_text().count(OLD) == 1 and NEW not in Path(VIEW).read_text(),'one-exact-reviewed-renderer-condition')
        sdk_identity(OUT); before = fingerprint(); require(sum(Path(name).name == Path(TEST).name for name in before) == 1,'one-whole-tree-source-basename'); original = Path(VIEW).read_bytes(); permissions = Path(VIEW).stat().st_mode
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
    parser = argparse.ArgumentParser(); parser.add_argument('--mode',choices=['preflight','measure','red-green','pfp','cli-schema','native-calibration','archive-summary'],default='preflight')
    main(parser.parse_args())
