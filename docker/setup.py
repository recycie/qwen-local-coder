#!/usr/bin/env python3
"""Prepare private Docker configuration without printing credentials."""
import argparse
import os
from pathlib import Path
import secrets

ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--models-dir', type=Path, default=Path.home() / 'models')
args = parser.parse_args()
model = args.models_dir.expanduser().resolve() / 'Qwen3.8-27B-GSQ-RCO-IQ2_XS-mtp.gguf'
if not model.is_file():
    parser.error('quality model missing; run bin/qlc install first, or set --models-dir')
os.umask(0o077)
path = ROOT / '.env'
if not path.exists():
    values = {
        'MODELS_DIR': str(model.parent),
        'POSTGRES_PASSWORD': secrets.token_hex(24),
        'LITELLM_MASTER_KEY': 'sk-' + secrets.token_hex(32),
        'LITELLM_SALT_KEY': 'sk-' + secrets.token_hex(32),
        'LLAMA_API_KEY': 'sk-' + secrets.token_hex(32),
        'UI_PASSWORD': secrets.token_urlsafe(24),
        'PORTAINER_PASSWORD': secrets.token_urlsafe(24),
    }
    with path.open('x') as f:
        f.write(''.join(f'{k}={v}\n' for k, v in values.items()))
else:
    values = dict(line.split('=', 1) for line in path.read_text().splitlines()
                  if '=' in line and not line.startswith('#'))
path.chmod(0o600)
runtime = ROOT / '.runtime'
runtime.mkdir(exist_ok=True, mode=0o700)
runtime.chmod(0o700)
secret = runtime / 'llama-api-key'
secret.write_text(values['LLAMA_API_KEY'] + '\n')
secret.chmod(0o600)
print('Private configuration ready. Existing credentials preserved.')
