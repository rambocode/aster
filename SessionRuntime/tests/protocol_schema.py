#!/usr/bin/env python3
"""Validate the generated wire contracts with the standard Draft 2020-12 engine."""
import json
from pathlib import Path
import subprocess
import sys
from jsonschema import Draft202012Validator

root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root/'scripts/build-protocol.py'), '--check'], check=True)
total = 0
for schema_name, fixture_name in [('operations.schema.json','operation-fixtures.json'),
                                  ('events.schema.json','event-fixtures.json'),
                                  ('stream.schema.json','stream-fixtures.json')]:
    schema = json.loads((root/'protocol'/schema_name).read_text())
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    fixtures = json.loads((root/'protocol'/fixture_name).read_text())
    for case in fixtures:
        errors = list(validator.iter_errors(case['value']))
        assert (not errors) == case['valid'], (case['name'], [e.message for e in errors])
    total += len(fixtures)
reply_cases = json.loads((root/'protocol/reply-fixtures.json').read_text())
for case in reply_cases:
    schema_name = 'events.schema.json' if case['kind']=='event' else 'operations.schema.json'
    validator = Draft202012Validator(json.loads((root/'protocol'/schema_name).read_text()))
    valid = not list(validator.iter_errors(json.loads(case['valueJSON'])))
    expected = case['name'] not in {'missing revision','invalid error code','wrong event kind','invalid event identity'}
    assert valid == expected, case['name']
total += len(reply_cases)
print(f'PASS: {total} operation/event/stream/reply fixtures match Draft 2020-12')
