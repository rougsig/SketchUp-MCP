#!/usr/bin/env python3
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED

root = Path(__file__).resolve().parent
out = root / 'dist' / 'sketch-up-mcp.rbz'
out.parent.mkdir(exist_ok=True)
with ZipFile(out, 'w', ZIP_DEFLATED) as archive:
    for path in sorted((root / 'extension').rglob('*.rb')):
        archive.write(path, path.relative_to(root / 'extension'))
print(out)

project_archive = root / 'dist' / 'sketch-up-mcp-project.zip'
with ZipFile(project_archive, 'w', ZIP_DEFLATED) as archive:
    for path in sorted(root.rglob('*')):
        if not path.is_file() or any(part in {'.git', '__pycache__', '.DS_Store'} for part in path.relative_to(root).parts) or path.suffix == '.pyc':
            continue
        if path.parent == root / 'dist' and path != out:
            continue
        archive.write(path, Path('sketch-up-mcp') / path.relative_to(root))
print(project_archive)
