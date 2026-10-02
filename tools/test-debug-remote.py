#!/usr/bin/env python3
"""Device API regression against unique temporary files; never touch existing user files."""
import argparse
import hashlib
import json
import time
import uuid
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, ProxyHandler, build_opener
from urllib.error import HTTPError

parser = argparse.ArgumentParser()
parser.add_argument('base_url')
parser.add_argument('token_file')
args = parser.parse_args()
token = Path(args.token_file).read_text().strip()
opener = build_opener(ProxyHandler({}))
base = args.base_url.rstrip('/')

def api(route, body=None, code=200, query=None, auth=True, extra_headers=None):
    if query:
        route += '?' + urlencode(query)
    headers = {'Authorization': 'Bearer ' + token} if auth else {}
    if extra_headers:
        headers.update(extra_headers)
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
    if data is not None:
        headers['Content-Type'] = 'application/json'
    request = Request(base + route, data=data, headers=headers)
    try:
        response = opener.open(request, timeout=20)
        actual = response.status
        content = response.read()
    except HTTPError as error:
        actual, content = error.code, error.read()
    assert actual == code, (route, actual, content.decode(errors='replace')[:800])
    return json.loads(content)

def command(text, timeout=5000):
    job = api('/api/exec', {'command': text, 'timeoutMs': timeout}, code=202)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        result = api('/api/jobs/' + job['id'])
        if not result['running']:
            return result
        time.sleep(.15)
    raise AssertionError('job failed to finish')

api('/api/status', code=401, auth=False)
api('/api/status', code=403, extra_headers={'Origin': 'http://unrelated.example'})
status = api('/api/status')
assert status['prefix'] == '/data/data/com.terminal/files/usr'
assert status['uid'] > 10000
permission = api('/api/permissions')
assert not permission['issues'], permission
print('authentication, origin rejection, private paths and permission audit passed')

result = command("printf 'command-ok\\n'; printf 'stderr-ok\\n' >&2; exit 7")
assert result['stdout'] == 'command-ok\n' and result['stderr'] == 'stderr-ok\n' and result['exitCode'] == 7, result
result = command('sleep 10', timeout=300)
assert result['timedOut'] and not result['running'], result
job = api('/api/exec', {'command': 'sleep 10', 'timeoutMs': 15000}, code=202)
api('/api/jobs/' + job['id'] + '/cancel', {})
time.sleep(.4)
assert api('/api/jobs/' + job['id'])['cancelled']
print('remote stdout/stderr, exit code, timeout and cancellation passed')

suffix = str(uuid.uuid4())
internal = '/data/data/com.terminal/files/usr/tmp/remote-api-test-' + suffix
external = '/storage/emulated/0/Download/remote-api-test-' + suffix
created = []
try:
    for directory in [internal, external]:
        api('/api/files/mkdir', {'path': directory})
        created.append(directory)
    text = '远程文件测试\nwith spaces and unicode\n'
    source = internal + '/测试 file.txt'
    output = api('/api/files/write', {'path': source, 'text': text})
    assert output['sha256'] == hashlib.sha256(text.encode()).hexdigest()
    read = api('/api/files/read', query={'path': source})
    assert read['text'] == text
    api('/api/files/write', {'path': source, 'text': 'conflict'}, code=409)
    api('/api/files/write', {'path': source, 'text': 'conflict', 'overwrite': True, 'sha256': '0' * 64}, code=409)
    updated = text + 'edited\n'
    api('/api/files/write', {'path': source, 'text': updated, 'overwrite': True, 'sha256': read['sha256']})
    assert api('/api/files/read', query={'path': source})['text'] == updated
    api('/api/files/copy', {'source': source, 'destination': external + '/out.txt'})
    assert api('/api/files/read', query={'path': external + '/out.txt'})['text'] == updated
    api('/api/files/copy', {'source': external + '/out.txt', 'destination': internal + '/back.txt'})
    api('/api/files/move', {'source': internal + '/back.txt', 'destination': external + '/moved-out.txt'})
    api('/api/files/read', query={'path': internal + '/back.txt'}, code=404)
    api('/api/files/move', {'source': external + '/moved-out.txt', 'destination': internal + '/moved-in.txt'})
    assert api('/api/files/read', query={'path': internal + '/moved-in.txt'})['text'] == updated
    tree = internal + '/tree'
    api('/api/files/mkdir', {'path': tree})
    api('/api/files/write', {'path': tree + '/a.txt', 'text': updated})
    api('/api/files/copy', {'source': tree, 'destination': external + '/tree'})
    api('/api/files/move', {'source': external + '/tree', 'destination': internal + '/tree-back'})
    assert api('/api/files/read', query={'path': internal + '/tree-back/a.txt'})['text'] == updated
    api('/api/files/copy', {'source': tree, 'destination': tree + '/nested'}, code=400)
    api('/api/files/delete', {'path': tree}, code=409)
    api('/api/files', query={'path': '/data/data/com.other'}, code=403)
    api('/api/files/delete', {'path': '/data/data/com.terminal/files', 'recursive': True}, code=403)
    entries = api('/api/files', query={'path': internal})['entries']
    assert any(entry['name'] == '测试 file.txt' for entry in entries)
    response = opener.open(Request(base + '/api/file?' + urlencode({'path': source}), headers={'Authorization': 'Bearer ' + token}), timeout=10)
    assert response.read() == updated.encode()
    binary = bytes(range(256)) * 8
    upload = Request(base + '/api/upload?' + urlencode({'path': internal + '/binary.dat'}), data=binary, headers={'Authorization': 'Bearer ' + token})
    assert opener.open(upload, timeout=10).status == 200
    read = api('/api/files/read', query={'path': internal + '/binary.dat'})
    assert read['sha256'] == hashlib.sha256(binary).hexdigest()
    print('file read/write/list/upload/download, conflicts, root protection and bidirectional cross-storage copy/move passed')
finally:
    for directory in reversed(created):
        api('/api/files/delete', {'path': directory, 'recursive': True})
    print('temporary API files removed')

print('Debug remote API device regression complete')