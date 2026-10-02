'use strict';
const $ = id => document.getElementById(id);
let key = sessionStorage.getItem('terminalDebugToken') || '';
let offset = 0, editorHash = null, activeJob = null;
$('token').value = key;
function message(text) { $('message').textContent = text; }
async function api(path, body, raw) {
  const headers = {'Authorization': 'Bearer ' + key};
  if (body !== undefined && !raw) headers['Content-Type'] = 'application/json';
  const response = await fetch(path, {method: body === undefined ? 'GET' : 'POST', headers, body: body === undefined ? undefined : raw ? body : JSON.stringify(body)});
  if (!response.ok) {
    let text = 'HTTP ' + response.status;
    try { text = (await response.json()).error || text; } catch (_) {}
    throw new Error(text);
  }
  return raw && body === undefined ? response : response.json();
}
function act(id, fn) { $(id).addEventListener('click', async () => { message(''); try { await fn(); } catch (e) { message(e.message); } }); }
async function connect() {
  key = $('token').value.trim();
  const status = await api('/api/status');
  sessionStorage.setItem('terminalDebugToken', key);
  $('status').textContent = '已连接 · UID ' + status.uid + ' · ' + status.prefix + ' · 外部存储' + (status.externalWritable ? '可写' : '等待权限授权');
  await browse();
}
act('connect', connect);
act('logout', () => { key = ''; $('token').value = ''; sessionStorage.removeItem('terminalDebugToken'); $('status').textContent = '已退出'; });
async function browse(next = false) {
  if (!next) offset = 0;
  const result = await api('/api/files?path=' + encodeURIComponent($('directory').value) + '&offset=' + offset + '&limit=100');
  $('directory').value = result.path;
  $('entries').replaceChildren();
  result.entries.forEach(entry => {
    const row = document.createElement('tr'), name = document.createElement('td'), details = document.createElement('td'), actions = document.createElement('td');
    name.textContent = (entry.type === 'directory' ? '📁 ' : entry.type === 'symlink' ? '↗ ' : '') + entry.name;
    details.textContent = entry.size + ' B · ' + entry.mode;
    function button(label, fn) {
      const node = document.createElement('button'); node.textContent = label;
      node.addEventListener('click', async () => { message(''); try { await fn(); } catch (e) { message(e.message); } });
      actions.appendChild(node);
    }
    if (entry.type === 'directory') button('打开', () => { $('directory').value = entry.path; return browse(); });
    if (entry.type === 'file') button('编辑', () => edit(entry.path));
    button('复制/移动', () => { $('source').value = entry.path; $('destination').focus(); });
    button('重命名', async () => {
      const name = prompt('新名称', entry.name); if (!name || name === entry.name) return;
      if (name.includes('/') || name === '.' || name === '..') throw new Error('名称不能包含路径');
      await api('/api/files/move', {source: entry.path, destination: result.path + '/' + name}); await browse();
    });
    button('删除', async () => {
      if (!confirm('删除 ' + entry.path + (entry.type === 'directory' ? ' 及其内容？' : '？'))) return;
      await api('/api/files/delete', {path: entry.path, recursive: entry.type === 'directory'}); await browse();
    });
    row.append(name, details, actions); $('entries').appendChild(row);
  });
  $('more').disabled = offset + result.entries.length >= result.total;
}
act('browse', () => browse());
act('more', () => { offset += 100; return browse(true); });
act('parent', () => { $('directory').value = $('directory').value.replace(/\/?[^/]+\/?$/, '') || '/'; return browse(); });
act('private', () => { $('directory').value = '/data/data/com.terminal/files'; return browse(); });
act('external', () => { $('directory').value = '/storage/emulated/0'; return browse(); });
act('mkdir', async () => { const name = prompt('新目录名称'); if (!name) return; await api('/api/files/mkdir', {path: $('directory').value + '/' + name}); await browse(); });
act('newFile', () => { const name = prompt('新文件名称'); if (!name) return; $('editPath').value = $('directory').value + '/' + name; $('editor').value = ''; editorHash = null; $('editor').focus(); });
act('permissions', async () => { const report = await api('/api/permissions'); message('检查 ' + report.directories + ' 个目录，问题 ' + report.issues.length + (report.issues.length ? '\n' + report.issues.join('\n') : '')); });
async function edit(path) { const file = await api('/api/files/read?path=' + encodeURIComponent(path)); $('editPath').value = path; $('editor').value = file.text; editorHash = file.sha256; $('editor').focus(); }
$('editPath').addEventListener('input', () => { editorHash = null; });
act('save', async () => { const body = {path: $('editPath').value, text: $('editor').value, overwrite: true}; if (editorHash) body.sha256 = editorHash; const result = await api('/api/files/write', body); editorHash = result.sha256; message('已保存 ' + result.path); await browse(); });
act('download', async () => { const response = await api('/api/file?path=' + encodeURIComponent($('editPath').value), undefined, true); const url = URL.createObjectURL(await response.blob()); const link = document.createElement('a'); link.href = url; link.download = $('editPath').value.split('/').pop(); link.click(); setTimeout(() => URL.revokeObjectURL(url), 10000); });
$('upload').addEventListener('change', async () => { const file = $('upload').files[0]; if (!file) return; try { if (file.size > 16 * 1024 * 1024) throw new Error('单次上传最多 16 MiB'); await api('/api/upload?path=' + encodeURIComponent($('directory').value + '/' + file.name), file, true); await browse(); message('上传完成'); } catch (e) { message(e.message); } $('upload').value = ''; });
for (const operation of ['copy', 'move']) act(operation, async () => { const result = await api('/api/files/' + operation, {source: $('source').value, destination: $('destination').value}); message((operation === 'copy' ? '已复制到 ' : '已移动到 ') + result.path); await browse(); });
act('execute', async () => {
  const job = await api('/api/exec', {command: $('command').value, cwd: $('cwd').value, timeoutMs: Number($('timeout').value) * 1000});
  activeJob = job.id; $('execute').disabled = true;
  try {
    while (activeJob === job.id) {
      const result = await api('/api/jobs/' + job.id);
      $('output').textContent = result.stdout + (result.stderr ? '\n[stderr]\n' + result.stderr : '') + (result.running ? '\n[运行中]' : '\n[退出码 ' + result.exitCode + (result.timedOut ? ' · 超时' : '') + (result.cancelled ? ' · 已取消' : '') + ']') + (result.truncated ? '\n[输出已达到显示上限]' : '');
      if (!result.running) break;
      await new Promise(resolve => setTimeout(resolve, 400));
    }
  } finally { activeJob = null; $('execute').disabled = false; }
});
act('cancel', () => activeJob ? api('/api/jobs/' + activeJob + '/cancel', {}) : undefined);
if (key) connect().catch(e => message(e.message));