#!/usr/bin/env python3
"""Hosted source/formatter-only stage. No test or SDK acceptance claim."""
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess

BASE = '1c0ed6f4035f36c59718865a591695c614eeb4af'
PREVIOUS = '5db1dc879149ec8b168baa24cb860d8d32b9c02e'
SELF = 'scripts/ci/shared-ui-qualification.py'
WORKFLOW = '.github/workflows/upstream-shared-ui-qualification.yml'
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
    require(SELF not in expected and WORKFLOW not in expected and set(current) == set(expected)|{SELF,WORKFLOW},'whole-source-inventory')
    for name,(mode,blob) in current.items():
        require((mode == '120000' and Path(name).is_symlink()) or (mode != '120000' and not Path(name).is_symlink()),'actual-symlink-mode')
        if mode != '120000': require(bool(Path(name).stat().st_mode & 0o111) == (mode == '100755'),'actual-executable-mode')
        data = os.fsencode(os.readlink(name)) if mode == '120000' else Path(name).read_bytes()
        require(hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() == blob,'tracked-bytes:' + name)
        if name in {SELF,WORKFLOW}: require(mode == '100644','owned-metadata-mode')
        else: require(current[name] == expected[name],'whole-baseline-contents-modes:' + name)
    require(not git('ls-files','--others','--exclude-standard'),'no-untracked-source')
    require(git('diff','--name-only',PREVIOUS,BASE,'--','*.swift').splitlines() == FILES,'exact-seventeen-integrated-Swift-files')
    return {'source_sha':head,'source_tree':git('rev-parse','HEAD^{tree}'),'baseline':BASE,
        'baseline_tree':git('rev-parse',BASE+'^{tree}'),'whole_source_modes_exact':True,'macos_version':version,
        'inherited_sdk_manifest_sha256':hashlib.sha256(Path('Vendored/MarmotKit/Package.swift').read_bytes()).hexdigest(),
        'SDK_consumed':False,'build_or_native_qualification_claim':False}


def main():
    os.umask(0o077); OUT.mkdir(parents=True,exist_ok=True)
    result = {'mode':'format-only','source_guard_passed':False,'format_passed':False,'runtime_executed':False,
        'runtime_counts':None,'full_qualification':False,'native_acceptance':False,'promotion_eligible':False}
    try:
        result['source'] = guard(); result['source_guard_passed'] = True
        patches = []; result['files'] = {}
        for name in FILES:
            original = Path(name).read_text()
            formatted = subprocess.check_output(['xcrun','swift-format','format','--configuration','.swift-format',name],text=True)
            require(Path(name).read_text() == original,'formatter-does-not-mutate-input')
            result['files'][name] = {'needs_format':original != formatted}
            patches.extend(difflib.unified_diff(original.splitlines(True),formatted.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
        patch = ''.join(patches).encode(); (OUT/'format.patch').write_bytes(patch)
        result['format_patch_bytes'] = len(patch); result['format_patch_sha256'] = hashlib.sha256(patch).hexdigest()
        result['format_passed'] = not patch
        require(not patch,'hosted-format-patch-must-be-empty')
    except Exception as error:
        result['exception_type'] = type(error).__name__
        if isinstance(error,ValueError): result['failure_gate'] = str(error)
        raise
    finally:
        result['tracked_source_pristine'] = subprocess.run(['git','diff','--quiet','HEAD']).returncode == 0
        (OUT/'result.json').write_text(json.dumps(result,indent=2)+'\n')


if __name__ == '__main__': main()
