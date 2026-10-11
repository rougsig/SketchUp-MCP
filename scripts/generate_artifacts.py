#!/usr/bin/env python3
"""Rebuild the project's furniture artifacts using their original generators."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET
import json

ROOT = Path(__file__).resolve().parents[1]
VARIANTS = {
    'washing-machine': ('default',),
    'dryer': ('default',),
    'laundry-tower': ('closed', 'open'),
    'laundry-sink': ('closed', 'open'),
    'detergent-cabinet': ('closed', 'lower-open', 'all-open', 'mechanism'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('models', nargs='*', help='Model names; omit to generate all five')
    parser.add_argument('--variant', help='One variant (requires exactly one model)')
    parser.add_argument('--geometry-only', action='store_true', help='Skip PNG/SVG preview rendering')
    parser.add_argument('--quality', choices=('high','draft'), default='high', help='High: technical PNG illustrations (NumPy); draft: original PNG/SVG previews')
    args = parser.parse_args()
    models = args.models or list(VARIANTS)
    if any(model not in VARIANTS for model in models):
        parser.error('Models: ' + ', '.join(VARIANTS))
    if args.variant and (len(models) != 1 or args.variant not in VARIANTS[models[0]]):
        parser.error('--variant requires one model and one of its supported variants')
    if args.geometry_only and args.variant == 'open' and models == ['laundry-tower']:
        parser.error('Tower open is a preview-only variant; its DAE/JSON describe the closed tower')
    env = dict(os.environ, SKETCHUP_ARTIFACT_SKIP_RENDER='1' if args.geometry_only else '0',
               SKETCHUP_ARTIFACT_RENDER_QUALITY=args.quality)
    for model in models:
        directory = ROOT / 'artifacts' / model
        variants = (args.variant,) if args.variant else VARIANTS[model]
        # Variant generators only write the canonical JSON in closed mode.
        if variants[0] not in ('closed', 'default'):
            subprocess.run([sys.executable, str(directory / 'build_model.py'), 'closed'],
                           env=dict(env, SKETCHUP_ARTIFACT_SKIP_RENDER='1'), check=True)
        for variant in variants:
            if args.geometry_only and model == 'laundry-tower' and variant == 'open':
                continue
            command = [sys.executable, str(directory / 'build_model.py')]
            if variant != 'default':
                command.append('--open' if model == 'laundry-tower' and variant == 'open' else variant)
            print(f'Generating {model}/{variant}', flush=True)
            subprocess.run(command, env=env, check=True)
        data = json.loads((directory / 'cache' / 'model-primitives.json').read_text(encoding='utf-8'))
        if not data.get('shapes'):
            raise ValueError(f'{model}: empty geometry')
        for path in (directory / 'cache').glob('*.dae'):
            ET.parse(path)
        print(f'Validated {model}: {len(data["shapes"])} primitives', flush=True)


if __name__ == '__main__':
    main()
