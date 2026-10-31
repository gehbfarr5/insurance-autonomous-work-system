#!/usr/bin/env python3
"""Root-only AES256-GPG inventory for the existing CardDAV credentials.
Usage: sudo insurance-vault init|sync|list|verify|test-admin|compare-admin|get NAME
The master file is on the SAME host. A separate offline recovery copy is still required.
"""
import getpass, hmac, json, os, secrets, subprocess, sys, tempfile
from pathlib import Path
from datetime import datetime, timezone
from urllib import request, parse, error

ROOT=Path('/var/lib/insurance-credential-vault')
KEY=ROOT/'master.key'
VAULT=ROOT/'secrets.json.gpg'
ENV=Path('/opt/insurance-carddav-mcp/secrets.env')
ADMIN=Path('/root/insurance-carddav-admin-password')
KEYS=Path('/root/.config/insurance-carddav-mcp/agent-keys')

def require_mode(p):
    if p.is_file() and (p.stat().st_mode & 0o077):
        raise RuntimeError('Sensitive file has permissions broader than 0600: '+str(p))

def crypt(data, decrypt=False):
    command=['gpg','--batch','--yes','--quiet','--pinentry-mode','loopback',
             '--passphrase-file',str(KEY), '--decrypt' if decrypt else '--symmetric']
    if not decrypt: command+=['--cipher-algo','AES256']
    p=subprocess.run(command,input=data,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode: raise RuntimeError('GPG encryption/decryption failed')
    return p.stdout

def collect():
    require_mode(ENV)
    result={}
    names={'PUBLIC_URL','ADMIN_PASSWORD_HASH','TOKEN_ENCRYPTION_KEY',
           'ICLOUD_ACCOUNT_1','ICLOUD_APP_PASSWORD_1'}
    for line in ENV.read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            k,v=line.split('=',1)
            if k in names and v: result['carddav.env.'+k.lower()]={'value':v,'source':str(ENV)}
    if ADMIN.is_file():
        require_mode(ADMIN)
        result['carddav.admin.password']={'value':ADMIN.read_text().strip(),'source':str(ADMIN)}
    for name in ['codex','antigravity']:
        p=KEYS/(name+'.access_key')
        if p.is_file():
            require_mode(p)
            result['agent.'+name+'.access_key']={'value':p.read_text().strip(),'source':str(p)}
    return result

def read():
    if not KEY.exists() or not VAULT.exists(): raise RuntimeError('Vault not initialized')
    require_mode(KEY); require_mode(VAULT)
    doc=json.loads(crypt(VAULT.read_bytes(),decrypt=True))
    if doc.get('version')!=1 or not isinstance(doc.get('items'),dict):
        raise RuntimeError('Invalid vault document')
    return doc

def save(doc):
    encoded=crypt(json.dumps(doc,ensure_ascii=False).encode('utf-8'))
    fd,name=tempfile.mkstemp(prefix='.vault-',dir=str(ROOT))
    p=Path(name)
    try:
        with os.fdopen(fd,'wb') as fp:
            fp.write(encoded); fp.flush(); os.fsync(fp.fileno())
        os.chmod(p,0o600); os.replace(p,VAULT)
    finally: p.unlink(missing_ok=True)

def init():
    ROOT.mkdir(parents=True,exist_ok=True); ROOT.chmod(0o700)
    if KEY.exists() or VAULT.exists(): raise RuntimeError('Already initialized (no overwrite)')
    fd=os.open(KEY,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as fp: fp.write(secrets.token_urlsafe(48)+'\n')
    doc={'version':1,'created':datetime.now(timezone.utc).isoformat(),'items':collect()}
    save(doc)
    print('VAULT_INITIALIZED entries='+str(len(doc['items'])))

def sync():
    doc=read(); diff=0
    for k,v in collect().items():
        if doc['items'].get(k)!=v:
            doc['items'][k]=v; diff+=1
    if diff: save(doc)
    print('VAULT_SYNCED changed='+str(diff)+' entries='+str(len(doc['items'])))

def list_items():
    for k,v in sorted(read()['items'].items()):
        print(k+' | PRESENT | '+v['source'])

def verify():
    doc=read()
    if any(not item.get('value') for item in doc['items'].values()):
        raise RuntimeError('Empty item detected')
    print('VAULT_VERIFIED AES256-GPG entries='+str(len(doc['items'])))

def test_admin():
    password=read()['items']['carddav.admin.password']['value']
    body=parse.urlencode({'password':password}).encode()
    class NoRedirect(request.HTTPRedirectHandler):
        def redirect_request(self,*args): return None
    req=request.Request('http://127.0.0.1:17734/admin/login',data=body,method='POST',
        headers={'Origin':'https://seoul-forge-01.tail4db0d9.ts.net',
                 'Content-Type':'application/x-www-form-urlencoded'})
    try: status=request.build_opener(NoRedirect()).open(req,timeout=8).status
    except error.HTTPError as exc: status=exc.code
    print('ADMIN_LOGIN_PASS' if status==303 else 'ADMIN_LOGIN_FAIL HTTP='+str(status))
    return 0 if status==303 else 1

def main():
    if os.geteuid(): raise RuntimeError('Requires sudo/root')
    if len(sys.argv)<2: raise RuntimeError('Usage: init|sync|list|verify|test-admin|compare-admin|get NAME')
    cmd=sys.argv[1]
    if cmd=='init': init()
    elif cmd=='sync': sync()
    elif cmd=='list': list_items()
    elif cmd=='verify': verify()
    elif cmd=='test-admin': return test_admin()
    elif cmd=='compare-admin':
        entered=getpass.getpass('Enter password previously tried on /admin: ')
        print('MATCH' if hmac.compare_digest(entered,read()['items']['carddav.admin.password']['value']) else 'MISMATCH')
    elif cmd=='get' and len(sys.argv)==3:
        print(read()['items'][sys.argv[2]]['value'])
    else: raise RuntimeError('Unsupported operation')
    return 0

if __name__=='__main__':
    try: sys.exit(main())
    except (OSError,RuntimeError,ValueError,KeyError) as exc:
        print('VAULT_ERROR: '+str(exc),file=sys.stderr); sys.exit(2)
