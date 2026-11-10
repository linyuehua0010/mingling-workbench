import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[2] / 'tools' / 'astr_setup.py'
spec = importlib.util.spec_from_file_location('pet_credentials', MODULE)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class Response(io.BytesIO):
    def __init__(self, result):
        super().__init__(json.dumps(result).encode())


class PetCredentialsTest(unittest.TestCase):
    def exercise(self, valid):
        requests = []
        def respond(request, timeout):
            path = request.full_url.split('/api/v1')[1]
            requests.append((request.method, path))
            if path == '/auth/login':
                return Response({'data': {'token': 'fixture-dashboard-token'}})
            if path.startswith('/chat/sessions'):
                return Response({'status': 'ok' if valid else 'error', 'data': []})
            if path == '/api-keys' and request.method == 'POST':
                return Response({'data': {'api_key': 'fixture-new-pet-key'}})
            raise AssertionError((request.method, path))
        test_root = MODULE.parents[1] / 'tmp'
        test_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='mingling-pet-test-', dir=test_root) as directory:
            root = Path(directory)
            private = root / 'private'
            private.mkdir()
            (private / 'backend.txt').write_text('username: fixture\npassword: fixture-password', encoding='utf-8')
            (private / 'owner-qq.txt').write_text('123456789', encoding='utf-8')
            (private / 'pet-key.txt').write_text('fixture-existing-pet-key', encoding='utf-8')
            output = io.StringIO()
            with patch.object(sys, 'argv', ['astr_setup.py', '--dir', directory, 'pet-key']), patch('urllib.request.urlopen', respond), contextlib.redirect_stdout(output):
                helper.main()
            self.assertFalse(any(method == 'DELETE' for method, _ in requests))
            self.assertNotIn('fixture-existing-pet-key', output.getvalue())
            self.assertNotIn('fixture-new-pet-key', output.getvalue())
            saved = (private / 'pet-key.txt').read_text(encoding='utf-8')
            self.assertEqual(saved, 'fixture-existing-pet-key' if valid else 'fixture-new-pet-key')
            if not valid:
                self.assertTrue(list((root / '旧版').rglob('pet-key.txt')))
        return requests

    def test_existing_key_is_reused_without_writing_sessions(self):
        requests = self.exercise(True)
        self.assertNotIn(('POST', '/api-keys'), requests)

    def test_invalid_key_is_backed_up_and_replaced_without_deleting_history(self):
        requests = self.exercise(False)
        self.assertIn(('POST', '/api-keys'), requests)


if __name__ == '__main__':
    unittest.main()
