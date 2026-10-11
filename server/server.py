#!/usr/bin/env python3
"""Dependency-free MCP stdio server for the SketchUp Ruby file bridge."""
import argparse
import json
import math
import os
from pathlib import Path
import sys
import time
import uuid
import re
sys.path.insert(0, str(Path(__file__).resolve().parent))
from automation_schema import TOOLS as AUTOMATION_TOOLS

PROTOCOLS = ('2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05')
NUMBER = {'type': 'number'}
IDS = {'type': 'array', 'items': {'type': 'integer', 'minimum': 1}, 'minItems': 1, 'maxItems': 1000}
VECTOR = {'type': 'array', 'items': NUMBER, 'minItems': 3, 'maxItems': 3}
POSITIVE_VECTOR = {'type': 'array', 'items': {'type': 'number', 'exclusiveMinimum': 0}, 'minItems': 3, 'maxItems': 3}

def tool(name, description, properties=None, required=None, write=False):
    return {'name': name, 'description': description,
            'inputSchema': {'type': 'object', 'properties': properties or {},
                            'required': required or [], 'additionalProperties': False},
            'annotations': {'readOnlyHint': not write, 'destructiveHint': write,
                            'openWorldHint': False}}

TOOLS = [
    tool('get_model', 'Read the active model summary, model bounds and materials. All lengths are millimeters.'),
    tool('list_entities', 'List one level of entities. Omit parent_id for current editing context. Bounds are in parent coordinates; IDs are SketchUp persistent IDs.',
         {'parent_id': {'type': 'integer', 'minimum': 1}, 'offset': {'type': 'integer', 'minimum': 0},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 500}}),
    tool('get_selection', 'Read selected entities in the current editing context.'),
    tool('get_view', 'Capture the current SketchUp view as a PNG. Does not change the camera.',
         {'width': {'type': 'integer', 'minimum': 64, 'maximum': 2048},
          'height': {'type': 'integer', 'minimum': 64, 'maximum': 2048}}),
    tool('create_box', 'Create a named group containing a rectangular box in the current editing context. Origin and dimensions use millimeters and context axes.',
         {'name': {'type': 'string', 'maxLength': 256}, 'origin_mm': VECTOR, 'dimensions_mm': POSITIVE_VECTOR},
         ['dimensions_mm'], True),
    tool('move_entities', 'Move groups/components in the current editing context by a millimeter vector. Undoable. Read IDs immediately before editing.',
         {'entity_ids': IDS, 'delta_mm': VECTOR}, ['entity_ids', 'delta_mm'], True),
    tool('resize_entity', 'Scale a group/component to target axis-aligned bounding-box dimensions, keeping its bounding-box minimum fixed. Millimeters, parent axes. Scales all contents; does not perform parametric furniture editing.',
         {'entity_id': {'type': 'integer', 'minimum': 1}, 'dimensions_mm': POSITIVE_VECTOR},
         ['entity_id', 'dimensions_mm'], True),
    tool('set_material', 'Assign an existing model material to groups/components in the current context. Use a name from get_model, or null to clear. Face materials inside groups may override the group material.',
         {'entity_ids': IDS, 'material_name': {'type': ['string', 'null'], 'maxLength': 256}},
         ['entity_ids', 'material_name'], True),
]
TOOLS += AUTOMATION_TOOLS
TOOL_MAP = {t['name']: t for t in TOOLS}


def validate(value, schema, path='arguments'):
    types = schema.get('type', [])
    types = types if isinstance(types, list) else [types]
    matches = {'object': isinstance(value, dict), 'array': isinstance(value, list),
               'string': isinstance(value, str), 'integer': isinstance(value, int) and not isinstance(value, bool),
               'number': isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value),
               'boolean': isinstance(value, bool),
               'null': value is None}
    if not any(matches.get(t, False) for t in types):
        raise ValueError(path + ': expected ' + '/'.join(types))
    if 'enum' in schema and value not in schema['enum']:
        raise ValueError(path + ': invalid choice')
    if isinstance(value, dict):
        properties = schema.get('properties', {})
        if schema.get('additionalProperties', False) is False and any(k not in properties for k in value):
            raise ValueError(path + ': unknown argument')
        for k in schema.get('required', []):
            if k not in value:
                raise ValueError(path + ': missing ' + k)
        for k, v in value.items():
            if k in properties:
                validate(v, properties[k], path + '.' + k)
    elif isinstance(value, list):
        if not schema.get('minItems', 0) <= len(value) <= schema.get('maxItems', float('inf')):
            raise ValueError(path + ': invalid array length')
        for v in value:
            validate(v, schema['items'], path + '[]')
    elif isinstance(value, str):
        if len(value) < schema.get('minLength', 0):
            raise ValueError(path + ': string too short')
        if len(value) > schema.get('maxLength', float('inf')):
            raise ValueError(path + ': string too long')
        if 'pattern' in schema and not re.fullmatch(schema['pattern'], value):
            raise ValueError(path + ': invalid string format')
    elif isinstance(value, (float, int)):
        if value < schema.get('minimum', -float('inf')) or value > schema.get('maximum', float('inf')) or value <= schema.get('exclusiveMinimum', -float('inf')):
            raise ValueError(path + ': number out of range')


def atomic_json(path, data):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, allow_nan=False), encoding='utf-8')
    os.replace(str(temporary), str(path))


class Bridge:
    def __init__(self, directory, timeout=15):
        self.directory = Path(directory).expanduser().resolve()
        self.timeout = timeout
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        if os.name != 'nt':
            self.directory.chmod(0o700)
        for child in ('requests', 'responses'):
            (self.directory / child).mkdir(parents=True, exist_ok=True, mode=0o700)

    def call(self, name, arguments):
        try:
            status = json.loads((self.directory / 'status.json').read_text(encoding='utf-8'))
        except (OSError, ValueError):
            raise RuntimeError('SketchUp bridge is unavailable. In SketchUp use Extensions > Local SketchUp MCP > Start bridge.')
        if not status.get('running') or time.time() - status.get('updated_at', 0) > 5:
            raise RuntimeError('SketchUp bridge is stopped or busy. Start the bridge and close modal dialogs.')
        request_id = uuid.uuid4().hex
        request = self.directory / 'requests' / (request_id + '.json')
        response = self.directory / 'responses' / (request_id + '.json')
        # Bind edits to the same active model/context observed in the heartbeat.
        payload = {'id': request_id, 'session': status['session'], 'model_id': status['model_id'],
            'context': status['context'], 'expires_at': time.time() + self.timeout,
                   'tool': name, 'arguments': arguments}
        atomic_json(request, payload)
        deadline = time.monotonic() + self.timeout
        try:
            while time.monotonic() < deadline:
                if response.exists():
                    result = json.loads(response.read_text(encoding='utf-8'))
                    if 'error' in result:
                        raise RuntimeError(result['error'])
                    return result['result']
                time.sleep(0.05)
            operation_id = arguments.get('operation_id')
            suffix = (' Query get_operation_status for ' + operation_id + '; retry only with the same operation_id.') if operation_id else ' Inspect the model before retrying an edit.'
            raise RuntimeError('SketchUp request timed out. It may have started.' + suffix)
        finally:
            request.unlink(missing_ok=True)
            response.unlink(missing_ok=True)


def handle(message, bridge):
    if not isinstance(message, dict) or message.get('jsonrpc') != '2.0' or not isinstance(message.get('method'), str):
        return {'jsonrpc': '2.0', 'id': message.get('id') if isinstance(message, dict) else None,
                'error': {'code': -32600, 'message': 'Invalid Request'}}
    if 'id' not in message:
        return None
    reply = {'jsonrpc': '2.0', 'id': message['id']}
    method = message['method']
    params = message.get('params', {})
    if not isinstance(params, dict):
        reply['error'] = {'code': -32602, 'message': 'params must be an object'}
        return reply
    if method == 'initialize':
        requested = params.get('protocolVersion')
        reply['result'] = {'protocolVersion': requested if requested in PROTOCOLS else PROTOCOLS[0],
                           'capabilities': {'tools': {}},
                           'serverInfo': {'name': 'local-sketchup-mcp', 'version': '0.3.0'},
                           'instructions': 'Work on the active SketchUp model. Lengths are mm. Read current IDs before editing; context coordinates may differ from world coordinates. Edits support SketchUp Undo.'}
    elif method == 'ping':
        reply['result'] = {}
    elif method == 'tools/list':
        reply['result'] = {'tools': TOOLS}
    elif method == 'tools/call':
        name = params.get('name')
        if not isinstance(name, str) or name not in TOOL_MAP:
            reply['error'] = {'code': -32602, 'message': 'Unknown tool'}
            return reply
        arguments = params.get('arguments', {})
        try:
            validate(arguments, TOOL_MAP[name]['inputSchema'])
            if name == 'batch_edit':
                for command in arguments['commands']:
                    nested = dict(command['arguments'], operation_id='batch-validation')
                    validate(nested, TOOL_MAP[command['tool']]['inputSchema'])
            result = bridge.call(name, arguments)
            if name == 'get_view':
                reply['result'] = {'content': [{'type': 'image', 'mimeType': 'image/png', 'data': result['png_base64']}]}
            else:
                reply['result'] = {'content': [{'type': 'text', 'text': json.dumps(result, ensure_ascii=False)}],
                                   'structuredContent': result}
        except (ValueError, RuntimeError, OSError, KeyError, OverflowError) as exc:
            reply['result'] = {'content': [{'type': 'text', 'text': str(exc)}], 'isError': True}
    else:
        reply['error'] = {'code': -32601, 'message': 'Method not found'}
    return reply


def main():
    # MCP stdio always uses UTF-8, including on Windows with a legacy locale.
    sys.stdin.reconfigure(encoding='utf-8')
    sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser()
    parser.add_argument('--bridge-dir', default=str(Path.home() / '.sketch-up-mcp'))
    parser.add_argument('--timeout', type=float, default=120)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('--timeout must be a positive finite number')
    bridge = Bridge(args.bridge_dir, args.timeout)
    for line in sys.stdin:
        try:
            message = json.loads(line, parse_constant=lambda v: (_ for _ in ()).throw(ValueError(v)))
            reply = handle(message, bridge)
        except (ValueError, RecursionError):
            reply = {'jsonrpc': '2.0', 'id': None, 'error': {'code': -32700, 'message': 'Parse error'}}
        if reply is not None:
            print(json.dumps(reply, ensure_ascii=False, allow_nan=False), flush=True)


if __name__ == '__main__':
    main()
