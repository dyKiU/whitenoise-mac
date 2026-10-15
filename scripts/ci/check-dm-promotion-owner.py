#!/usr/bin/env python3
"""Remote-only exact-body post-create ownership regression and mutation proof."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

if os.environ.get('GITHUB_ACTIONS') != 'true':
    raise SystemExit('Remote CI only')
phase = os.environ.get('PROMOTION_PHASE', 'red')
assert phase in ('red', 'green')
output = Path('promotion-proof'); output.mkdir()
source = Path('whitenoise-mac/Core/WorkspaceState+NewChat.swift')
original = source.read_bytes()
tracked = subprocess.check_output(['git','ls-files','whitenoise-mac','whitenoise-macTests','Vendored','scripts/test-isolated.sh','scripts/local-device-sync-settings.sh','.swift-format'],text=True).splitlines()
def hashes(): return {n:hashlib.sha256(Path(n).read_bytes()).hexdigest() for n in tracked}
frozen = hashes()
report = {'source':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(), 'phase':phase,'cohort':'published-default','sdk_version':Path('Vendored/MarmotKit/MARMOT_VERSION').read_text().strip(),'executions':[], 'passed':False, 'frozen_inputs':frozen}
regressions = ['accountReplacementDuringCreationCannotPromoteFromRetiredAction', 'accountReturnDuringCreationCannotRevivePromotionAuthority', 'cancellationDuringCreationCannotStartAnotherAdminWrite']
def save(): (output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
def execute(suite,test,expected,stage="control"):
    number=len(report['executions']); folder=Path(os.environ['RUNNER_TEMP'])/'promotion-owner'; folder.mkdir(exist_ok=True)
    bundle=folder/('case-'+str(number)+'.xcresult'); log=folder/('case-'+str(number)+'.log')
    selector='whitenoise-macTests/'+suite+'/'+test+'()'
    command=['scripts/test-isolated.sh','-parallel-testing-enabled','NO','-only-testing:'+selector]
    row={'test':suite+'/'+test,'stage':stage,'expected':expected,'command':command,'qualified':False};report['executions'].append(row);save()
    started=time.monotonic()
    with log.open('x') as stream:
        result=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=2400,env=dict(os.environ,WN_TEST_DERIVED_DATA=str(folder/'DerivedData'),WN_TEST_RESULT_BUNDLE=str(bundle),WN_TEST_JOBS='2'))
    text=log.read_text(errors='replace');row.update(exit_code=result.returncode,seconds=round(time.monotonic()-started,3),log_sha256=hashlib.sha256(log.read_bytes()).hexdigest())
    row['error_context_lines']=re.findall(r'(?m)^.*\berror:.*$',text)
    row['compilation_failed']='** TEST BUILD FAILED **' in text or '** BUILD FAILED **' in text
    row['actual_create_prerequisite']='direct-promotion-owner-prerequisite actual-created-group=true retired-action=true' in text
    row['own_marker']='retired-direct-chat-action-must-not-promote-peer' in text
    row['named_body']=bool(re.search(r'Test '+re.escape(test)+r'\(\)',text))
    row['own_test_file']='DirectChatPromotionOwnershipTests.swift:' in text
    if bundle.exists():
        raw=json.loads(subprocess.check_output(['xcrun','xcresulttool','get','test-results','summary','--path',str(bundle)],text=True))
        summary_path=output/('case-'+str(number)+'-summary.json')
        summary_path.write_text(json.dumps(raw,indent=2)+'\n')
        row['xcresult_summary_file']=summary_path.name
        row['xcresult_summary_sha256']=hashlib.sha256(summary_path.read_bytes()).hexdigest()
        row['counts']={k:raw.get(k) for k in ('totalTestCount','passedTests','failedTests','skippedTests')}
        wanted=dict(zip(row['counts'],(1,0,1,0) if expected=='red' else (1,1,0,0)))
        row['qualified']=(row['counts']==wanted and row['named_body'] and not row['compilation_failed'] and ((result.returncode==0) if expected=='green' else (result.returncode!=0 and row['own_marker'] and row['own_test_file'] and row['actual_create_prerequisite'])))
    save()
    if not row['qualified']: raise RuntimeError('Actual named runtime evidence required; compilation/zero bodies do not qualify')
try:
    assert subprocess.run(['git','diff','--quiet','HEAD']).returncode==0
    for test in regressions: execute('DirectChatPromotionOwnershipTests',test,'red' if phase=='red' else 'green')
    if phase=='green':
        for test in ('startingADirectChatMakesThePeerAnAdminToo','aRefusedPeerPromotionStillOpensTheDirectChat'):
            execute('GroupsTests',test,'green')
        execute('GroupsTests','startingDirectChatReusesExistingConversation','green')
        guard = (
            '            guard activeAccountId == accountId, conversationMetadataEpoch == accountEpoch, !Task.isCancelled else {\n'
            '                return\n'
            '            }\n'
        ).encode()
        after = b'            // Both people in a direct chat are its admins, so either can add someone or manage\n'
        anchor = guard + after
        if original.count(anchor) != 1:
            raise RuntimeError('Exact new ownership guard must be unique before promotion')
        mutant = original.replace(anchor, after, 1)
        report['mutation']={'original_sha256':hashlib.sha256(original).hexdigest(),'mutated_sha256':hashlib.sha256(mutant).hexdigest()}
        failure=None
        try:
            source.write_bytes(mutant)
            for test in regressions: execute('DirectChatPromotionOwnershipTests',test,'red','guard-omission')
        except Exception as error:
            failure=error
        finally:
            source.write_bytes(original)
            report['mutation']['exact_source_restored']=source.read_bytes()==original
            save()
        for test in regressions: execute('DirectChatPromotionOwnershipTests',test,'green','restored-control')
        if failure is not None: raise failure
        assert len(report['executions'])==12
    report['passed']=True
finally:
    source.write_bytes(original)
    report['inputs_unchanged']=hashes()==frozen
    report['tracked_pristine']=subprocess.run(['git','diff','--quiet','HEAD']).returncode==0
    report['passed']=report['passed'] and report['inputs_unchanged'] and report['tracked_pristine']
    save()
if not report['passed']: raise SystemExit(1)
