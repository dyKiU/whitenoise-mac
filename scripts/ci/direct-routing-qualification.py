#!/usr/bin/env python3
"""Owned hosted published direct-routing regression; compact evidence only."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import urllib.parse

MINIMUM = 'a4337d694f5e9b649cc44bcf3d1ae6258b24fdc3'
SELF = 'scripts/ci/direct-routing-qualification.py'
WORKFLOW = '.github/workflows/upstream-direct-routing.yml'
PRODUCT = 'whitenoise-mac/Core/WorkspaceState+NewChat.swift'
FIXTURE = 'whitenoise-macTests/DirectConversationRoutingTests.swift'
FORMATTED = [PRODUCT, 'whitenoise-mac/Views/Onboarding/AccountSetupView.swift', FIXTURE]
SUITE = 'DirectConversationRoutingTests'
TARGET = 'startNewBypassesSourceOwnedLocalSdkCandidate()'
CONTROLS = [TARGET, 'lookupFailureDoesNotFallThroughToCreatingAnotherInvitation()',
            'firstDirectConversationUsesNativeUnnamedGroupSentinel()',
            'explicitNamedGroupDoesNotReuseADirectConversation()',
            'accountSwitchAndReturnDuringLookupCannotCreateAnInvitationFromTheRetiredAction()']
EXPRESSIONS = ['runtime.existingDirectConversationQueries.isEmpty',
               'runtime.createGroupAttempts == [[peer]]',
               'runtime.createdGroupMemberRefs == [peer]',
               'state.selection == .chat("created-group")']
ANCHOR = '            if reusingExisting {\n'
COUNT_KEYS = ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests')
CAP = 32 * 1024 * 1024


class Rejected(Exception):
    pass


def require(value, label):
    if not value:
        raise Rejected(label)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(*args):
    return subprocess.check_output(['git', *args], stderr=subprocess.DEVNULL, timeout=60)


def capture(command, timeout, env=None):
    started = time.monotonic()
    process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, 'stdout')
    selector.register(process.stderr, selectors.EVENT_READ, 'stderr')
    buffers = {'stdout': bytearray(), 'stderr': bytearray()}
    stopped = None
    try:
        while selector.get_map():
            if time.monotonic() - started >= timeout:
                stopped = 'timeout'
                break
            for key, _ in selector.select(0.2):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if sum(map(len, buffers.values())) + len(chunk) > CAP:
                    stopped = 'output_limit'
                    break
                buffers[key.data].extend(chunk)
            if stopped:
                break
        if stopped:
            os.killpg(process.pid, signal.SIGTERM)
        try:
            code = process.wait(timeout=10 if stopped else max(1, timeout - (time.monotonic() - started)))
        except subprocess.TimeoutExpired:
            stopped = stopped or 'timeout'
            os.killpg(process.pid, signal.SIGKILL)
            code = process.wait(timeout=30)
        return ({'exit_code': code, 'seconds': time.monotonic() - started,
                 'capture_complete': stopped is None, 'timeout': stopped == 'timeout',
                 'output_limit': stopped == 'output_limit', 'raw_output_persisted': False,
                 'stdout_bytes': len(buffers['stdout']), 'stderr_bytes': len(buffers['stderr'])},
                bytes(buffers['stdout']), bytes(buffers['stderr']))
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=30)
        selector.close()
        process.stdout.close()
        process.stderr.close()


def tree(commit):
    result = {}
    for entry in git('ls-tree', '-rz', commit).split(b'\0'):
        if entry:
            info, raw = entry.split(b'\t', 1)
            mode, kind, blob = info.decode().split()
            name = os.fsdecode(raw)
            require(kind == 'blob' and mode in ('100644', '100755', '120000')
                    and not Path(name).is_absolute() and '..' not in Path(name).parts, 'tracked_tree_shape')
            result[name] = (mode, blob)
    return result


def physical(names):
    result = {}
    for name in sorted(names):
        path = Path(name)
        for parent in path.parents:
            if parent == Path('.'):
                break
            require(not parent.is_symlink(), 'physical_parent')
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode):
            data, mode = os.fsencode(os.readlink(path)), '120000'
        else:
            require(stat.S_ISREG(info.st_mode), 'physical_regular')
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                before = os.fstat(descriptor)
                data = b''
                while True:
                    chunk = os.read(descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    data += chunk
                after = os.fstat(descriptor)
                require((before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode)
                        == (after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode), 'physical_read_changed')
            finally:
                os.close(descriptor)
            mode = '100755' if info.st_mode & 0o111 else '100644'
        result[name] = (mode, hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest(), sha(data))
    return result


def fingerprint(values):
    return sha(json.dumps(values, sort_keys=True, separators=(',', ':')).encode())


def case_method(value):
    if not isinstance(value, str) or len(value) > 512:
        return None
    for prefix in ('whitenoise-macTests/', 'whitenoise_macTests/', 'whitenoise-macTests.', 'whitenoise_macTests.'):
        if value.startswith(prefix):
            value = value[len(prefix):]
            break
    for name in CONTROLS:
        if value in (SUITE + '/' + name, SUITE + '.' + name):
            return name
    return None


def native_rows(document, names):
    rows = []
    visited = 0
    def walk(value, depth=0):
        nonlocal visited
        visited += 1
        require(visited <= 20000 and depth <= 40, 'native_tree_bound')
        if isinstance(value, list):
            for child in value:
                walk(child, depth + 1)
        elif isinstance(value, dict):
            if value.get('nodeType') == 'Test Case':
                name = case_method(value.get('nodeIdentifier', value.get('testIdentifier')))
                status = value.get('result', value.get('status'))
                require(name in names and status in ('Passed', 'Failed'), 'native_case_identity_status')
                rows.append((name, status))
            for child in value.values():
                if isinstance(child, (dict, list)):
                    walk(child, depth + 1)
    walk(document)
    require(len(rows) == len(names) and {name for name, _ in rows} == set(names), 'native_unique_exact_inventory')
    return dict(rows)


def typed(value, name):
    return isinstance(value, dict) and isinstance(value.get('_type'), dict) and value['_type'].get('_name') == name


def string(value):
    require(typed(value, 'String') and isinstance(value.get('_value'), str) and len(value['_value']) <= 1024 * 1024,
            'native_typed_string')
    return value['_value']


def array(value):
    require(typed(value, 'Array') and isinstance(value.get('_values', []), list)
            and len(value.get('_values', [])) <= 64, 'native_typed_array')
    return value.get('_values', [])


def own_lines():
    text = Path(FIXTURE).read_text()
    start = text.index('func ' + TARGET)
    end = text.index('\n    }', start)
    lines = set()
    for expression in EXPRESSIONS:
        needle = '#expect(' + expression + ')'
        require(text[start:end].count(needle) == 1, 'source_owned_expectation')
        line = text.count('\n', 0, text.index(needle, start, end)) + 1
        # Native DocumentLocation fragments are recorded as delivered. Accept
        # only this exact source line under its documented zero/one-base forms.
        lines.update((line - 1, line))
    return lines


def native_issues(document):
    rows = []
    unknown = 0
    seen = set()
    require(typed(document, 'ActionsInvocationRecord') and typed(document.get('issues'), 'ResultIssueSummaries'),
            'native_issue_schema')
    issues = document['issues']
    errors = array(issues['errorSummaries']) if 'errorSummaries' in issues else []
    failures = array(issues['testFailureSummaries']) if 'testFailureSummaries' in issues else []
    for issue in failures:
        row = {'method': None, 'file': None, 'line': None, 'ending_line': None,
               'own_expectation': False, 'rejection': None}
        try:
            require(typed(issue, 'TestFailureIssueSummary'), 'native_failure_type')
            name = case_method(string(issue.get('testCaseName')))
            row['method'] = name
            message = string(issue.get('message'))
            row['expectation_prefix'] = message.startswith('Expectation failed:')
            kind = string(issue.get('issueType'))
            row['issue_class'] = kind if kind in ('Assertion Failure', 'Swift Testing Failure', 'Uncategorized') else 'other'
            target = issue.get('producingTarget')
            require(target is None or string(target) in ('whitenoise-macTests', 'whitenoise_macTests'), 'native_failure_target')
            location = issue.get('documentLocationInCreatingWorkspace')
            require(typed(location, 'DocumentLocation'), 'native_location_type')
            parsed = urllib.parse.urlsplit(string(location.get('url')))
            path = urllib.parse.unquote(parsed.path)
            row['known_file_suffix'] = path.endswith('/' + FIXTURE)
            row['file_scheme'] = parsed.scheme == 'file'
            require(parsed.scheme == 'file' and parsed.netloc in ('', 'localhost') and not parsed.query
                    and path.endswith('/' + FIXTURE) and '..' not in Path(path).parts and '%' not in path, 'native_own_path')
            row['file'] = FIXTURE
            fields = urllib.parse.parse_qs(parsed.fragment, strict_parsing=True)
            allowed = {'StartingLineNumber', 'EndingLineNumber', 'StartingColumnNumber', 'EndingColumnNumber', 'CharacterRangeLoc', 'CharacterRangeLen'}
            row['known_fragment_keys'] = sorted(set(fields) & allowed)
            row['other_fragment_key_count'] = len(set(fields) - allowed)
            require(set(fields) <= allowed and {'StartingLineNumber', 'EndingLineNumber'} <= set(fields)
                    and all(len(v) == 1 and re.fullmatch('[0-9]{1,8}', v[0]) for v in fields.values()), 'native_own_coordinate')
            line, end = int(fields['StartingLineNumber'][0]), int(fields['EndingLineNumber'][0])
            row.update(line=line, ending_line=end)
            require(name == TARGET and line == end and line in own_lines()
                    and kind in ('Assertion Failure', 'Swift Testing Failure') and message.startswith('Expectation failed:'),
                    'native_own_assertion')
            require((name, line) not in seen and len(failures) <= 4, 'native_duplicate_or_extra_issue')
            seen.add((name, line))
            row.update(method=TARGET, file=FIXTURE, line=line, own_expectation=True)
        except (Rejected, ValueError, TypeError, KeyError) as error:
            # Export only fixed validation labels and independently validated
            # source coordinates; native messages and URLs remain private.
            row['rejection'] = error.args[0] if type(error) is Rejected else 'native_payload_shape'
            unknown += 1
        rows.append(row)
    return {'root_error_count': len(errors), 'failure_issue_count': len(failures),
            'unknown_issue_count': unknown, 'issues': rows,
            'only_own_expectations': bool(rows) and not errors and unknown == 0,
            'no_native_issues': not errors and not failures}


def metadata():
    count = 0
    good = {'testNodes': [{'nodeType': 'Test Case', 'nodeIdentifier': SUITE + '/' + TARGET, 'result': 'Passed'}]}
    require(native_rows(good, [TARGET]) == {TARGET: 'Passed'}, 'metadata_native_positive')
    for value in ({}, {'testNodes': []}, {'testNodes': good['testNodes'] * 2},
                  {'testNodes': [dict(good['testNodes'][0], result='Skipped')]},
                  {'testNodes': [dict(good['testNodes'][0], nodeIdentifier='PRIVATE/unknown()')]}):
        try:
            native_rows(value, [TARGET])
        except Rejected:
            count += 1
        else:
            raise Rejected('metadata_native_negative')
    def scalar(value):
        return {'_type': {'_name': 'String'}, '_value': value}
    def wrapped(values):
        return {'_type': {'_name': 'Array'}, '_values': values}
    line = min(own_lines())
    issue = {'_type': {'_name': 'TestFailureIssueSummary'},
             'testCaseName': scalar(SUITE + '.' + TARGET),
             'message': scalar('Expectation failed: runtime.existingDirectConversationQueries.isEmpty'),
             'issueType': scalar('Swift Testing Failure'),
             'documentLocationInCreatingWorkspace': {'_type': {'_name': 'DocumentLocation'},
                 'url': scalar('file:///fixture/' + FIXTURE + '#StartingLineNumber=' + str(line) + '&EndingLineNumber=' + str(line))}}
    def document(values):
        return {'_type': {'_name': 'ActionsInvocationRecord'}, 'issues': {
            '_type': {'_name': 'ResultIssueSummaries'}, 'testFailureSummaries': wrapped(values)}}
    require(native_issues(document([issue]))['only_own_expectations'], 'metadata_own_issue_positive')
    require(native_issues(document([]))['no_native_issues'], 'metadata_no_issue_positive')
    # All values here are clearly synthetic parser inputs, never SDK/app proof.
    for change in ({'testCaseName': scalar('PRIVATE.unknown()')},
                   {'message': scalar('PRIVATE')}, {'issueType': scalar('PRIVATE')},
                   {'documentLocationInCreatingWorkspace': {'_type': {'_name': 'DocumentLocation'},
                       'url': scalar('file:///PRIVATE.swift#StartingLineNumber=1&EndingLineNumber=1')}},
                   {'documentLocationInCreatingWorkspace': {'_type': {'_name': 'DocumentLocation'},
                       'url': scalar('file:///fixture/' + FIXTURE + '#StartingLineNumber=1&EndingLineNumber=1')}}):
        result = native_issues(document([dict(issue, **change)]))
        require(not result['only_own_expectations'] and 'PRIVATE' not in json.dumps(result), 'metadata_reject_foreign_issue')
        count += 1
    require(not native_issues(document([issue, issue]))['only_own_expectations'], 'metadata_duplicate_issue_negative')
    count += 1
    return {'positive': 3, 'negative': count, 'actual_app_bodies': 0}


def published():
    require(os.environ.get('WN_EXPERIMENTAL_DEVICE_SYNC', '0') == '0'
            and os.environ.get('WN_CURRENT_SDK_API', '0') == '0'
            and not os.environ.get('WN_SDK_PROFILE'), 'published_capability_environment')
    require(not Path('Vendored/MarmotKit/LOCAL_BUILD.json').exists()
            and not Path('Vendored/MarmotKit/LOCAL_BUILD_INPUTS.json').exists(), 'published_no_overlay')
    for key in ('OTHER_SWIFT_FLAGS', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS', 'SWIFT_FLAGS', 'XCODE_XCCONFIG_FILE'):
        require(not os.environ.get(key), 'no_unchecked_compilation_override')


def inverse(data):
    text = data.decode()
    require(text.count(ANCHOR) == 1, 'unique_conditional_reuse')
    return text.replace(ANCHOR, ANCHOR.replace('if reusingExisting', 'if true'), 1).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('preflight', 'format', 'red', 'controls', 'pfp'), required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--baseline', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    os.umask(0o077)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    require(not output.exists(), 'fresh_closed_report')
    report = {'source': args.source, 'baseline': args.baseline, 'mode': args.mode, 'cohort': 'published-pinned',
              'whole_app_qualified': False, 'qualified': False, 'behavioral_red': False,
              'mutation_attempted': False, 'phases': [], 'actual_bodies': 0, 'raw_output_persisted': False}
    def save():
        temporary = output.with_suffix('.tmp')
        temporary.write_text(json.dumps(report, sort_keys=True, indent=2) + '\n')
        temporary.replace(output)
    frozen = current = index = None
    descriptor = None
    private = None
    original = None
    parent_info = None
    leaf_info = None
    def closure(expected):
        return (git('rev-parse', 'HEAD').decode().strip() == args.source
                and git('ls-files', '--stage', '-z') == index and physical(current) == expected
                and not git('ls-files', '--others', '--exclude-standard').strip())
    def write_product(data):
        require(parent_info is not None and leaf_info is not None, 'admitted_restore_owner')
        now_parent = Path(PRODUCT).parent.stat()
        now_leaf = Path(PRODUCT).lstat()
        require(not Path(PRODUCT).is_symlink()
                and (now_parent.st_dev, now_parent.st_ino) == parent_info
                and (now_leaf.st_dev, now_leaf.st_ino) == leaf_info, 'restore_physical_identity')
        physical([PRODUCT])  # Parent ancestry remains nofollow before any write.
        os.lseek(descriptor, 0, os.SEEK_SET)
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            require(written > 0, 'source_write_progress')
            view = view[written:]
        os.ftruncate(descriptor, len(data))
        os.fsync(descriptor)
    sdk_manifest = None
    def sdk_identity():
        frameworks = list((private / 'DerivedData/SourcePackages/artifacts').rglob('MarmotKit.xcframework'))
        require(len(frameworks) == 1 and not frameworks[0].is_symlink(), 'one_resolved_published_framework')
        files = {}
        for path in sorted(frameworks[0].rglob('*')):
            require(not path.is_symlink(), 'resolved_sdk_symlink')
            if path.is_file():
                digest = hashlib.sha256()
                with path.open('rb') as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(chunk)
                files[path.relative_to(frameworks[0]).as_posix()] = digest.hexdigest()
        require(files, 'resolved_sdk_inventory')
        return {'package_sha256': frozen['Vendored/MarmotKit/Package.swift'][2],
                'version_stamp_sha256': frozen['Vendored/MarmotKit/MARMOT_VERSION'][2],
                'resolved_file_hashes': files}
    def phase(label, names, expected, want_red):
        nonlocal sdk_manifest
        require(closure(expected), 'phase_source_closure')
        row = {'label': label, 'selected': names, 'qualified': False}
        report['phases'].append(row)
        save()
        free = shutil.disk_usage(private).free
        row['disk_free_bytes'] = free
        require(free >= 8 * 1024 ** 3, 'build_disk_reserve')
        bundle = private / (label + '.xcresult')
        env = dict(os.environ, WN_TEST_DERIVED_DATA=str(private / 'DerivedData'),
                   WN_TEST_RESULT_BUNDLE=str(bundle), WN_TEST_JOBS='3')
        command = ['scripts/test-isolated.sh'] + ['-only-testing:whitenoise-macTests/' + SUITE + '/' + name for name in names]
        facts, stdout, stderr = capture(command, 2100, env)
        row.update(command=['scripts/test-isolated.sh', *['-only-testing:whitenoise-macTests/' + SUITE + '/' + n for n in names]], **facts)
        row['test_build_succeeded'] = b'** TEST BUILD SUCCEEDED **' in stdout + stderr
        row['compiler_source_sites'] = []
        if not row['test_build_succeeded']:
            raw_text = (stdout + stderr).decode('utf-8', errors='replace')
            for name in FORMATTED:
                pattern = r'(?m)^' + re.escape(str(Path(name).resolve())) + r':([0-9]{1,7}):([0-9]{1,7}): error:'
                for match in re.finditer(pattern, raw_text):
                    if len(row['compiler_source_sites']) < 20:
                        row['compiler_source_sites'].append({'file': name, 'line': int(match[1]), 'column': int(match[2])})
        save()  # Actual exit/time/capture survives native exporter or oracle failure.
        require(bundle.is_dir(), 'native_result_missing')
        documents = {}
        for kind in ('summary', 'tests', 'legacy'):
            cmd = (['xcrun', 'xcresulttool', 'get', 'object', '--legacy', '--format', 'json', '--path', str(bundle)]
                   if kind == 'legacy' else ['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(bundle)])
            export, raw, _ = capture(cmd, 90)
            row[kind + '_export'] = export
            save()
            require(export['capture_complete'] and export['exit_code'] == 0, 'native_export_failed')
            documents[kind] = json.loads(raw)
            if kind == 'summary':
                row['counts'] = {key: documents[kind].get(key) for key in COUNT_KEYS}
                save()
                if all(type(row['counts'][key]) is int and row['counts'][key] >= 0 for key in COUNT_KEYS):
                    report['actual_bodies'] += row['counts']['passedTests'] + row['counts']['failedTests']
        counts = row['counts']
        row['cases'] = native_rows(documents['tests'], names)
        row['native_issues'] = native_issues(documents['legacy'])
        save()
        require(all(type(counts[k]) is int for k in COUNT_KEYS) and counts['totalTestCount'] == len(names)
                and counts['skippedTests'] == 0 and counts['passedTests'] + counts['failedTests'] == len(names)
                and sum(s == 'Failed' for s in row['cases'].values()) == counts['failedTests'], 'native_counts_exact')
        identity = sdk_identity()
        if sdk_manifest is None:
            sdk_manifest = identity
        require(identity == sdk_manifest, 'sdk_changed_between_phases')
        row['sdk'] = identity
        row['source_closure'] = closure(expected)
        success = (facts['capture_complete'] and row['test_build_succeeded'] and row['source_closure'])
        if want_red:
            success = (success and facts['exit_code'] == 65 and counts['failedTests'] == 1
                       and counts['passedTests'] == 0 and row['native_issues']['only_own_expectations'])
        else:
            success = (success and facts['exit_code'] == 0 and counts['failedTests'] == 0
                       and row['native_issues']['no_native_issues'])
        row['qualified'] = bool(success)
        save()
        return row['qualified']
    save()
    try:
        require(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == 'dyKiU/whitenoise-mac', 'approved_hosted_fork')
        ref = os.environ.get('GITHUB_REF', '')
        require(ref.startswith('refs/heads/ci/upstream-direct-routing-')
                and os.environ.get('GITHUB_WORKFLOW_REF') == 'dyKiU/whitenoise-mac/' + WORKFLOW + '@' + ref
                and os.environ.get('GITHUB_WORKFLOW_SHA') == os.environ.get('GITHUB_SHA') == args.source
                and re.fullmatch('[0-9a-f]{40}', args.source) and re.fullmatch('[0-9a-f]{40}', args.baseline)
                and git('rev-parse', 'HEAD').decode().strip() == args.source, 'exact_owned_workflow_source')
        event_name = os.environ.get('GITHUB_EVENT_NAME')
        require(event_name == 'workflow_dispatch' or (event_name == 'push' and args.mode == 'preflight'), 'explicit_manual_runtime')
        if event_name == 'workflow_dispatch':
            inputs = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()).get('inputs', {})
            require(inputs.get('source_sha') == args.source and inputs.get('baseline_sha') == args.baseline
                    and (args.mode == 'preflight' or inputs.get('mode') == args.mode), 'explicit_mode_inputs')
        require(subprocess.run(['git', 'merge-base', '--is-ancestor', MINIMUM, args.baseline]).returncode == 0
                and subprocess.run(['git', 'merge-base', '--is-ancestor', args.baseline, args.source]).returncode == 0, 'reviewed_ancestry')
        current, baseline = tree(args.source), tree(args.baseline)
        changed = {name for name in set(current) | set(baseline) if current.get(name) != baseline.get(name)}
        require(changed <= {SELF, WORKFLOW} and SELF in current and WORKFLOW in current, 'only_owned_tool_overlay')
        frozen = physical(current)
        require(all(frozen[name][:2] == pair for name, pair in current.items()), 'whole_tracked_modes_bytes')
        index = git('ls-files', '--stage', '-z')
        require(not git('ls-files', '--others', '--exclude-standard').strip()
                and subprocess.run(['git', 'diff', '--quiet', '--cached', 'HEAD']).returncode == 0 and closure(frozen), 'initial_git_closure')
        commit = git('cat-file', 'commit', args.source)
        report['source_identity'] = {'source': args.source, 'tree': git('rev-parse', 'HEAD^{tree}').decode().strip(),
            'baseline': args.baseline, 'owned_tool_overlays': sorted(changed), 'tracked_manifest_sha256': fingerprint(frozen),
            'signature_present': b'\ngpgsig ' in commit, 'hosted_signature_verification': 'not_performed',
            'signed_source_review': 'external_root_review_required_no_new_approval_system'}
        published()
        report['parser_controls'] = metadata()
        if args.mode == 'preflight':
            report['preflight_passed'] = True
        else:
            require(os.environ.get('RUNNER_OS') == 'macOS', 'hosted_macos')
            platform, version, _ = capture(['sw_vers', '-productVersion'], 30)
            require(platform['exit_code'] == 0 and version.decode().strip().startswith('26.'), 'macos26')
            original = Path(PRODUCT).read_bytes()
            if args.mode == 'format':
                patch = []
                for name in FORMATTED:
                    facts, formatted, _ = capture(['xcrun', 'swift-format', 'format', '--configuration', '.swift-format', name], 90)
                    require(facts['capture_complete'] and facts['exit_code'] == 0, 'remote_formatter_failed')
                    patch.extend(difflib.unified_diff(Path(name).read_text().splitlines(True), formatted.decode().splitlines(True), fromfile='a/' + name, tofile='b/' + name))
                feedback = output.parent / 'formatting.patch'
                feedback.write_text(''.join(patch))
                report['formatting'] = {'bytes': feedback.stat().st_size, 'sha256': sha(feedback.read_bytes()), 'only_reviewed_source_paths': True}
                report['formatting_passed'] = not patch
            else:
                private = Path(tempfile.mkdtemp(prefix='direct-routing-', dir=os.environ['RUNNER_TEMP']))
                scope = original.decode().split('func startDirectChat(', 1)[1].split('/// The invite prompt', 1)[0]
                if args.mode == 'red':
                    require(ANCHOR.strip() not in scope and 'let existing = try await existingDirectChat(' in scope, 'original_unconditional_reuse')
                    report['behavioral_red'] = phase('red', [TARGET], frozen, True)
                else:
                    inverse(original)
                    require(phase('baseline', CONTROLS, frozen, False), 'baseline_controls_failed')
                    if args.mode == 'controls':
                        report['qualified'] = True
                    else:
                        path = Path(PRODUCT)
                        parent = path.parent.stat()
                        leaf = path.stat()
                        require(leaf.st_nlink == 1, 'product_hardlink')
                        parent_info, leaf_info = (parent.st_dev, parent.st_ino), (leaf.st_dev, leaf.st_ino)
                        descriptor = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
                        report['mutation_attempted'] = True
                        write_product(inverse(original))
                        expected = physical(current)
                        require({n for n in frozen if frozen[n] != expected[n]} == {PRODUCT}
                                and expected[PRODUCT][0] == frozen[PRODUCT][0], 'only_conditional_inverse')
                        report['inverse_qualified'] = phase('inverse', [TARGET], expected, True)
    except Exception as error:
        report['failure_category'] = error.args[0] if type(error) is Rejected else 'unknown'
        report['exception_type'] = type(error).__name__
    finally:
        try:
            if descriptor is not None:
                if Path(PRODUCT).read_bytes() != original:
                    write_product(original)
                report['restored_exact'] = closure(frozen)
                save()
                if report['restored_exact']:
                    report['restored_qualified'] = phase('restored', CONTROLS, frozen, False)
                    report['qualified'] = bool(report.get('inverse_qualified')
                                               and report['restored_qualified'] and report['actual_bodies'] == 11)
            if frozen is not None:
                report['final_closure'] = closure(frozen)
                report['final_tracked_manifest_sha256'] = fingerprint(physical(current))
                require(report['final_closure'], 'final_source_closure')
        except Exception as error:
            report['closure_failure'] = error.args[0] if type(error) is Rejected else 'unknown'
        finally:
            if descriptor is not None:
                os.close(descriptor)
            if private is not None:
                try:
                    shutil.rmtree(private)
                    report['private_results_removed'] = not private.exists()
                except OSError:
                    report['private_results_removed'] = False
                    report['closure_failure'] = 'private_cleanup_failed'
            complete = report.get('final_closure') is True and 'failure_category' not in report and 'closure_failure' not in report
            report['qualified'] = bool(report['qualified'] and complete)
            report['behavioral_red'] = bool(report['behavioral_red'] and complete)
            report['preflight_passed'] = bool(report.get('preflight_passed') and complete)
            report['formatting_passed'] = bool(report.get('formatting_passed') and complete)
            save()
    return 0 if report['qualified'] or report['behavioral_red'] or report['preflight_passed'] or report['formatting_passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
