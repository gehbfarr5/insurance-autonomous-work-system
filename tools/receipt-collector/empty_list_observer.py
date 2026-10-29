"""Passive, same-session empty-list receipt collector for an already-open page.
No request replay, fetch interception, refresh, navigation or page writes.
Profile: exact origin/path, observed endpoint origin/path, and reviewed source pin.
Wire messages / bodies stay in memory; output contains only reason/counts/hash.
"""
import hashlib,json,time
from urllib.parse import urlsplit

class ObservationError(RuntimeError):
    pass

class Observer:
    def __init__(self, ws, profile, timeout=20, clock=time.monotonic):
        self.ws,self.profile,self.clock=ws,profile,clock
        self.end=clock()+timeout;self.serial=0;self.events=[]
    def remaining(self):
        left=self.end-self.clock()
        if left<=0:raise TimeoutError('EMPTY_OBSERVER_DEADLINE')
        return left
    def call(self,method,params):
        self.serial+=1;ident=self.serial
        self.ws.settimeout(self.remaining())
        self.ws.send(json.dumps({'id':ident,'method':method,'params':params}))
        while True:
            self.ws.settimeout(self.remaining());message=json.loads(self.ws.recv())
            if message.get('id')==ident:
                if 'error' in message or 'exceptionDetails' in message.get('result',{}):raise ObservationError('CDP_OBSERVATION_FAILED')
                return message.get('result',{})
            self.event(message)
    def event(self,message):
        # Never retain headers, query, postData, body or customer values.
        m,p=message.get('method'),message.get('params',{})
        if m=='Network.requestWillBeSent':
            u=urlsplit(p.get('request',{}).get('url',''))
            if (u.scheme+'://'+u.netloc,u.path)==(self.profile['endpointOrigin'],self.profile['endpointPath']):
                self.events.append({'kind':'request','id':p.get('requestId'),'loader':p.get('loaderId'),'redirect':bool(p.get('redirectResponse'))})
        elif m=='Network.responseReceived':
            self.events.append({'kind':'response','id':p.get('requestId'),'loader':p.get('loaderId'),'status':p.get('response',{}).get('status')})
        elif m in ('Network.loadingFinished','Network.loadingFailed'):
            self.events.append({'kind':'finished' if m.endswith('Finished') else 'failed','id':p.get('requestId')})
        if len(self.events)>2000:raise ObservationError('OBSERVER_EVENT_BUDGET')
    def run(self):
        p=self.profile
        if not p.get('sourcePin') or not p.get('salt'):
            return {'status':'BLOCKED','reason':'SOURCE_OR_INTENT_CONTEXT_MISSING'}
        # Establish exact target and keep the initial actual list object alive.
        expression="""(()=>{if(location.origin!==ORIGIN||location.pathname!==PATH)throw Error('WRONG_TARGET');const v=document.querySelector('.customer-list-page')?.__vue__;if(!v||!Array.isArray(v.customers))throw Error('LIST_UNKNOWN');return v.customers;})()""".replace('ORIGIN',json.dumps(p['origin'])).replace('PATH',json.dumps(p['path']))
        baseline=self.call('Runtime.evaluate',{'expression':expression,'returnByValue':False})
        handle=baseline.get('result',{}).get('objectId')
        if not handle:return {'status':'BLOCKED','reason':'BASELINE_OBJECT_UNAVAILABLE'}
        try:
            self.call('Network.enable',{})
            # Ignore anything already in flight before baseline+observation.
            self.events=[]
            while True:
                self.ws.settimeout(self.remaining());self.event(json.loads(self.ws.recv()))
                requests=[x for x in self.events if x['kind']=='request']
                if len(requests)>1:return {'status':'BLOCKED','reason':'QUERY_CYCLE_NOT_UNIQUE'}
                if not requests:continue
                request=requests[0]
                if not isinstance(request.get('id'),str) or not request['id'] or not isinstance(request.get('loader'),str) or not request['loader']:
                    return {'status':'BLOCKED','reason':'REQUEST_ID_OR_LOADER_MISSING'}
                ident=request['id'];related=[x for x in self.events if x.get('id')==ident]
                if request['redirect'] or any(x['kind']=='failed' for x in related):return {'status':'BLOCKED','reason':'QUERY_FAILED_OR_REDIRECTED'}
                responses=[x for x in related if x['kind']=='response']
                if not any(x['kind']=='finished' for x in related):continue
                if len(responses)!=1 or responses[0]['status']!=200 or responses[0]['loader']!=request['loader']:
                    return {'status':'BLOCKED','reason':'HTTP_OR_LOADER_UNCONFIRMED'}
                body=self.call('Network.getResponseBody',{'requestId':ident})
                if body.get('base64Encoded') or not isinstance(body.get('body'),str) or len(body['body'])>2000000:
                    return {'status':'BLOCKED','reason':'BODY_FORMAT_OR_SIZE'}
                data=json.loads(body['body']);body.clear()
                if not isinstance(data,dict) or data.get('code')!='200' or data.get('content')!=[]:
                    return {'status':'BLOCKED','reason':'NOT_CONFIRMED_SUCCESS_EMPTY'}
                # Only a fresh array assigned after the unique successful query
                # can be correlated with the reviewed setCustomers(content) branch.
                fn="""function(){if(location.origin!==ORIGIN||location.pathname!==PATH)throw Error('WRONG_TARGET');const v=document.querySelector('.customer-list-page')?.__vue__;if(!v||!Array.isArray(v.customers))throw Error('LIST_UNKNOWN');return {changed:this!==v.customers,loading:v.loadingPage,count:v.customers.length,visible:document.visibilityState==='visible'};}""".replace('ORIGIN',json.dumps(p['origin'])).replace('PATH',json.dumps(p['path']))
                state=self.call('Runtime.callFunctionOn',{'objectId':handle,'functionDeclaration':fn,'returnByValue':True}).get('result',{}).get('value',{})
                if len([x for x in self.events if x['kind']=='request'])!=1:return {'status':'BLOCKED','reason':'QUERY_CYCLE_NOT_UNIQUE'}
                if state.get('changed') is not True or state.get('loading') is not False or type(state.get('count')) is not int or state.get('count')!=0 or state.get('visible') is not True:
                    return {'status':'BLOCKED','reason':'FRESH_EMPTY_ASSIGNMENT_UNCONFIRMED'}
                return {'status':'SUCCESS_EMPTY','count':0,'queryConfirmed':True,'sourcePin':p['sourcePin'],
                        'cycleHash':hashlib.sha256((p['salt']+'\0'+ident).encode()).hexdigest()}
        finally:
            # Do not disable a shared session's Network domain; caller owns a
            # dedicated connection and must close it even on timeout/TERM.
            if self.clock()<self.end:
                self.call('Runtime.releaseObject',{'objectId':handle})

def observe(ws,profile,timeout=20):
    try:return Observer(ws,profile,timeout).run()
    except (TimeoutError,ObservationError,ValueError,TypeError,KeyError):
        return {'status':'BLOCKED','reason':'OBSERVATION_INCOMPLETE'}
