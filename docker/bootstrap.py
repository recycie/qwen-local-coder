#!/usr/bin/env python3
"""Initialize local dashboards/client key; never print secrets."""
import json
import base64
import os
from pathlib import Path
import re
import shlex
import ssl
import subprocess
import urllib.error
import urllib.request
import urllib.parse
import uuid

ROOT = Path(__file__).resolve().parent
os.umask(0o077)
ENV = dict(line.split('=', 1) for line in (ROOT / '.env').read_text().splitlines()
           if '=' in line and not line.startswith('#'))
GATEWAY = f"http://127.0.0.1:{ENV.get('API_PORT', '4000')}"
PORTAINER = f"https://127.0.0.1:{ENV.get('INFRA_PORT', '9443')}"
# Only used for the loopback Portainer service's self-signed certificate.
LOCAL_TLS = ssl._create_unverified_context()


def call(base, path, data=None, headers=None):
    headers = dict(headers or {})
    raw = None
    if data is not None:
        raw = json.dumps(data).encode()
        headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(base + path, raw, headers)
    with urllib.request.urlopen(request, context=LOCAL_TLS if base == PORTAINER else None,
                                timeout=30) as response:
        body = response.read()
        return json.loads(body) if body else None


try:
    call(PORTAINER, '/api/users/admin/check')
except urllib.error.HTTPError as error:
    if error.code != 404:
        raise
    container = subprocess.check_output(
        ['docker', 'compose', 'ps', '-q', 'infra'], cwd=ROOT, text=True).strip()
    logs = subprocess.check_output(['docker', 'logs', container], stderr=subprocess.STDOUT,
                                   text=True)
    matches = re.findall(r'setup_token=([a-f0-9]+)', logs)
    if not matches:
        raise SystemExit('Portainer setup token missing. Check/restart the infra service.')
    call(PORTAINER, '/api/users/admin/init',
         {'Username': 'admin', 'Password': ENV['PORTAINER_PASSWORD']},
         {'X-Setup-Token': matches[-1]})

auth = call(PORTAINER, '/api/auth',
            {'Username': 'admin', 'Password': ENV['PORTAINER_PASSWORD']})
headers = {'Authorization': 'Bearer ' + auth['jwt']}
endpoints = call(PORTAINER, '/api/endpoints', headers=headers)
local = next((e for e in endpoints if e.get('URL') == 'unix:///var/run/docker.sock'), None)
if local is None:
    boundary = 'qlc' + uuid.uuid4().hex
    fields = {'Name': 'Local Docker', 'EndpointCreationType': '1',
              'URL': 'unix:///var/run/docker.sock'}
    body = ''.join('--' + boundary + '\r\nContent-Disposition: form-data; name="' + k +
                   '"\r\n\r\n' + v + '\r\n' for k, v in fields.items())
    body += '--' + boundary + '--\r\n'
    request = urllib.request.Request(PORTAINER + '/api/endpoints', body.encode(),
                                    dict(headers, **{'Content-Type': 'multipart/form-data; boundary=' + boundary}))
    with urllib.request.urlopen(request, context=LOCAL_TLS, timeout=30) as response:
        local = json.load(response)
call(PORTAINER, f"/api/endpoints/{local['Id']}/docker/info", headers=headers)
print('Portainer login and Docker connection verified.')

admin = {'Authorization': 'Bearer ' + ENV['LITELLM_MASTER_KEY']}
# Provision a database-backed admin through the same invitation flow as the UI.
# Management APIs intentionally do not accept setting another user's password.
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def admin_login_ok():
    request = urllib.request.Request(GATEWAY + '/login', urllib.parse.urlencode({
        'username': ENV['LITELLM_ADMIN_USERNAME'],
        'password': ENV['LITELLM_ADMIN_PASSWORD'],
    }).encode())
    try:
        urllib.request.build_opener(NoRedirect()).open(request, timeout=30)
    except urllib.error.HTTPError as error:
        if error.code in (302, 303):
            target = urllib.parse.urlparse(error.headers.get('Location', ''))
            return target.path.startswith('/ui') and 'login=success' in target.query
        if error.code in (400, 401, 403):
            return False
        raise
    return False


if not admin_login_ok():
    user = call(GATEWAY, '/user/info?user_id=qlc-operator', headers=admin)
    if user and user.get('user_info'):
        raise SystemExit('Operator account already exists but stored password does not match. '
                         'Preserving its password; update private credentials before retrying.')
    call(GATEWAY, '/user/new', {
        'user_id': 'qlc-operator', 'user_email': ENV['LITELLM_ADMIN_USERNAME'],
        'user_role': 'proxy_admin', 'auto_create_key': False, 'send_invite_email': False,
    }, admin)
    invitation = call(GATEWAY, '/invitation/new', {'user_id': 'qlc-operator'}, admin)
    onboarding = call(GATEWAY, '/onboarding/get_token?' + urllib.parse.urlencode({
        'invite_link': invitation['id'],
    }))
    # Extract the provided onboarding credential from its UI-token envelope.
    part = onboarding['token'].split('.')[1]
    claims = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4)))
    call(GATEWAY, '/onboarding/claim_token', {
        'invitation_link': invitation['id'], 'user_id': 'qlc-operator',
        'password': ENV['LITELLM_ADMIN_PASSWORD'],
    }, {'Authorization': 'Bearer ' + claims['key']})
    if not admin_login_ok():
        raise SystemExit('Database admin login verification failed.')
print('Database admin login verified; environment login is disabled.')

client_file = ROOT / '.runtime/client-key'
key = client_file.read_text().strip() if client_file.exists() else None
if key:
    call(GATEWAY, '/v1/models', headers={'Authorization': 'Bearer ' + key})
else:
    result = call(GATEWAY, '/key/generate', {
        'key_alias': 'local-dev', 'models': ['qwen3.8-27b'], 'rpm_limit': 6,
        'tpm_limit': 120000, 'max_parallel_requests': 1,
        'metadata': {'purpose': 'local coding API client'},
    }, admin)
    key = result['key']
    client_file.write_text(key + '\n')
    client_file.chmod(0o600)
call(GATEWAY, '/v1/models', headers={'Authorization': 'Bearer ' + key})
access = {
    'OPENAI_BASE_URL': ENV.get('PUBLIC_API_BASE_URL', GATEWAY + '/v1'), 'OPENAI_API_KEY': key, 'OPENAI_MODEL': 'qwen3.8-27b',
    'LITELLM_UI_URL': ENV.get('PUBLIC_UI_URL', GATEWAY + '/ui/'),
    'LITELLM_UI_USERNAME': ENV['LITELLM_ADMIN_USERNAME'],
    'LITELLM_UI_PASSWORD': ENV['LITELLM_ADMIN_PASSWORD'],
    'PORTAINER_URL': ENV.get('PUBLIC_INFRA_URL', PORTAINER),
    'PORTAINER_USERNAME': 'admin', 'PORTAINER_PASSWORD': ENV['PORTAINER_PASSWORD'],
}
path = Path.home() / '.config/qwen-local-coder/docker-access.env'
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(''.join(k + '=' + shlex.quote(v) + '\n' for k, v in access.items()))
path.chmod(0o600)
print('Client key verified. Access details saved privately to', path)
