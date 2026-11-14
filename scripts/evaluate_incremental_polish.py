#!/usr/bin/env python3
"""Isolated real-time preview replay; approved final intents gate execution, never enter prompts.
Measures actual complete editing after frozen final ASR, not installed F5/ASR/insert latency.
"""
import argparse
import asyncio
import hashlib
import json
import os
from pathlib import Path
import time
from evaluate_local_polish import unique_object, apply_edit_patch


class Schedule:
    def __init__(self):
        self.text = ''
        self.changed_ms = 0
        self.last_text = ''
        self.last_start_ms = -15000
        self.count = 0

    def observe(self, ms, text):
        if text != self.text:
            self.text, self.changed_ms = text, ms

    def eligible(self, ms, busy=False):
        return (not busy and self.count < 8 and ms >= 4000 and len(self.text) >= 24
                and ms - self.changed_ms >= 800 and ms - self.last_start_ms >= 15000
                and self.text != self.last_text)

    def trigger(self, ms):
        if not self.eligible(ms):
            raise ValueError('Premature trigger')
        self.last_text, self.last_start_ms = self.text, ms
        self.count += 1
        return self.count, self.text


def apply_versioned_patch(source, serialized, version):
    payload = json.loads(serialized, object_pairs_hook=unique_object)
    if (not isinstance(payload, dict) or set(payload) != {'schema', 'base_version', 'edits'}
            or type(payload['schema']) is not int or payload['schema'] != 1
            or type(payload['base_version']) is not int or payload['base_version'] != version):
        raise ValueError('Patch schema or immutable base version mismatch')
    source.encode('utf-8', errors='strict')
    for edit in payload['edits'] if isinstance(payload['edits'], list) else []:
        if isinstance(edit, dict):
            for value in edit.values():
                if isinstance(value, str):
                    value.encode('utf-8', errors='strict')
    return apply_edit_patch(source, json.dumps(payload['edits'], ensure_ascii=False))


class Challenge(Exception):
    pass


class Worker:
    def __init__(self, binary, config, stderr, audit=None):
        self.binary, self.config, self.stderr = binary, config, stderr
        self.process = None
        self.calls = []
        self.preparation = None
        self.audit = audit or (lambda event: None)
        self.termination_requested = False

    async def start(self):
        self.process = await asyncio.create_subprocess_exec(str(self.binary), 'incremental-polish-worker',
            '--config-snapshot', str(self.config), stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=self.stderr)
        try:
            self.preparation = await self.call('worker-auth-preparation', 'prewarm', '', deadline_seconds=20)
        except BaseException:
            await self.close()
            raise
        self.calls.clear()
        if not self.preparation.get('authReady'):
            await self.close()
            raise RuntimeError('Account preparation unavailable')
        return self

    async def call(self, id, mode, text, deadline_seconds=120, **kwargs):
        request = dict(id=id, mode=mode, text=text, **kwargs)
        started = time.perf_counter()
        identity = dict(id=id, mode=mode, workerPID=self.process.pid)
        self.audit(dict(event='request-start', monotonic=started, **identity,
                        inputSHA256=hashlib.sha256(text.encode()).hexdigest()))
        try:
            self.process.stdin.write((json.dumps(request, ensure_ascii=False) + '\n').encode())
            await self.process.stdin.drain()
            line = await asyncio.wait_for(self.process.stdout.readline(), timeout=deadline_seconds)
            if not line:
                raise RuntimeError('Worker ended without complete result')
            result = json.loads(line)
            if not isinstance(result, dict) or result.get('id') != id:
                raise RuntimeError('Response identity mismatch')
        except BaseException as error:
            self.audit(dict(event='request-cancelled' if isinstance(error,asyncio.CancelledError) else 'request-failed',
                            monotonic=time.perf_counter(), errorType=type(error).__name__, **identity))
            raise
        result['requestStartMonotonic'] = started
        result['responseMonotonic'] = time.perf_counter()
        result['fullCallMs'] = (result['responseMonotonic'] - started) * 1000
        result['mode'] = mode
        self.calls.append(result)
        self.audit(dict(event='request-response', monotonic=result['responseMonotonic'], result=result, **identity))
        calls = result.get('timing', {}).get('polishCalls', [])
        if any(a.get('statusCode') == 403 for c in calls for a in c.get('httpAttempts', [])):
            raise Challenge('Account host challenge; all further calls stopped')
        return result

    def stop(self):
        if self.process and self.process.returncode is None and not self.termination_requested:
            self.termination_requested = True
            try:
                self.process.terminate()
            except ProcessLookupError:
                pass

    async def close(self):
        if self.process and self.process.returncode is None:
            self.stop()
            try:
                await asyncio.wait_for(self.process.wait(), timeout=5)
            except asyncio.TimeoutError:
                self.process.kill()
                await self.process.wait()


async def one_case(case, trace, final_text, binary, config, stderr, case_index, audit=None):
    audit = audit or (lambda event: None)
    events = [r for r in trace if r['event'] == 'preview']
    stop_ms = next(r['elapsedMs'] for r in trace if r['event'] == 'audioEnd')
    warm = await Worker(binary, config, stderr, audit).start()
    try:
        final = await Worker(binary, config, stderr, audit).start()
    except BaseException:
        await warm.close()
        raise
    policy, pending, last, triggers = Schedule(), None, None, []
    started, at = time.perf_counter(), 0
    cancelled_at_stop = False
    attempt = None
    try:
        while (time.perf_counter() - started) * 1000 < stop_ms:
            now = (time.perf_counter() - started) * 1000
            if now >= stop_ms:
                break
            while at < len(events) and events[at]['elapsedMs'] <= now:
                policy.observe(events[at]['elapsedMs'], events[at]['text'])
                at += 1
            if pending and pending.done():
                result = await pending
                attempt.update(state=result['status'], responseMonotonic=result['responseMonotonic'])
                if result['status'] == 'completed':
                    last = dict(version=policy.count, source=policy.last_text, result=result)
                pending = None
            if policy.eligible(now, busy=pending is not None):
                version, source = policy.trigger(now)
                attempt = dict(id=f'{case}-warm-{version}', version=version, elapsedMs=now, source=source,
                               state='started', reason='v1:elapsed,length,800ms-stability,15s-interval,idle,quota')
                triggers.append(attempt)
                pending = asyncio.create_task(warm.call(f'{case}-warm-{version}', 'full', source))
            await asyncio.sleep(0.1)
        stopped = time.perf_counter()
        if pending and pending.done():
            result = await pending
            attempt.update(state=result['status'], responseMonotonic=result['responseMonotonic'])
            if result['status'] == 'completed' and result['responseMonotonic'] <= stopped:
                last = dict(version=policy.count, source=policy.last_text, result=result)
        elif pending:
            cancelled_at_stop = True
            attempt.update(state='cancelled', cancelledMonotonic=time.perf_counter())
            audit(dict(event='preheat-cancelled-at-stop', case=case, **attempt))
            pending.cancel()
        warm.stop()
        cancel_dispatch_ms = (time.perf_counter() - stopped) * 1000
        audit(dict(event='stop-and-final-source-available',case=case,monotonic=stopped,
                   cancellationDispatchMs=cancel_dispatch_ms))
        routes = ['baseline', 'reuse', 'patch']
        routes = routes[case_index % 3:] + routes[:case_index % 3]
        outputs = []
        for route in routes:
            began = time.perf_counter()
            record = dict(route=route, case=case, warmAvailable=last is not None,
                          finalASRDeliveredMonotonic=began,
                          stopCancellationDispatchMs=cancel_dispatch_ms if route!='baseline' else 0)
            result = None
            if route == 'reuse' and last:
                prepared = await final.call(f'{case}-prepare', 'prepare', final_text)
                if (prepared['input'] == last['result']['input'] and
                        prepared['contextSHA256'] == last['result']['contextSHA256']):
                    result = last['result']
                    record['reused'] = True
                else:
                    record['fallbackReason'] = 'final-input-or-context-differs'
            if route == 'patch' and last:
                patch = await final.call(f'{case}-patch', 'patch', final_text,
                    base=last['result']['text'], baseVersion=last['version'])
                record['patchResponse'] = patch
                if patch['status'] == 'completed':
                    try:
                        text, count = apply_versioned_patch(last['result']['text'], patch['text'], last['version'])
                        result = await final.call(f'{case}-postprocess', 'postprocess', final_text, base=text)
                        record['appliedEdits'] = count
                        if result['status'] != 'completed' or not result.get('text', '').strip():
                            result = None
                            record['fallbackReason'] = 'postprocess-failed-or-empty'
                    except (ValueError, TypeError, KeyError, UnicodeError) as error:
                        record['fallbackReason'] = type(error).__name__
                else:
                    record['fallbackReason'] = 'patch-request-failed'
            if result is None:
                if route != 'baseline' and not last:
                    record['fallbackReason'] = 'no-completed-preheat-at-stop'
                result = await final.call(f'{case}-{route}-full', 'full', final_text)
            record.update(status=result['status'], finalText=result.get('text', ''),
                          completeReadyMonotonic=time.perf_counter(),
                          editingReadyMs=(time.perf_counter() - began) * 1000 + record['stopCancellationDispatchMs'])
            outputs.append(record)
        return dict(case=case, scope='file trace and frozen historical ASR; not installed F5 timing',
            policy='v1', stopElapsedMs=(stopped - started) * 1000, traceStopMs=stop_ms,
            triggers=triggers, warmCalls=warm.calls, finalCalls=final.calls,
            workerPreparation=[warm.preparation, final.preparation],
            pendingWarmCancelled=cancelled_at_stop, outputs=outputs)
    finally:
        if pending and not pending.done():
            pending.cancel()
        if pending:
            await asyncio.gather(pending,return_exceptions=True)
        await warm.close()
        await final.close()


async def run(args):
    references = json.loads(args.references.read_text())
    if references.get('finalIntentApprovedCount') != 6 or any(c.get('finalIntentStatus') != 'user-approved' for c in references['cases']):
        raise ValueError('Approved intent references are required')
    sources = {c['id']: c['text'] for c in json.loads(args.suite.read_text())['cases']}
    if args.output.exists():
        raise FileExistsError('Keep prior results')
    os.umask(0o077)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    metadata = dict(scope='complete editing after frozen historical ASR; file replay, not F5 latency',
        model='gpt-6.1-terra', effort='none', policy='v1', independentCases=6,
        finalIntentApprovedCount=6, verbatimApprovedCount=0,
        hashes={name:hashlib.sha256(getattr(args,name).read_bytes()).hexdigest()
                for name in ['references','suite','config','binary']}, status='running')
    with args.output.with_suffix('.manifest.json').open('x') as manifest:
        json.dump(metadata,manifest,ensure_ascii=False,indent=2)
    with args.output.open('x') as output, args.output.with_suffix('.stderr.log').open('x') as stderr, args.output.with_suffix('.events.jsonl').open('x') as journal:
        def audit(event):
            journal.write(json.dumps(event,ensure_ascii=False)+'\n');journal.flush();os.fsync(journal.fileno())
        for index, case in enumerate(references['cases']):
            id = case['id']
            if args.case and id not in args.case:
                continue
            trace = [json.loads(line) for line in (args.traces / (id + '.jsonl')).read_text().splitlines()]
            if (trace[0].get('sourceAudioSHA256') != case['sourceAudioSHA256'] or
                    not trace[0].get('realTimePaced') or trace[-1]['event'] != 'completed'):
                raise ValueError('Complete real-time trace with matching source is required')
            row = await one_case(id, trace, sources[id], args.binary, args.config, stderr, index,audit)
            output.write(json.dumps(row, ensure_ascii=False) + '\n');output.flush();os.fsync(output.fileno())
            print(json.dumps(dict(case=id, warmCalls=len(row['triggers']),
                outputs=[{k:r[k] for k in ['route','status','editingReadyMs']} for r in row['outputs']])), flush=True)
    metadata['status']='complete'
    args.output.with_suffix('.manifest.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['references', 'suite', 'traces', 'binary', 'config', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--case', action='append')
    asyncio.run(run(parser.parse_args()))
