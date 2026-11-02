"""Read-only bridge for the floating companion. Never starts or changes a task."""
import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import sqlite3
import subprocess
import sys
import threading
import time


def find_codex():
    override = os.environ.get('COMPANION_CODEX_CLI')
    if override:
        path = Path(override).expanduser()
        return str(path) if path.is_file() and os.access(path, os.X_OK) else None
    installed = shutil.which('codex')
    if installed:
        return installed
    hosts = [Path(os.environ['COMPANION_HOST_APP'])] if os.environ.get('COMPANION_HOST_APP') else []
    hosts += [base/name for base in (Path('/Applications'), Path.home()/'Applications')
              for name in ('Codex.app', 'ChatGPT.app')]
    for host in hosts:
        for relative in ('Contents/Resources/codex', 'Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'):
            path = host/relative
            if path.is_file() and os.access(path, os.X_OK):
                return str(path)
    return None


def read_quota(timeout=18):
    executable = find_codex()
    if not executable:
        return None
    process = subprocess.Popen([executable, 'app-server', '--listen', 'stdio://'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    buffer = b''
    def send(message):
        process.stdin.write((json.dumps(message) + '\n').encode())
        process.stdin.flush()
    try:
        send({'id':1, 'method':'initialize', 'params':{'clientInfo':{
            'name':'companion_hover', 'title':'Companion Hover',
            'version':os.environ.get('COMPANION_APP_VERSION', '1.4.0')}}})
        deadline = time.monotonic() + timeout
        while process.poll() is None and time.monotonic() < deadline:
            for _, _mask in selector.select(.5):
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    return None
                buffer += chunk
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    try:
                        message = json.loads(line)
                    except ValueError:
                        continue
                    if message.get('id') == 1:
                        if 'error' in message:
                            return None
                        send({'method':'initialized', 'params':{}})
                        send({'id':2, 'method':'account/rateLimits/read'})
                    elif message.get('id') == 2:
                        result = message.get('result', {})
                        bucket = (result.get('rateLimitsByLimitId') or {}).get('codex') or result.get('rateLimits')
                        return {'limits':bucket, 'timestamp':time.time(), 'source':'live'} if bucket else None
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
        process.stdin.close()
        process.stdout.close()
    return None


def stamp(value):
    try:
        return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, AttributeError):
        return 0


def plain_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return ' '.join(plain_text(x) for x in content)
    if isinstance(content, dict):
        return content.get('text', '')
    return ''


class Rollouts:
    def __init__(self):
        self.cache = {}

    def read(self, path):
        file = Path(path)
        try:
            info = file.stat()
        except OSError:
            return {}
        cached = self.cache.get(path)
        if not cached or cached['inode'] != info.st_ino or cached['offset'] > info.st_size:
            cached = {'inode':info.st_ino, 'offset':0, 'partial':b'', 'running':False,
                      'status':'状态暂不可用', 'detail':'', 'last_event':0, 'plan':[],
                      'terminal':None, 'completed_at':0, 'pending_inputs':{}, 'input_calls':{}}
            self.cache[path] = cached
        try:
            with file.open('rb') as stream:
                stream.seek(cached['offset'])
                data = cached['partial'] + stream.read()
                cached['offset'] = stream.tell()
            lines = data.split(b'\n')
            cached['partial'] = lines.pop()
            for line in lines:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(event, dict):
                    continue
                payload = event.get('payload') or {}
                if not isinstance(payload, dict):
                    continue
                when = stamp(event.get('timestamp'))
                cached['last_event'] = max(when, cached['last_event'])
                if event.get('type') == 'event_msg':
                    kind = payload.get('type')
                    if kind == 'task_started':
                        cached.update(running=True, status='正在处理', detail='', plan=[], terminal=None)
                    elif kind in ('task_complete', 'task_completed'):
                        cached.update(running=False, status='已完成', detail='', terminal='completed', completed_at=when)
                    elif kind == 'turn_aborted':
                        cached.update(running=False, status='已停止', detail='', terminal='stopped')
                        cached['pending_inputs'].clear()
                    elif kind == 'token_count' and payload.get('rate_limits'):
                        cached['quota'] = {'limits':payload['rate_limits'], 'timestamp':when, 'source':'local'}
                    elif kind == 'agent_message':
                        cached['detail'] = plain_text(payload.get('message'))[:180]
                    elif kind == 'item_completed':
                        item = payload.get('item') or {}
                        item_type = item.get('type')
                        if item_type == 'AgentMessage' and item.get('phase') != 'final_answer':
                            cached['detail'] = plain_text(item.get('content'))[:180]
                            cached['status'] = '正在处理'
                        elif item_type == 'Reasoning':
                            cached['status'] = '正在思考'
                        elif item_type == 'CommandExecution':
                            cached['status'] = '正在执行任务'
                elif event.get('type') == 'response_item':
                    item_type = payload.get('type')
                    name = payload.get('name', '').split('.')[-1]
                    call_id = payload.get('call_id')
                    if item_type == 'function_call' and name == 'update_plan':
                        try:
                            plan = json.loads(payload.get('arguments', '{}')).get('plan', [])
                            cached['plan'] = plan
                        except (ValueError, AttributeError):
                            pass
                    elif item_type == 'function_call' and name in ('request_user_input', 'request_user_input_async', 'request_permissions'):
                        try:
                            arguments = json.loads(payload.get('arguments', '{}'))
                        except (ValueError, TypeError):
                            arguments = {}
                        if not isinstance(arguments, dict):
                            arguments = {}
                        # Async questions return "accepted" immediately. They remain
                        # pending until the matching user reply, not that tool result.
                        count = len(arguments.get('questions') or [None])
                        cached['input_calls'][call_id] = name
                        cached['pending_inputs'][call_id] = set(range(count))
                    elif item_type == 'function_call_output' and call_id in cached['input_calls']:
                        output = payload.get('output', '')
                        name = cached['input_calls'].pop(call_id)
                        try:
                            result = json.loads(output) if isinstance(output, str) else output
                        except (ValueError, TypeError):
                            result = {}
                        accepted = isinstance(result, dict) and result.get('accepted') is True
                        if name != 'request_user_input_async' or not accepted:
                            cached['pending_inputs'].pop(call_id, None)
                    elif item_type == 'message' and payload.get('role') == 'user':
                        message = plain_text(payload.get('content'))
                        match = re.search(r'<send_user_message_question_reply>\s*(.*?)\s*</send_user_message_question_reply>', message, re.S)
                        if match:
                            try:
                                for reply in json.loads(match.group(1)):
                                    tool, reply_id, index = json.loads(reply['questionItemId'])
                                    pending = cached['pending_inputs'].get(reply_id)
                                    if tool == 'request_user_input_async' and pending is not None:
                                        pending.discard(index)
                                        if not pending:
                                            cached['pending_inputs'].pop(reply_id, None)
                            except (ValueError, KeyError, TypeError):
                                pass
                        elif message.strip():
                            # A free-text follow-up also answers/supersedes the question.
                            cached['pending_inputs'].clear()
        except OSError:
            pass
        return cached


def activity_indicator(tasks, recent, error=None, now=None):
    """All active tasks contribute, even ones beyond the four visible cards."""
    now = time.time() if now is None else now
    if error:
        return {'state':'idle', 'label':'任务状态暂不可用'}
    if any(task.get('waiting') for task in tasks):
        return {'state':'attention', 'label':'等待你确认'}
    if any(task.get('status') != '状态待确认' for task in tasks):
        return {'state':'running', 'label':'任务进行中'}
    if not tasks and recent:
        latest = max(recent, key=lambda task:task.get('updated_at', 0))
        age = now-latest.get('completed_at', 0)
        if latest.get('terminal') == 'completed' and 0 <= age < 60:
            return {'state':'completed', 'label':'任务已完成'}
    return {'state':'idle', 'label':'当前没有进行中的任务'}


def windows(quota):
    result = []
    limits = (quota or {}).get('limits') or {}
    for key, label, expected_minutes in [('primary','5 小时',300), ('secondary','本周',10080)]:
        raw = limits.get(key)
        if not isinstance(raw, dict):
            result.append({'label':label, 'remaining':None, 'resets_at':None})
            continue
        used = raw.get('usedPercent', raw.get('used_percent'))
        minutes = raw.get('windowDurationMins', raw.get('window_minutes'))
        actual_label = label if minutes in (None, expected_minutes) else '{} 分钟'.format(minutes)
        try:
            used = float(used)
            remaining = max(0, min(100, 100-used)) if math.isfinite(used) else None
        except (ValueError, TypeError):
            remaining = None
        result.append({'label':actual_label,
                       'remaining':remaining,
                       'resets_at':raw.get('resetsAt', raw.get('resets_at'))})
    return result


class Bridge:
    def __init__(self, home=None):
        self.home = Path(home or os.environ.get('CODEX_HOME') or Path.home()/'.codex').expanduser().resolve()
        self.rollouts = Rollouts()
        self.live_quota = None
        self.refreshing = False
        self.last_attempt = 0
        self.last_error = False
        self.stop_event = threading.Event()

    def refresh_quota(self):
        if self.refreshing or time.time()-self.last_attempt < 60:
            return
        self.refreshing = True
        self.last_attempt = time.time()
        def work():
            try:
                quota = read_quota()
                if quota:
                    self.live_quota = quota
                self.last_error = quota is None
            except Exception:
                self.last_error = True
            finally:
                self.refreshing = False
        threading.Thread(target=work, daemon=True).start()

    def snapshot(self):
        databases = sorted((path for path in self.home.glob('state_*.sqlite') if path.stem.split('_')[-1].isdigit()),
                           key=lambda p:int(p.stem.split('_')[-1]), reverse=True)
        local_quota = None
        tasks, recent = [], []
        try:
            if not databases:
                raise FileNotFoundError('No local state database')
            connection = sqlite3.connect(databases[0].as_uri()+'?mode=ro', uri=True, timeout=1)
            connection.row_factory = sqlite3.Row
            try:
                columns = {row[1] for row in connection.execute('PRAGMA table_info(threads)')}
                if not {'id', 'rollout_path'} <= columns:
                    raise sqlite3.DatabaseError('Unsupported thread schema')
                selected = ['id', 'rollout_path']
                for name, default in [('name', "''"), ('title', "''"), ('updated_at', '0'), ('source', "''")]:
                    selected.append((name if name in columns else default)+' AS '+name)
                filters = ['archived=0'] if 'archived' in columns else []
                if 'source' in columns:
                    filters.append("source NOT LIKE '%subagent%'")
                query = 'SELECT '+', '.join(selected)+' FROM threads'
                if filters:
                    query += ' WHERE '+' AND '.join(filters)
                query += ' ORDER BY '+('updated_at' if 'updated_at' in columns else 'id')+' DESC LIMIT 60'
                rows = connection.execute(query).fetchall()
            finally:
                connection.close()
            for row in rows:
                state = self.rollouts.read(row['rollout_path'])
                quota = state.get('quota')
                if quota and (not local_quota or quota['timestamp'] > local_quota['timestamp']):
                    local_quota = quota
                title = row['name'] or row['title'] or '未命名任务'
                title = title.replace('\n', ' ')[:100]
                task = {'id':row['id'], 'title':title, 'status':state.get('status','状态暂不可用'),
                        'detail':state.get('detail',''), 'updated_at':state.get('last_event',row['updated_at']),
                        'waiting':bool(state.get('pending_inputs')), 'terminal':state.get('terminal'),
                        'completed_at':state.get('completed_at', 0)}
                plan = state.get('plan') or []
                if plan:
                    current = next((x.get('step') for x in plan if x.get('status')=='in_progress'), None)
                    done = sum(x.get('status')=='completed' for x in plan)
                    task.update(detail=current or task['detail'], completed=done, total=len(plan))
                if state.get('running') or task['waiting']:
                    if task['waiting']:
                        task.update(status='等待你确认', detail='请在原会话中查看并回复')
                    elif time.time()-task['updated_at']>900:
                        task.update(status='状态待确认', detail='任务记录暂时没有更新')
                    tasks.append(task)
                else:
                    recent.append(task)
            state_error = None
        except (OSError, sqlite3.Error, ValueError):
            state_error = '暂时无法读取本机任务'
        quota = self.live_quota
        if local_quota and (not quota or local_quota['timestamp']>quota['timestamp']):
            quota = local_quota
        tasks.sort(key=lambda task:(not task.get('waiting'), -task['updated_at']))
        return {'windows':windows(quota), 'quota_timestamp':(quota or {}).get('timestamp'),
                'quota_source':(quota or {}).get('source'), 'quota_error':self.last_error,
                'tasks':tasks[:4], 'recent':recent[:2], 'task_error':state_error,
                'indicator':activity_indicator(tasks, recent, state_error)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--local-only', action='store_true')
    args = parser.parse_args()
    bridge = Bridge()
    if args.once:
        if not args.local_only:
            bridge.live_quota = read_quota()
        print(json.dumps(bridge.snapshot(), ensure_ascii=False))
        return
    previous = None
    while True:
        if not args.local_only:
            bridge.refresh_quota()
        packet = json.dumps(bridge.snapshot(), ensure_ascii=False)
        if packet != previous:
            print(packet, flush=True)
            previous = packet
        # Stdin EOF means the native parent exited; terminate the bridge as well.
        if sys.stdin in selectors_select_stdin(2):
            line = sys.stdin.readline()
            if not line:
                return
            if line.strip() == 'refresh':
                bridge.last_attempt = 0


def selectors_select_stdin(timeout):
    import select
    try:
        return select.select([sys.stdin], [], [], timeout)[0]
    except (ValueError, OSError):
        time.sleep(timeout)
        return []


if __name__ == '__main__':
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
