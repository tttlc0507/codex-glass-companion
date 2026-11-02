"""Exercise installation transactions only in temporary folders, never the user's Library."""
import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def load_installer():
    path=Path(__file__).resolve().parents[1]/'scripts/install.py'
    spec=importlib.util.spec_from_file_location('isolated_installer',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


class InstallTransactionTests(unittest.TestCase):
    def exercise(self, fail_bootstrap):
        module=load_installer()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);support=root/'support';support.mkdir()
            target=support/'app.app';source=root/'source.app'
            for app,marker in [(target,'old'),(source,'new')]:
                (app/'Contents/Resources').mkdir(parents=True)
                (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':module.APP_ID}))
                (app/'marker').write_text(marker)
                (app/'Contents/Resources/CompanionWatch').write_text(marker)
            watcher=support/'CompanionWatch';watcher.write_text('old-watcher')
            agent=root/'agents/companion.plist';agent.parent.mkdir();agent.write_text('old-agent')
            failures=[]
            def run(arguments,check=True):
                args=list(map(str,arguments))
                if args[:2]==['launchctl','bootstrap'] and fail_bootstrap and not failures:
                    failures.append(True)
                    raise subprocess.CalledProcessError(1,args)
                output='state = running' if args[:2]==['launchctl','print'] else '{"companions":[],"chatgpt_running":false}'
                return subprocess.CompletedProcess(args,0,output,'')
            with patch.multiple(module,SUPPORT=support,TARGET=target,AGENT=agent,DOMAIN='gui/test',SERVICE='gui/test/companion'), patch.object(module,'run',side_effect=run):
                with contextlib.redirect_stdout(io.StringIO()):
                    if fail_bootstrap:
                        with self.assertRaises(subprocess.CalledProcessError):module.install(source)
                    else:
                        module.install(source)
            if fail_bootstrap:
                self.assertEqual((target/'marker').read_text(),'old')
                self.assertEqual(watcher.read_text(),'old-watcher')
                self.assertEqual(agent.read_text(),'old-agent')
            else:
                self.assertEqual((target/'marker').read_text(),'new')
                self.assertEqual((support/'.previous-companion.app/marker').read_text(),'old')
                self.assertEqual(plistlib.loads(agent.read_bytes())['ProgramArguments'][2],str(target))

    def test_failed_startup_restores_previous_app_watcher_and_agent(self):
        self.exercise(True)

    def test_success_keeps_backup_and_installs_matching_launch_configuration(self):
        self.exercise(False)
