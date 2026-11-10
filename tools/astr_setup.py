"""冥零桌宠凭据助手：复用已有凭据，不删除历史会话，不发送聊天。"""
import argparse
import hashlib
import json
import secrets
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dir', required=True)
    parser.add_argument('command', choices=['pet-key'])
    parser.add_argument('rest', nargs='*')
    args = parser.parse_args()
    root = Path(args.dir)
    private = root / 'private'
    def read(name):
        path = private / name
        return path.read_text(encoding='utf-8-sig').strip() if path.exists() else ''
    backend = {}
    for line in read('backend.txt').splitlines():
        key, sep, value = line.replace('：', ':', 1).partition(':')
        if sep:
            backend[key.strip().lower()] = value.strip()
    answers_file = root / 'answers.json'
    answers = json.loads(answers_file.read_text(encoding='utf-8-sig')) if answers_file.exists() else {}
    port = urllib.parse.urlparse(answers.get('base_url', 'http://127.0.0.1:6185')).port or 6185
    api = f'http://127.0.0.1:{port}/api/v1'
    def call(method, path, body=None, token='', api_key=''):
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        if api_key:
            headers['X-API-Key'] = api_key
        data = json.dumps(body, ensure_ascii=False).encode('utf-8') if body is not None else None
        req = urllib.request.Request(api + path, data=data, method=method, headers=headers)
        with urllib.request.urlopen(req, timeout=20) as response:
            result = json.loads(response.read().decode('utf-8'))
        if result.get('status') == 'error':
            raise RuntimeError('后台未接受桌宠配置，请查看后台日志')
        return result.get('data')
    if args.rest and args.rest != ['remove']:
        raise RuntimeError('不支持的桌宠凭据操作')
    token = backend.get('token', '')
    if not token:
        password = backend.get('password', '')
        for candidate in (password, hashlib.md5(password.encode()).hexdigest()):
            if not candidate:
                continue
            try:
                result = call('POST', '/auth/login', {'username': backend.get('username', 'astrbot'), 'password': candidate})
                token = result.get('token', '') if isinstance(result, dict) else ''
                if token:
                    break
            except (urllib.error.HTTPError, RuntimeError):
                continue
    if not token:
        raise RuntimeError('桌宠配置无法登录后台，请检查 backend.txt')
    backup_dir = root / '旧版' / ('pet-credentials-' + time.strftime('%Y%m%d-%H%M%S'))
    def save(name, value):
        path = private / name
        if path.exists():
            backup_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, backup_dir / name)
        private.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding='utf-8')
    old_key = read('pet-key.txt')
    if args.rest == ['remove']:
        keys = call('GET', '/api-keys', token=token) or []
        matching = [key for key in keys if key.get('key_prefix') and old_key.startswith(str(key['key_prefix']))
                    and key.get('name') in ('冥零桌宠', '大肥鱼桌宠')]
        if old_key and not matching:
            raise RuntimeError('没有找到与本机凭据匹配的桌宠密钥，请在后台核对后撤销')
        backup_dir.mkdir(parents=True, exist_ok=True)
        for name in ('pet-key.txt', 'pet-bridge-token.txt'):
            if (private / name).exists():
                shutil.copy2(private / name, backup_dir / name)
        for key in matching:
            call('DELETE', '/api-keys/' + urllib.parse.quote(str(key['key_id'])), token=token)
        for name in ('pet-key.txt', 'pet-bridge-token.txt'):
            (private / name).unlink(missing_ok=True)
        print('本机桌宠密钥已撤销，凭据已备份，历史会话保持完整')
        return
    owner = read('owner-qq.txt')
    if not owner:
        raise RuntimeError('缺少主人识别文件 private/owner-qq.txt')
    works = False
    if old_key:
        try:
            call('GET', '/chat/sessions?username=' + urllib.parse.quote(owner) + '&page=1&page_size=1', api_key=old_key)
            works = True
        except (urllib.error.HTTPError, RuntimeError):
            pass
    if not works:
        result = call('POST', '/api-keys', {'name': '冥零桌宠', 'scopes': ['chat', 'chat:admin']}, token=token)
        if not isinstance(result, dict) or not result.get('api_key'):
            raise RuntimeError('桌宠专用 API 密钥创建失败')
        save('pet-key.txt', result['api_key'])
    if not read('pet-bridge-token.txt'):
        save('pet-bridge-token.txt', 'ml-' + secrets.token_urlsafe(24))
    print('桌宠凭据已就绪，历史会话保持完整')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else '桌宠凭据配置失败：' + type(error).__name__)
        sys.exit(1)
