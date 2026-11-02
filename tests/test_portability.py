import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch
from companion_backend import Bridge, Rollouts, find_codex, windows


class PortabilityTests(unittest.TestCase):
    def test_cli_override_and_missing_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory)/'codex'
            executable.write_text('#!/bin/sh\nexit 0\n')
            executable.chmod(0o755)
            with patch.dict(os.environ, {'COMPANION_CODEX_CLI':str(executable)}):
                self.assertEqual(find_codex(), str(executable))
            executable.chmod(0o644)
            with patch.dict(os.environ, {'COMPANION_CODEX_CLI':str(executable)}):
                self.assertIsNone(find_codex())

    def test_schema_without_optional_name_source_and_archived_columns(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            log = home/'test.jsonl'
            log.write_text(json.dumps({'timestamp':'2026-11-02T12:00:00Z','type':'event_msg','payload':{'type':'task_complete'}})+'\n')
            db = sqlite3.connect(home/'state_6.sqlite')
            db.execute('create table threads(id,title,rollout_path,updated_at)')
            db.execute('insert into threads values (?,?,?,?)', ('test','A public example',str(log),time.time()))
            db.commit();db.close()
            (home/'state_other.sqlite').touch()
            result = Bridge(home).snapshot()
            self.assertIsNone(result['task_error'])
            self.assertEqual(result['recent'][0]['title'], 'A public example')

    def test_missing_database_reports_unavailable_instead_of_fake_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            result = Bridge(directory).snapshot()
            self.assertIsNotNone(result['task_error'])
            self.assertEqual(result['indicator']['state'], 'idle')
            self.assertIsNone(result['windows'][0]['remaining'])

    def test_malformed_quota_is_unknown(self):
        for used in ['invalid', 'NaN', 'Infinity', None, {}]:
            self.assertIsNone(windows({'limits':{'primary':{'usedPercent':used}}})[0]['remaining'])

    def test_malformed_rollout_payload_does_not_stop_following(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory)/'test.jsonl'
            log.write_text('\n'.join(map(json.dumps,[[], {'type':'event_msg','payload':[]},
                {'type':'event_msg','payload':{'type':'task_started'}}]))+'\n')
            self.assertTrue(Rollouts().read(str(log))['running'])

    def test_confirmation_beyond_four_cards_is_visible_first(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory);db=sqlite3.connect(home/'state_5.sqlite')
            db.execute('create table threads(id,title,rollout_path,updated_at)')
            for i in range(6):
                log=home/(str(i)+'.jsonl')
                events=[{'timestamp':'2026-11-02T12:00:00Z','type':'event_msg','payload':{'type':'task_started'}}]
                if i==5:
                    events.append({'type':'response_item','payload':{'type':'function_call','name':'request_user_input_async','call_id':'q','arguments':'{}'}})
                log.write_text('\n'.join(map(json.dumps,events))+'\n')
                db.execute('insert into threads values (?,?,?,?)',(str(i),'Example '+str(i),str(log),time.time()-i))
            db.commit();db.close()
            result=Bridge(home).snapshot()
            self.assertEqual(result['indicator']['state'],'attention')
            self.assertEqual(result['tasks'][0]['id'],'5')


class InstallConfigurationTests(unittest.TestCase):
    def test_launch_agent_is_per_user_and_event_driven(self):
        path=Path(__file__).resolve().parents[1]/'scripts/install.py'
        spec=importlib.util.spec_from_file_location('companion_install',path)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        config=module.configuration()
        self.assertTrue(config['RunAtLoad'])
        self.assertNotIn('StartInterval',config)
        self.assertEqual(config['ProgramArguments'][1],'--watch')
        self.assertTrue(str(module.SUPPORT).startswith(str(Path.home())))


if __name__=='__main__':
    unittest.main()
