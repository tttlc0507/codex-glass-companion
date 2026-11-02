"""Create a release archive and SHA-256 checksum; do not commit build artifacts."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
from build import ROOT, VERSION, build

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--arch', choices=['universal', 'arm64', 'x86_64'], default='universal')
    args = parser.parse_args()
    app = build(args.arch)
    name = 'codex-glass-companion-v'+VERSION+'-macos-'+args.arch
    staging = ROOT/'build'/name
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir()
    shutil.copytree(app, staging/'CompanionHover.app')
    shutil.copy2(ROOT/'scripts/install.py', staging/'install.py')
    shutil.copy2(ROOT/'docs/INSTALL.md', staging/'INSTALL.md')
    shutil.copy2(ROOT/'LICENSE', staging/'LICENSE')
    dist = ROOT/'dist'
    dist.mkdir(exist_ok=True)
    archive = dist/(name+'.zip')
    if archive.exists():
        archive.unlink()
    subprocess.run(['ditto', '-c', '-k', '--norsrc', '--keepParent', str(staging), str(archive)], check=True)
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    (dist/'SHA256SUMS').write_text(checksum+'  '+archive.name+'\n')
    print(archive)
