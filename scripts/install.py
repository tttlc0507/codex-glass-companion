"""Install the per-user app and event-driven Codex launch follower; never uses sudo."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

APP_ID = 'local.companion.hover'
LABEL = 'local.companion.hover.follow-chatgpt'
SUPPORT = Path.home()/'Library/Application Support/CompanionHover'
TARGET = SUPPORT/'悬浮助手.app'  # Keep the existing installation and saved preferences compatible.
AGENT = Path.home()/'Library/LaunchAgents'/(LABEL+'.plist')
DOMAIN = 'gui/'+str(os.getuid())
SERVICE = DOMAIN+'/'+LABEL


def run(arguments, check=True):
    return subprocess.run([str(x) for x in arguments], capture_output=True, text=True, check=check)


def bundle_id(app):
    with (app/'Contents/Info.plist').open('rb') as stream:
        return plistlib.load(stream).get('CFBundleIdentifier')


def configuration():
    return {'Label':LABEL, 'ProgramArguments':[str(SUPPORT/'CompanionWatch'), '--watch', str(TARGET)],
            'RunAtLoad':True, 'KeepAlive':True, 'ProcessType':'Background', 'ThrottleInterval':10,
            'LimitLoadToSessionType':'Aqua', 'StandardOutPath':str(SUPPORT/'follow.log'),
            'StandardErrorPath':str(SUPPORT/'follow-errors.log')}


def default_source():
    script = Path(__file__).resolve()
    for path in [script.parent/'CompanionHover.app', script.parents[1]/'build/CompanionHover.app']:
        if path.exists():
            return path
    raise FileNotFoundError('Build first with make build, or keep install.py beside the release app.')


def disable():
    run(['launchctl', 'bootout', SERVICE], check=False)
    AGENT.unlink(missing_ok=True)


def install(source):
    watcher = source/'Contents/Resources/CompanionWatch'
    if bundle_id(source) != APP_ID or not watcher.is_file():
        raise RuntimeError('This is not a complete CompanionHover release app.')
    if TARGET.exists() and bundle_id(TARGET) != APP_ID:
        raise RuntimeError('The installation path belongs to another app; nothing was replaced.')
    run(['codesign', '--verify', '--deep', '--strict', source])
    old_agent = AGENT.read_bytes() if AGENT.exists() else None
    old_watcher = (SUPPORT/'CompanionWatch').read_bytes() if (SUPPORT/'CompanionWatch').exists() else None
    SUPPORT.mkdir(parents=True, exist_ok=True)
    AGENT.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix='.install-', dir=SUPPORT))
    previous = SUPPORT/'.previous-companion.app'
    replaced = False
    moved_old = False
    try:
        shutil.copytree(source, temporary/'app')
        run(['codesign', '--verify', '--deep', '--strict', temporary/'app'])
        run(['launchctl', 'bootout', SERVICE], check=False)
        run([watcher, '--quit-companion'])
        for _ in range(20):
            if not json.loads(run([watcher, '--status']).stdout)['companions']:
                break
            time.sleep(.2)
        else:
            raise RuntimeError('Close the companion and retry; the installed app was not replaced.')
        if TARGET.exists():
            if previous.exists():
                if bundle_id(previous) != APP_ID:
                    raise RuntimeError('The backup path belongs to another application.')
                shutil.rmtree(previous)
            TARGET.rename(previous)
            moved_old = True
        (temporary/'app').rename(TARGET)
        replaced = True
        shutil.copy2(watcher, temporary/'CompanionWatch')
        os.chmod(temporary/'CompanionWatch', 0o755)
        os.replace(temporary/'CompanionWatch', SUPPORT/'CompanionWatch')
        staged = AGENT.with_suffix('.staging')
        staged.write_bytes(plistlib.dumps(configuration()))
        os.chmod(staged, 0o644)
        os.replace(staged, AGENT)
        run(['plutil', '-lint', AGENT])
        run(['launchctl', 'enable', SERVICE])
        run(['launchctl', 'bootstrap', DOMAIN, AGENT])
        verified = None
        for _ in range(20):
            packet = json.loads(run([SUPPORT/'CompanionWatch', '--status']).stdout)
            ours = [app for app in packet['companions'] if app['path'] == str(TARGET)]
            if bool(ours) == bool(packet['chatgpt_running']):
                verified = packet
                break
            time.sleep(.5)
        if verified is None or 'state = running' not in run(['launchctl', 'print', SERVICE]).stdout:
            raise RuntimeError('Launch synchronization did not start correctly.')
        print(json.dumps({'installed':True, 'app':str(TARGET), **verified}, ensure_ascii=False, indent=2))
    except Exception:
        run(['launchctl', 'bootout', SERVICE], check=False)
        if replaced and TARGET.exists():
            shutil.rmtree(TARGET)
        if moved_old and previous.exists():
            previous.rename(TARGET)
        if old_watcher is not None:
            (SUPPORT/'CompanionWatch').write_bytes(old_watcher)
            os.chmod(SUPPORT/'CompanionWatch', 0o755)
        else:
            (SUPPORT/'CompanionWatch').unlink(missing_ok=True)
        if old_agent is not None:
            AGENT.write_bytes(old_agent)
            run(['launchctl', 'bootstrap', DOMAIN, AGENT], check=False)
        else:
            AGENT.unlink(missing_ok=True)
        raise
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, help='App bundle to install')
    parser.add_argument('--preview', action='store_true', help='Print launch configuration without changing anything')
    parser.add_argument('--disable', action='store_true', help='Remove launch synchronization; keep the app')
    parser.add_argument('--uninstall', action='store_true', help='Remove the installed app and launch synchronization; keep preferences')
    args = parser.parse_args()
    if args.preview:
        print(plistlib.dumps(configuration()).decode())
    elif args.disable or args.uninstall:
        if args.uninstall and TARGET.exists() and bundle_id(TARGET) != APP_ID:
            raise RuntimeError('Refusing to remove another application.')
        disable()
        if args.uninstall:
            watcher = SUPPORT/'CompanionWatch'
            if watcher.exists():
                run([watcher, '--quit-companion'])
            if TARGET.exists():
                shutil.rmtree(TARGET)
            watcher.unlink(missing_ok=True)
            backup = SUPPORT/'.previous-companion.app'
            if backup.exists() and bundle_id(backup) == APP_ID:
                shutil.rmtree(backup)
        print('Launch synchronization removed. Codex data and companion preferences were kept.')
    else:
        install((args.app or default_source()).expanduser().resolve())


if __name__ == '__main__':
    main()
