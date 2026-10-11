import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('server', ROOT / 'server' / 'server.py')
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class FakeBridge:
    def call(self, name, arguments):
        return {'name': name, 'arguments': arguments}


class ProtocolTests(unittest.TestCase):
    def call(self, method, params=None):
        return server.handle({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params or {}}, FakeBridge())

    def test_initialize_and_tools(self):
        result = self.call('initialize', {'protocolVersion': '2024-11-05'})['result']
        self.assertEqual(result['protocolVersion'], '2024-11-05')
        tools = self.call('tools/list')['result']['tools']
        self.assertEqual(len(tools), 41)
        self.assertTrue(next(t for t in tools if t['name'] == 'get_model')['annotations']['readOnlyHint'])
        self.assertFalse(next(t for t in tools if t['name'] == 'create_box')['annotations']['readOnlyHint'])

    def test_automation_schema_and_nested_batch_validation(self):
        valid = {'tool': 'transform_object', 'arguments': {'path': [10, 20], 'translation_mm': [0, -400, 0]}}
        result = self.call('tools/call', {'name': 'batch_edit', 'arguments': {'commands': [valid], 'operation_id': 'batch-1'}})
        self.assertNotIn('isError', result['result'])
        for command in (
            {'tool': 'run_ruby_script', 'arguments': {}},
            {'tool': 'transform_object', 'arguments': {'path': [10], 'ruby': 'anything'}},
            {'tool': 'transform_object', 'arguments': {'path': [True]}},
        ):
            result = self.call('tools/call', {'name': 'batch_edit', 'arguments': {'commands': [command], 'operation_id': 'bad'}})
            self.assertTrue(result['result']['isError'])

    def test_script_requires_content_hash_and_edit_identity(self):
        for arguments in (
            {'file_path': '/tmp/a.rb', 'operation_id': 'script'},
            {'file_path': '/tmp/a.rb', 'sha256': 'not-a-hash', 'operation_id': 'script'},
            {'file_path': '/tmp/a.rb', 'sha256': 'a' * 64},
        ):
            self.assertTrue(self.call('tools/call', {'name': 'run_ruby_script', 'arguments': arguments})['result']['isError'])

    def test_existing_project_assemblies_can_be_submitted_as_files(self):
        result = self.call('tools/call', {'name': 'build_assembly', 'arguments': {
            'json_path': '/tmp/model-primitives.json', 'key': 'laundry-sink', 'replace': True, 'operation_id': 'sink-v1'}})
        self.assertNotIn('isError', result['result'])

    def test_new_primitive_export_and_ruby_arguments(self):
        for name, arguments in (
            ('create_sphere', {'key':'sphere','radius_mm':100,'center_mm':[10,20,30],'operation_id':'sphere-1'}),
            ('create_cone', {'key':'cone','radius_mm':100,'height_mm':200,'axis':'X','operation_id':'cone-1'}),
            ('export_scene', {'file_path':'/tmp/model.stl','operation_id':'export-1'}),
            ('export_scene', {'file_path':'/tmp/model.dae','paths':[[123]],'render_compatible':True,'operation_id':'export-selected'}),
            ('eval_ruby', {'code':'[1,2,3]','transaction':'managed','operation_id':'ruby-1'}),
        ):
            self.assertNotIn('isError', self.call('tools/call', {'name':name,'arguments':arguments})['result'])
        for name, arguments in (
            ('create_sphere', {'key':'sphere','radius_mm':0,'operation_id':'bad'}),
            ('create_cone', {'key':'cone','radius_mm':1,'height_mm':-1,'operation_id':'bad'}),
            ('create_cone', {'key':'cone','radius_mm':1,'height_mm':1,'segments':13,'operation_id':'bad'}),
            ('eval_ruby', {'code':'','operation_id':'bad'}),
            ('eval_ruby', {'code':'puts 1'}),
            ('eval_ruby', {'code':'a'*100001,'operation_id':'bad'}),
            ('eval_ruby', {'code':'1','transaction':'other','operation_id':'bad'}),
            ('export_scene', {'file_path':'/tmp/view.png','width':16001,'operation_id':'bad'}),
        ):
            self.assertTrue(self.call('tools/call', {'name':name,'arguments':arguments})['result']['isError'])
        for kind in ('sphere','cone'):
            result=self.call('tools/call', {'name':'build_assembly','arguments':{
                'key':kind,'operation_id':kind+'-assembly','assembly':{
                    'shapes':[{'type':kind,'radius':100,'length':200,'segments':32}]}}})
            self.assertNotIn('isError',result['result'])

    def test_notifications_and_invalid_requests(self):
        self.assertIsNone(server.handle({'jsonrpc': '2.0', 'method': 'notifications/initialized'}, FakeBridge()))
        self.assertEqual(server.handle([], FakeBridge())['error']['code'], -32600)
        self.assertEqual(self.call('unknown')['error']['code'], -32601)
        self.assertEqual(self.call('tools/call', {'name': []})['error']['code'], -32602)

    def test_invalid_edit_never_reaches_bridge(self):
        class RejectBridge:
            def call(self, *args):
                raise AssertionError('Invalid edit reached SketchUp')
        for args in ({'dimensions_mm': [1, 2, 0]}, {'dimensions_mm': [True, 2, 3]},
                     {'dimensions_mm': [float('nan'), 2, 3]}, {'dimensions_mm': [1, 2, 3], 'ruby': 'unsafe'},
                     {'dimensions_mm': [1, 2]}, {'dimensions_mm': [10**400, 2, 3]}):
            result = server.handle({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                                    'params': {'name': 'create_box', 'arguments': args}}, RejectBridge())
            self.assertTrue(result['result']['isError'])

    def test_stdio_real_process(self):
        with tempfile.TemporaryDirectory() as directory:
            messages = ['invalid json', json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
                         'params': {'protocolVersion': '2025-11-25'}}),
                        json.dumps({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
                        json.dumps({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
                        json.dumps({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'get_model'}})]
            proc = subprocess.run([sys.executable, str(ROOT / 'server' / 'server.py'), '--bridge-dir', directory],
                                  input='\n'.join(messages) + '\n', text=True, capture_output=True, timeout=5)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            replies = [json.loads(line) for line in proc.stdout.splitlines()]
            self.assertEqual(len(replies), 4)
            self.assertEqual(replies[0]['error']['code'], -32700)
            self.assertEqual(replies[1]['id'], 1)
            self.assertTrue(replies[-1]['result']['isError'])

    def test_bridge_roundtrip_and_error(self):
        for reply in ({'result': {'title': 'Test'}}, {'error': 'Model changed'}):
            with tempfile.TemporaryDirectory() as directory:
                bridge = server.Bridge(directory, timeout=1)
                server.atomic_json(Path(directory) / 'status.json',
                                   {'running': True, 'updated_at': time.time(), 'session': 'abc', 'model_id': '123', 'context': []})
                seen = []
                def fake_sketchup():
                    deadline = time.monotonic() + 1
                    while time.monotonic() < deadline:
                        requests = list((Path(directory) / 'requests').glob('*.json'))
                        if requests:
                            request = requests[0]
                            seen.append(json.loads(request.read_text()))
                            request.unlink()
                            server.atomic_json(Path(directory) / 'responses' / request.name, reply)
                            return
                        time.sleep(0.01)
                worker = threading.Thread(target=fake_sketchup)
                worker.start()
                try:
                    if 'error' in reply:
                        with self.assertRaisesRegex(RuntimeError, 'Model changed'):
                            bridge.call('get_model', {})
                    else:
                        self.assertEqual(bridge.call('get_model', {}), reply['result'])
                finally:
                    worker.join()
                self.assertEqual(seen[0]['session'], 'abc')
                self.assertEqual(seen[0]['context'], [])
                self.assertFalse(list((Path(directory) / 'requests').glob('*.json')))
                self.assertFalse(list((Path(directory) / 'responses').glob('*.json')))

    def test_timeout_and_stale_heartbeat(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge = server.Bridge(directory, timeout=0.1)
            status = {'running': True, 'updated_at': time.time(), 'session': 'abc', 'model_id': '123', 'context': []}
            server.atomic_json(Path(directory) / 'status.json', status)
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                bridge.call('create_box', {'dimensions_mm': [1, 2, 3]})
            self.assertFalse(list((Path(directory) / 'requests').glob('*.json')))
            status['updated_at'] -= 10
            server.atomic_json(Path(directory) / 'status.json', status)
            with self.assertRaisesRegex(RuntimeError, 'stopped or busy'):
                bridge.call('get_model', {})


if __name__ == '__main__':
    unittest.main()
