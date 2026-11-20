"""Fail-closed Seatbelt containment for commands and MCP processes on macOS."""
import json, os, pathlib, shutil, sys

def quote(path):return json.dumps(str(path))
def roots(paths):
    result=[]
    for path in paths:
        p=pathlib.Path(path).expanduser().resolve()
        if not p.is_dir():raise ValueError('Sandbox folder does not exist: '+str(p))
        if str(p)=='/':raise ValueError('Filesystem root cannot be granted to a sandbox')
        result.append(p)
    return result

def launch(command,workspace,read_roots=(),write_roots=(),network=False,escalated=False):
    if sys.platform!='darwin' or not pathlib.Path('/usr/bin/sandbox-exec').is_file():
        raise ValueError('macOS sandbox-exec is unavailable; command execution denied')
    workspace=pathlib.Path(workspace).resolve()
    reads=roots(read_roots); writes=roots([workspace,*write_roots])
    if escalated:
        # Explicit single-action approval removes filesystem containment only.
        # Offline still denies networking for this process and its descendants.
        policy='(version 1)(allow default)'+('' if network else '(deny network*)')
    else:
        policy='(version 1)(deny default)(allow process*)(allow signal (target self))(allow sysctl-read)(allow mach-lookup (global-name "com.apple.system.logger") (global-name "com.apple.system.notification_center") (global-name "com.apple.trustd"))(allow file-read-metadata)(allow file-read-data (literal "/"))'
        for path in ['/System','/usr/lib','/usr/share','/usr/bin','/bin','/sbin','/usr/sbin','/Library/Apple','/opt/homebrew/bin','/opt/homebrew/lib','/opt/homebrew/Cellar','/opt/homebrew/opt','/usr/local/bin','/usr/local/lib','/private/var/db/timezone',str(pathlib.Path(sys.prefix).resolve())]:
            policy+='(allow file-read* (subpath '+quote(path)+'))'
        for path in ['/private/etc/ssl/openssl.cnf','/private/etc/ssl/cert.pem','/private/etc/hosts','/private/etc/resolv.conf']:
            policy+='(allow file-read* (literal '+quote(path)+'))'
        executable=shutil.which(command[0]) or command[0]
        policy+='(allow file-read* (literal '+quote(pathlib.Path(executable).resolve())+'))'
        # /dev/null and entropy only; no arbitrary devices or home paths.
        policy+='(allow file-read* file-write* (literal "/dev/null"))(allow file-read* (literal "/dev/urandom")(literal "/dev/random"))'
        for path in reads+writes:policy+='(allow file-read* (subpath '+quote(path)+'))'
        for path in writes:policy+='(allow file-write* (subpath '+quote(path)+'))'
        if network:policy+='(allow network*)'
    env={'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(workspace),'TMPDIR':str(workspace),'LANG':'en_US.UTF-8'}
    return ['/usr/bin/sandbox-exec','-p',policy,*command],env
