import json
import sqlite3
import tempfile
import time
import unittest
from pathlib import Path
from companion_backend import Bridge, Rollouts, windows, activity_indicator


class BridgeTests(unittest.TestCase):
    def test_indicator_priority_completion_expiry_and_abort(self):
        running={'status':'正在处理'}
        waiting={'status':'等待你确认','waiting':True}
        self.assertEqual(activity_indicator([running]*4+[waiting],[])['state'],'attention')
        self.assertEqual(activity_indicator([running],[])['state'],'running')
        completed={'terminal':'completed','completed_at':100,'updated_at':100}
        self.assertEqual(activity_indicator([],[completed],now=130)['state'],'completed')
        self.assertEqual(activity_indicator([],[completed],now=161)['state'],'idle')
        stopped={'terminal':'stopped','updated_at':120}
        self.assertEqual(activity_indicator([],[completed,stopped],now=130)['state'],'idle')
        self.assertEqual(activity_indicator([{'status':'状态待确认'}],[])['state'],'idle')
        self.assertEqual(activity_indicator([running],[],error='offline')['state'],'idle')

    def test_async_question_stays_yellow_until_all_answers(self):
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'rollout.jsonl'
            reader=Rollouts()
            def append(payload,kind='response_item'):
                with file.open('a') as stream:
                    stream.write(json.dumps({'type':kind,'payload':payload})+'\n')
                return reader.read(str(file))
            append({'type':'task_started'},'event_msg')
            append({'type':'function_call','name':'request_user_input_async','call_id':'q1',
                    'arguments':json.dumps({'questions':[{'title':'A'},{'title':'B'}]})})
            append({'type':'function_call_output','call_id':'q1','output':'{"accepted":true}'})
            state=append({'type':'task_complete'},'event_msg')
            self.assertTrue(state['pending_inputs'])
            def reply(index):
                return {'type':'message','role':'user','content':[{'type':'input_text','text':
                    '<send_user_message_question_reply>'+json.dumps([{
                        'questionItemId':json.dumps(['request_user_input_async','q1',index]),
                        'answer':'yes'}])+'</send_user_message_question_reply>'}]}
            self.assertTrue(append(reply(0))['pending_inputs'])
            self.assertFalse(append(reply(1))['pending_inputs'])

    def test_sync_confirmation_error_and_free_text_clear_waiting(self):
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'rollout.jsonl';reader=Rollouts()
            def append(payload,kind='response_item'):
                with file.open('a') as stream:stream.write(json.dumps({'type':kind,'payload':payload})+'\n')
                return reader.read(str(file))
            for name in ['request_user_input','request_permissions','request_user_input_async']:
                state=append({'type':'function_call','name':name,'call_id':name,'arguments':'{}'})
                self.assertTrue(state['pending_inputs'])
                state=append({'type':'function_call_output','call_id':name,'output':'{"error":"unavailable"}'})
                self.assertFalse(state['pending_inputs'])
            append({'type':'function_call','name':'request_user_input_async','call_id':'q','arguments':'{}'})
            self.assertFalse(append({'type':'message','role':'user','content':'继续吧'})['pending_inputs'])
            append({'type':'function_call','name':'request_user_input_async','call_id':'q2','arguments':'{}'})
            self.assertFalse(append({'type':'turn_aborted'},'event_msg')['pending_inputs'])

    def test_remaining_is_inverse_of_used(self):
        actual=windows({'limits':{'primary':{'usedPercent':27},'secondary':{'used_percent':4}}})
        self.assertEqual([x['remaining'] for x in actual],[73,96])

    def test_missing_is_unknown_and_never_zero(self):
        self.assertIsNone(windows(None)[0]['remaining'])
        self.assertEqual(windows({'limits':{'primary':{'usedPercent':100}}})[0]['remaining'],0)

    def test_clamps_invalid_percent_and_preserves_reset(self):
        value=windows({'limits':{'primary':{'usedPercent':-4,'resetsAt':123}}})[0]
        self.assertEqual(value['remaining'],100)
        self.assertEqual(value['resets_at'],123)

    def test_does_not_mislabel_a_changed_window(self):
        actual=windows({'limits':{'primary':{'usedPercent':1,'windowDurationMins':60}}})
        self.assertEqual(actual[0]['label'],'60 分钟')

    def test_partial_json_and_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'rollout.jsonl'
            line=json.dumps({'timestamp':'2026-10-29T12:00:00Z','type':'event_msg','payload':{'type':'task_started'}})
            file.write_text(line[:40])
            reader=Rollouts()
            self.assertFalse(reader.read(str(file))['running'])
            with file.open('a') as stream:stream.write(line[40:]+'\n')
            self.assertTrue(reader.read(str(file))['running'])
            with file.open('a') as stream:stream.write(json.dumps({'type':'event_msg','payload':{'type':'task_complete'}})+'\n')
            self.assertFalse(reader.read(str(file))['running'])

    def test_rotated_rollout_resets_cached_state(self):
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'rollout.jsonl'
            file.write_text(json.dumps({'type':'event_msg','payload':{'type':'task_started'}})+'\n')
            reader=Rollouts()
            self.assertTrue(reader.read(str(file))['running'])
            file.write_text('{}\n')
            self.assertFalse(reader.read(str(file))['running'])

    def test_guardian_excluded_and_completed_thread_moves_to_recent(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory)
            db=sqlite3.connect(home/'state_5.sqlite')
            db.execute('create table threads(id,name,title,rollout_path,updated_at,source,archived)')
            file=home/'a.jsonl'
            file.write_text(json.dumps({'type':'event_msg','payload':{'type':'task_complete'}})+'\n')
            db.executemany('insert into threads values (?,?,?,?,?,?,0)',[
                ('user','用户任务','',str(file),time.time(),'vscode'),
                ('guardian','Guardian review','',str(file),time.time(),'{"subagent":{"other":"guardian"}}')])
            db.commit();db.close()
            result=Bridge(home).snapshot()
            self.assertEqual(result['tasks'],[])
            self.assertEqual([x['id'] for x in result['recent']],['user'])
            self.assertIsNone(result['task_error'])


if __name__=='__main__':unittest.main()
