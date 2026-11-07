"""Regression coverage for durable workbench memory delivery without AstrBot/network."""
import asyncio
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

spec = importlib.util.spec_from_file_location('selftest_loader', Path(__file__).resolve().parents[2] / 'plugin-selftest.py')
loader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(loader)
m = loader.load_plugin()


class MemoryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.logs = Path(self.tmp.name) / 'logs'
        self.logs.mkdir()
        self.paths_patch = patch.object(m, '_paths', return_value={'logs': self.logs, 'root': Path(self.tmp.name), 'out': Path(self.tmp.name) / 'out'})
        self.paths_patch.start()
        self.bridge = m.BiliBridge(None, {'owner_session': 'qq:FriendMessage:123', 'persona_id': '冥零'})

    async def asyncTearDown(self):
        self.paths_patch.stop()
        self.tmp.cleanup()

    def publish(self, name='a.json', source='link'):
        inbox = self.logs / 'memory-inbox'
        inbox.mkdir(exist_ok=True)
        path = inbox / name
        path.write_text(json.dumps({'bv': 'https://example.com', 'content': '网页正文和阅读要点', 'metadata': {'source': source, 'bili_bv': 'https://example.com'}}), encoding='utf-8')
        return path

    async def test_failed_delivery_survives_and_later_retries(self):
        path = self.publish()
        with patch.object(m, '_lm_remember', new=AsyncMock(return_value='offline')):
            self.assertEqual(await self.bridge._flush_memory(), (0, 1))
        self.assertTrue(path.exists())
        self.bridge._memory_retry_after.clear()
        with patch.object(m, '_lm_remember', new=AsyncMock(return_value='')) as remember:
            self.assertEqual(await self.bridge._flush_memory(), (1, 0))
            self.assertEqual(remember.call_args.args[2], 'qq:FriendMessage:123')
            self.assertEqual(remember.call_args.args[3]['persona_id'], '冥零')
        self.assertFalse(path.exists())

    async def test_cancelled_worker_keeps_record(self):
        path = self.publish()
        with patch.object(m, '_lm_remember', new=AsyncMock(side_effect=asyncio.CancelledError)):
            with self.assertRaises(asyncio.CancelledError):
                await self.bridge._flush_memory()
        self.assertTrue(path.exists())

    async def test_memory_disabled_retains_queue(self):
        path = self.publish()
        self.bridge.cfg['memory_write'] = False
        with patch.object(m, '_lm_remember', new=AsyncMock()) as remember:
            self.assertEqual(await self.bridge._flush_memory(), (0, 1))
            remember.assert_not_called()
        self.assertTrue(path.exists())

    async def test_backfills_old_success_only_and_does_not_requeue_new_jobs(self):
        jobs = self.logs / 'jobs'
        jobs.mkdir()
        sink = jobs / 'read.txt'
        sink.write_text('历史网页正文', encoding='utf-8')
        base = {'bv': 'https://example.com', 'source': 'console', 'status': 'ok', 'sink': str(sink), 'type': 'link'}
        records = [base, {**base, 'status': 'fail'}, {**base, 'memory_queued': True}]
        (self.logs / 'jobs.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in records), encoding='utf-8')
        with patch.object(m, '_lm_remember', new=AsyncMock(return_value='')) as remember:
            self.assertEqual(await self.bridge._flush_memory(), (1, 0))
            self.assertIn('历史网页正文', remember.call_args.args[1])
            self.assertEqual(await self.bridge._flush_memory(), (0, 0))
            self.assertEqual(remember.await_count, 1)

    async def test_scope_and_persona_are_preserved_and_other_scope_not_overwritten(self):
        engine = SimpleNamespace(list_memories_page=AsyncMock(return_value={'items': [{'id': 7, 'metadata': {'bili_bv': 'BV1', 'session_id': 'other', 'persona_id': '冥零'}}]}), add_memory=AsyncMock(return_value=8), update_memory=AsyncMock(return_value=True))
        plugin = SimpleNamespace(initializer=SimpleNamespace(memory_engine=engine), config_manager=object())
        api = SimpleNamespace(is_event_memory_allowed=lambda c,e: True, resolve_memory_scope=lambda c,e: 'livingmemory:global')
        with patch.object(m, '_lm_plugin', return_value=plugin), patch.object(m, '_scope_api', return_value=api):
            self.assertEqual(await m._lm_remember('BV1', '看了视频', 'qq:FriendMessage:123', {'bili_bv': 'BV1', 'persona_id': '冥零'}), '')
        engine.update_memory.assert_not_called()
        self.assertEqual(engine.add_memory.call_args.kwargs['session_id'], 'livingmemory:global')
        self.assertEqual(engine.add_memory.call_args.kwargs['persona_id'], '冥零')
        self.assertEqual(engine.add_memory.call_args.kwargs['metadata']['source_session_id'], 'qq:FriendMessage:123')

    async def test_whitelist_denial_is_not_silently_written(self):
        engine = SimpleNamespace(add_memory=AsyncMock())
        plugin = SimpleNamespace(initializer=SimpleNamespace(memory_engine=engine), config_manager=object())
        api = SimpleNamespace(is_event_memory_allowed=lambda c,e: False)
        with patch.object(m, '_lm_plugin', return_value=plugin), patch.object(m, '_scope_api', return_value=api):
            self.assertIn('白名单', await m._lm_remember('BV1', 'content', 'qq:FriendMessage:123', {}))
        engine.add_memory.assert_not_called()

    async def test_scope_event_uses_adapter_type_and_original_group_sender(self):
        context = SimpleNamespace(get_platform_inst=lambda _: SimpleNamespace(meta=lambda: SimpleNamespace(name='aiocqhttp')))
        event = m._session_event('冥零:GroupMessage:456', context, {'source_sender_id': '123', 'source_sender_name': '主人'})
        self.assertEqual(event.get_platform_id(), '冥零')
        self.assertEqual(event.get_platform_name(), 'aiocqhttp')
        self.assertEqual(event.get_group_id(), '456')
        self.assertEqual(event.get_sender_id(), '123')

    async def test_legacy_pending_survives_cancellation_as_files(self):
        m._pending_add({'bv': 'BV1', 'content': 'old memory', 'session_id': 'qq:GroupMessage:456'})
        with patch.object(m, '_lm_remember', new=AsyncMock(side_effect=asyncio.CancelledError)):
            with self.assertRaises(asyncio.CancelledError):
                await self.bridge._flush_memory()
        queued = list((self.logs / 'memory-inbox').glob('*.json'))
        self.assertEqual(len(queued), 1)
        self.assertEqual(json.loads(queued[0].read_text())['session_id'], 'qq:GroupMessage:456')

if __name__ == '__main__':
    unittest.main()
