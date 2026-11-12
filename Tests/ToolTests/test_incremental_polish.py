import importlib.util
from pathlib import Path
import json
import sys
import unittest

scripts=Path(__file__).resolve().parents[2]/'scripts'
sys.path.insert(0,str(scripts))
spec=importlib.util.spec_from_file_location('incremental',scripts/'evaluate_incremental_polish.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class IncrementalProtocolTests(unittest.TestCase):
    def patch(self, edits, version=2):
        return json.dumps({'schema':1,'base_version':version,'edits':edits},ensure_ascii=False)
    def test_unicode_anchor_and_append_are_atomic(self):
        source='保留 MCP🙂，周五开。'
        result,count=m.apply_versioned_patch(source,self.patch([{'old':'MCP🙂','new':'MCP🙂'}, {'old':'周五开。','new':'周六15:00开。继续。'}]),2)
        self.assertEqual(result,'保留 MCP🙂，周六15:00开。继续。');self.assertEqual(count,2)
    def test_bad_identity_ambiguous_overlapping_and_empty_anchors_rejected(self):
        bad=[self.patch([],3), self.patch([{'old':'MCP','new':'x'}]), self.patch([{'old':'','new':'x'}]), self.patch([{'old':'MCP MCP','new':'x'},{'old':'P MCP','new':'y'}])]
        for payload in bad:
            with self.subTest(payload=payload),self.assertRaises(ValueError):m.apply_versioned_patch('MCP MCP',payload,2)
    def test_duplicate_unknown_fields_and_surrogates_rejected(self):
        for payload in ['{"schema":1,"base_version":2,"edits":[],"extra":0}', '{"schema":1,"schema":1,"base_version":2,"edits":[]}', self.patch([{'old':'a','new':'\ud800'}])]:
            with self.subTest(payload=repr(payload)),self.assertRaises((ValueError,UnicodeError)):m.apply_versioned_patch('a',payload,2)
    def test_causal_schedule_requires_observed_stability_and_respects_quota(self):
        policy=m.Schedule();policy.observe(3500,'一'*24)
        self.assertFalse(policy.eligible(4000));self.assertTrue(policy.eligible(4300))
        policy.trigger(4300);policy.observe(4400,'二'*25)
        self.assertFalse(policy.eligible(19000));self.assertFalse(policy.eligible(19300,busy=True));self.assertTrue(policy.eligible(19300))
        policy.count=8;self.assertFalse(policy.eligible(60000))

class IncrementalCancellationTests(unittest.IsolatedAsyncioTestCase):
    async def test_stop_cancels_preheat_without_waiting_for_worker_cleanup(self):
        import asyncio
        from unittest.mock import patch
        original_sleep=asyncio.sleep
        class Clock:
            value=0.0
        clock=Clock()
        async def sleep(seconds):
            clock.value+=seconds
            await original_sleep(0)
        class FakeWorker:
            def __init__(self,*args):
                self.calls=[];self.preparation={};self.stopped=False
            async def start(self):return self
            async def call(self,id,mode,text,**kwargs):
                if '-warm-' in id:
                    await asyncio.Event().wait()
                result=dict(id=id,status='completed',text='完整结果',responseMonotonic=clock.value)
                self.calls.append(result);return result
            def stop(self):self.stopped=True
            async def close(self):
                await sleep(5)
        with patch.object(m,'Worker',FakeWorker),patch.object(m.time,'perf_counter',lambda:clock.value),patch.object(m.asyncio,'sleep',sleep):
            row=await m.one_case('case',[{'event':'preview','elapsedMs':0,'text':'一'*24},{'event':'audioEnd','elapsedMs':5000}], '完整原文',None,None,None,0)
        self.assertEqual(len(row['triggers']),1)
        self.assertTrue(row['pendingWarmCancelled'])
        self.assertEqual(row['triggers'][0]['state'],'cancelled')
        first=row['outputs'][0]
        self.assertAlmostEqual(first['finalASRDeliveredMonotonic'],row['stopElapsedMs']/1000,places=6)
        self.assertEqual(first['editingReadyMs'],0)
    async def test_wrong_worker_identity_records_failed_terminal_event(self):
        from types import SimpleNamespace
        class Input:
            def write(self,data):pass
            async def drain(self):pass
        class Output:
            async def readline(self):return b'{"id":"wrong"}\n'
        events=[]
        worker=m.Worker(None,None,None,events.append)
        worker.process=SimpleNamespace(stdin=Input(),stdout=Output(),pid=42)
        with self.assertRaises(RuntimeError):await worker.call('expected','full','test')
        self.assertEqual([e['event'] for e in events],['request-start','request-failed'])
