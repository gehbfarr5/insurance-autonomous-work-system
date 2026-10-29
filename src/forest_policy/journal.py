"""Offline journal extracted from the private executor; no device or network access."""
import datetime as dt
import json, os, uuid
from zoneinfo import ZoneInfo
from policy import UnsafeState, UncertainAction
TZ=ZoneInfo("Asia/Shanghai")

def atomic_json(path, data):
    path.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    temp=path.with_name(path.name+'.pending')
    fd=os.open(temp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as out:
        json.dump(data,out,ensure_ascii=False,indent=2);out.flush();os.fsync(out.fileno())
    os.replace(temp,path);path.chmod(0o600)
    directory=os.open(path.parent,os.O_RDONLY)
    try:os.fsync(directory)
    finally:os.close(directory)


class Journal:
    def __init__(self,folder):
        self.folder=folder;self.path=folder/'state.json'
        self.state=json.loads(self.path.read_text()) if self.path.exists() else {'pending':None,'history':[]}
    @property
    def pending(self):return self.state['pending']
    def begin(self,intent):
        if self.pending:raise UncertainAction('PRIOR_ACTION_STILL_PENDING')
        self.state['pending']={**intent,'id':uuid.uuid4().hex,'intentAt':dt.datetime.now(TZ).isoformat()}
        atomic_json(self.path,self.state)
    def complete(self,result):
        if not self.pending:raise RuntimeError('NO_ACTION_TO_COMPLETE')
        self.state['history'].append({'intent':self.pending,'result':result,'recordedAt':dt.datetime.now(TZ).isoformat()})
        self.state['pending']=None;atomic_json(self.path,self.state)
    def readonly(self,date):
        return self.state.get('readOnlyTasks',{}).get(date)
    def begin_readonly(self,date):
        if self.readonly(date):raise UnsafeState('READONLY_DAILY_LIMIT')
        self.state.setdefault('readOnlyTasks',{})[date]={'phase':'INTENT','startedAt':dt.datetime.now(TZ).isoformat(),'customerLimit':1}
        atomic_json(self.path,self.state)
    def complete_readonly(self,date,outcome):
        if not self.readonly(date):raise RuntimeError('NO_READONLY_INTENT')
        self.state['readOnlyTasks'][date]={'phase':'COMPLETE','outcome':outcome,'finishedAt':dt.datetime.now(TZ).isoformat(),'customerLimit':1}
        atomic_json(self.path,self.state)
