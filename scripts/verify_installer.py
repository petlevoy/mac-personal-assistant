"""Verify the final read-only DMG, then a copy launched by LaunchServices."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile

image = pathlib.Path(sys.argv[1]).resolve()
report = pathlib.Path(sys.argv[2]).resolve()

def check_signature(app):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], check=True)

with tempfile.TemporaryDirectory(prefix='personal-assistant-dmg-') as mount_dir:
    mounted = False
    try:
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount_dir, str(image)], check=True)
        mounted = True
        source = pathlib.Path(mount_dir) / 'Inij.app'
        check_signature(source)
        # Use Applications location, but a unique container so no user app can be overwritten.
        with tempfile.TemporaryDirectory(prefix='PersonalAssistant-CI-', dir='/Applications') as install_dir:
            installed = pathlib.Path(install_dir) / 'Inij.app'
            subprocess.run(['ditto', str(source), str(installed)], check=True)
            check_signature(installed)
            verify = pathlib.Path(__file__).with_name('verify_native.py')
            subprocess.run([sys.executable, '-I', '-B', str(verify), str(installed), str(report), '--launchservices'], check=True)
            check_signature(installed)
            print('Installed LaunchServices open and signature after runtime: PASS')
        check_signature(source)
    finally:
        if mounted:
            subprocess.run(['hdiutil', 'detach', mount_dir], check=True)
print('Final DMG mounted read-only, installed copy launched and signatures intact: PASS')
