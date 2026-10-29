import importlib.util,json,pathlib,unittest
p=pathlib.Path(__file__).with_name('empty_list_observer.py')
spec=importlib.util.spec_from_file_location('empty_observer',p);mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
PROFILE={'origin':'https://example.invalid','path':'/customers','endpointOrigin':'https://example.invalid','endpointPath':'/query','sourcePin':'synthetic-pin','salt':'s'*64}
SECRET='PRIVATE_CUSTOMER_HEADERS_BODY'
class WS:
 def __init__(self,mode='positive'):self.mode=mode;self.queue=[];self.calls=[]
 def settimeout(self,value):pass
 def send(self,message):
  m=json.loads(message);method=m['method'];self.calls.append(method);r={}
  if method=='Runtime.evaluate':r={'result':{'objectId':'private-array-handle'}}
  if method=='Network.enable':
   self.queue.append(json.dumps({'id':m['id'],'result':{}}))
   if self.mode=='no_request':return
   events=[{'method':'Network.requestWillBeSent','params':{'requestId':'private-request','loaderId':None if self.mode=='missing_loader' else 'L','request':{'url':'https://example.invalid/query?private='+SECRET,'headers':{'auth':SECRET},'postData':SECRET}}}, {'method':'Network.responseReceived','params':{'requestId':'private-request','loaderId':'OTHER' if self.mode=='loader' else 'L','response':{'status':500 if self.mode=='http' else 200,'headers':{'private':SECRET}}}}, {'method':'Network.loadingFailed' if self.mode=='failed' else 'Network.loadingFinished','params':{'requestId':'private-request'}}]
   if self.mode=='duplicate':events.insert(1,{'method':'Network.requestWillBeSent','params':{'requestId':'second','loaderId':None if self.mode=='missing_loader' else 'L','request':{'url':'https://example.invalid/query'}}})
   self.queue.extend(json.dumps(x) for x in events);return
  if method=='Network.getResponseBody':
   data={'code':'500' if self.mode=='business' else '200','content':[{'private':SECRET}] if self.mode=='nonempty' else []}
   r={'body':'not json' if self.mode=='malformed' else json.dumps(data),'base64Encoded':self.mode=='base64'}
  if method=='Runtime.callFunctionOn':r={'result':{'value':{'changed':self.mode!='unchanged','loading':self.mode=='loading','count':0,'visible':self.mode!='hidden'}}}
  self.queue.append(json.dumps({'id':m['id'],'result':r}))
 def recv(self):
  if not self.queue:raise TimeoutError('synthetic timeout')
  return self.queue.pop(0)
class Tests(unittest.TestCase):
 def test_positive_and_privacy(self):
  ws=WS();out=mod.observe(ws,PROFILE);self.assertEqual(out['status'],'SUCCESS_EMPTY');self.assertTrue(out['queryConfirmed']);self.assertNotIn(SECRET,json.dumps(out));self.assertNotIn('private-request',json.dumps(out));self.assertEqual(ws.calls[-1],'Runtime.releaseObject');self.assertFalse(any(x.startswith('Fetch.') for x in ws.calls))
 def test_failures_block(self):
  for mode in ['missing_loader','no_request','loader','http','failed','duplicate','business','nonempty','malformed','base64','unchanged','loading','hidden']:
   with self.subTest(mode=mode):self.assertEqual(mod.observe(WS(mode),PROFILE)['status'],'BLOCKED')
 def test_termination_not_swallowed(self):
  class TerminatedError(RuntimeError):pass
  class Terminated(WS):
   def recv(self):raise TerminatedError('TERM')
  with self.assertRaises(TerminatedError):mod.observe(Terminated(),PROFILE)
 def test_context_required(self):self.assertEqual(mod.observe(WS(),{})['status'],'BLOCKED')
if __name__=='__main__':unittest.main(verbosity=2)
