#!/usr/bin/env python3
"""Test Android dpkg install/upgrade/conffile backups/purge in an isolated App-owned root."""
import argparse
import json
import io
import tarfile
import time
import uuid
from pathlib import Path
from urllib.request import Request, ProxyHandler, build_opener
from urllib.parse import urlencode

parser = argparse.ArgumentParser()
parser.add_argument('base_url')
parser.add_argument('token_file')
args = parser.parse_args()
key = Path(args.token_file).read_text().strip()
opener = build_opener(ProxyHandler({}))
base = args.base_url.rstrip('/')

def request(route, body=None, raw=None):
    headers = {'Authorization': 'Bearer ' + key}
    data = raw
    if body is not None:
        headers['Content-Type'] = 'application/json'
        data = json.dumps(body).encode()
    with opener.open(Request(base + route, data=data, headers=headers), timeout=15) as response:
        return json.loads(response.read())

work = '/data/data/com.terminal/files/usr/tmp/dpkg-lifecycle-' + str(uuid.uuid4())
request('/api/files/mkdir', {'path': work})
try:
    def tar_bytes(entries):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:gz', format=tarfile.GNU_FORMAT) as archive:
            for name, content, kind, target in entries:
                entry = tarfile.TarInfo(name)
                entry.uid = entry.gid = entry.mtime = 0
                entry.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
                entry.type, entry.linkname = kind, target
                if kind == tarfile.REGTYPE:
                    entry.size = len(content)
                    archive.addfile(entry, io.BytesIO(content))
                else:
                    archive.addfile(entry)
        return output.getvalue()

    for version in ['1', '2']:
        control = ('Package: terminal-permissions-probe\nVersion: ' + version + '\nArchitecture: arm64\n'
                   'Maintainer: Terminal Tests <tests@example.invalid>\n'
                   'Description: isolated file and database backup fixture\n'
                   'X-Android-Bionic: yes\nX-Android-Min-API: 24\n'
                   'X-Terminal-Prefix: /data/data/com.terminal/files/usr\n').encode()
        ctrl = tar_bytes([('./control', control, tarfile.REGTYPE, ''),
                          ('./conffiles', b'/etc/terminal-probe.conf\n', tarfile.REGTYPE, '')])
        data = tar_bytes([
            (name, b'', tarfile.DIRTYPE, '') for name in ['./', './etc', './share', './share/terminal-probe']
        ] + [
            ('./etc/terminal-probe.conf', ('config-version-' + version + '\n').encode(), tarfile.REGTYPE, ''),
            ('./share/terminal-probe/source.txt', ('payload-version-' + version + '\n').encode(), tarfile.REGTYPE, ''),
            ('./share/terminal-probe/hardlink.txt', b'', tarfile.LNKTYPE, './share/terminal-probe/source.txt'),
            ('./share/terminal-probe/symlink.txt', b'', tarfile.SYMTYPE, 'source.txt'),
        ])
        # Write explicit tar link headers; proot simulates host link() with symlinks.
        deb = bytearray(b'!<arch>\n')
        for name, content in [('debian-binary', b'2.0\n'), ('control.tar.gz', ctrl), ('data.tar.gz', data)]:
            header = '%-16s%-12d%-6d%-6d%-8o%-10d`\n' % (name + '/', 0, 0, 0, 0o100644, len(content))
            assert len(header) == 60
            deb.extend(header.encode('ascii'))
            deb.extend(content)
            if len(content) % 2:
                deb.extend(b'\n')
        request('/api/upload?' + urlencode({'path': work + '/probe-' + version + '.deb'}), raw=bytes(deb))

    script = '''set -eu
work="WORK_PLACEHOLDER"
mkdir -p "$work/db" "$work/root"
: > "$work/db/status"
run_dpkg() {
    dpkg --admindir="$work/db" --instdir="$work/root" --log="$work/dpkg.log" \
        --force-not-root --force-script-chrootless "$@"
}
run_dpkg -i "$work/probe-1.deb"
printf 'payload-version-1\n' | cmp -s - "$work/root/share/terminal-probe/source.txt"
cmp -s "$work/root/share/terminal-probe/source.txt" "$work/root/share/terminal-probe/hardlink.txt"
test -L "$work/root/share/terminal-probe/symlink.txt"
printf 'user-modified-config\n' > "$work/root/etc/terminal-probe.conf"
run_dpkg --force-confnew -i "$work/probe-2.deb"
printf 'payload-version-2\n' | cmp -s - "$work/root/share/terminal-probe/source.txt"
cmp -s "$work/root/share/terminal-probe/source.txt" "$work/root/share/terminal-probe/hardlink.txt"
printf 'config-version-2\n' | cmp -s - "$work/root/etc/terminal-probe.conf"
printf 'user-modified-config\n' | cmp -s - "$work/root/etc/terminal-probe.conf.dpkg-old"
test -f "$work/db/status-old"
run_dpkg --purge terminal-permissions-probe
test ! -e "$work/root/share/terminal-probe/source.txt"
test ! -e "$work/root/share/terminal-probe/hardlink.txt"
test ! -L "$work/root/share/terminal-probe/symlink.txt"
test ! -e "$work/root/etc/terminal-probe.conf"
run_dpkg --audit
printf 'ISOLATED_DPKG_LIFECYCLE_OK uid=%s\n' "$(id -u)"
'''.replace('WORK_PLACEHOLDER', work)
    job = request('/api/exec', {'command': script, 'timeoutMs': 30000})
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        result = request('/api/jobs/' + job['id'])
        if not result['running']:
            break
        time.sleep(.2)
    print(result['stdout'])
    print(result['stderr'])
    assert not result['running'] and result['exitCode'] == 0, result
    assert 'ISOLATED_DPKG_LIFECYCLE_OK' in result['stdout']
    print('dpkg regular-file backups, archive hard links, conffile backups, database commits and purge passed')
finally:
    request('/api/files/delete', {'path': work, 'recursive': True})
    print('isolated dpkg fixture tree removed; live package database untouched')