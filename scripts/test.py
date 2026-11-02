"""Run isolated data tests and native appearance/geometry regression checks."""
from pathlib import Path
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
environment = os.environ.copy()
environment['PYTHONPATH'] = str(root/'src')
subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', str(root/'tests'), '-v'], env=environment, check=True)
(root/'build/tests').mkdir(parents=True, exist_ok=True)
for name in ('native', 'corners'):
    binary = root/'build/tests'/name
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Cocoa', '-framework', 'QuartzCore',
                    '-mmacosx-version-min=14.0', str(root/'tests'/('test_'+name+'.m')), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
