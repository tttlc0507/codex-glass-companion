"""Build a signed local app. No network or third-party Python packages."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VERSION = (ROOT/'VERSION').read_text().strip()
APP_ID = 'local.companion.hover'


def build(architecture='native', demo=False):
    app = ROOT/'build'/('CompanionHoverDemo.app' if demo else 'CompanionHover.app')
    mac, resources = app/'Contents/MacOS', app/'Contents/Resources'
    mac.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    architectures = ['arm64', 'x86_64'] if architecture == 'universal' else ([] if architecture == 'native' else [architecture])
    flags = [part for arch in architectures for part in ['-arch', arch]]
    for source, target, frameworks in [
        ('CompanionHover.m', mac/'CompanionHover', ['Cocoa', 'QuartzCore']),
        ('CompanionWatch.m', resources/'CompanionWatch', ['Cocoa']),
    ]:
        command = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-mmacosx-version-min=14.0', *flags]
        for framework in frameworks:
            command += ['-framework', framework]
        subprocess.run(command+[str(ROOT/'src'/source), '-o', str(target)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True)
    shutil.copy2(ROOT/'src/companion_backend.py', resources/'companion_backend.py')
    info = {'CFBundleExecutable':'CompanionHover', 'CFBundleIdentifier':APP_ID+('.demo' if demo else ''),
            'CFBundleName':'CompanionHover', 'CFBundleDisplayName':'悬浮助手',
            'CFBundleVersion':VERSION, 'CFBundleShortVersionString':VERSION,
            'CFBundlePackageType':'APPL', 'LSUIElement':True, 'LSMinimumSystemVersion':'14.0',
            'NSHighResolutionCapable':True, 'NSPrincipalClass':'NSApplication'}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    return app


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--arch', choices=['native', 'universal', 'arm64', 'x86_64'], default='native')
    parser.add_argument('--demo', action='store_true')
    options = parser.parse_args()
    print(build(options.arch, options.demo))
