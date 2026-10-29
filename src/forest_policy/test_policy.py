import copy, datetime as dt, json, pathlib, tempfile, unittest
from decimal import Decimal
from policy import run_workflow, snapshot, UnsafeState, UncertainAction
from journal import Journal
PINS={'onClickCheck':'original-sign','onClickCollect1':'original-collect'}
DATE='2026-10-26'

def raw(signed=True,pending=None,balance='485.5',date=DATE):
    pending=[] if pending is None else pending
    day=dt.date.fromisoformat(date)
    return {'ready':True,'component':'mhdsl','visible':'visible','businessDate':date,
      'observedAt':date+'T01:00:00+08:00','dateLabel':day.strftime('%m.%d')+' 周'+'一二三四五六日'[day.weekday()],
      'signDates':[{'date':date,'signFlag':'1' if signed else '0'}],'signFlag':'1' if signed else '0',
      'signDisabled':signed,'balance':balance,'pending':pending,'oneKeyVisible':bool(pending),
      'treeStage':4,'treeCount':3,'medalCount':1,'overlay':False,'methodSources':PINS.copy(),
      'freshRead':{'energyResponse':True,'signAssignment':True,'responseCode':'00','observedAfterOriginalQueries':True}}

class Adapter:
    def __init__(self,state):self.state=state;self.signs=0;self.collects=0;self.failure=None
    def read_fresh(self):return copy.deepcopy(self.state)
    def sign(self,date):
        self.signs+=1;self.state['signFlag']='1';self.state['signDisabled']=True
        self.state['signDates'][0]['signFlag']='1';self.state['balance']=str(Decimal(self.state['balance'])+Decimal('.5'))
        if self.failure=='sign-disconnect':raise OSError('connection lost after server accepted')
        if self.failure=='midnight':self.state['businessDate']='2026-10-27'
        return {'status':'CLICKED'}
    def collect(self,before):
        self.collects+=1;self.state['balance']=str(Decimal(self.state['balance'])+Decimal(before['expectedCollection']))
        self.state['pending']=[];self.state['oneKeyVisible']=False
        if self.failure=='collect-disconnect':raise OSError('connection lost after collection')
        if self.failure=='missing-credit':self.state['balance']=before['balance']
        return {'status':'CLICKED'}

class PolicyTests(unittest.TestCase):
    def setUp(self):self.temp=tempfile.TemporaryDirectory();self.dir=pathlib.Path(self.temp.name);self.journal=Journal(self.dir)
    def tearDown(self):self.temp.cleanup()
    def execute(self,adapter,execute=True):return run_workflow(adapter,self.journal,DATE,execute,PINS)
    def test_already_signed_empty_no_write(self):
        a=Adapter(raw());r=self.execute(a);self.assertEqual(r['status'],'PASS');self.assertEqual((a.signs,a.collects),(0,0))
    def test_sign_then_collect_and_repeat(self):
        a=Adapter(raw(False,[{'ids':[12,13],'energyType':'2','energyValue':'5'}],'475'))
        r=self.execute(a);self.assertEqual(r['after']['balance'],'485.5');self.assertEqual((a.signs,a.collects),(1,1))
        r=self.execute(a);self.assertEqual((a.signs,a.collects),(1,1));self.assertIsNone(self.journal.pending)
    def test_inspect_does_not_submit(self):
        a=Adapter(raw(False,[{'ids':[12],'energyType':'1','energyValue':'.5'}]));self.execute(a,False)
        self.assertEqual((a.signs,a.collects),(0,0))
    def test_stale_date_blocks(self):
        a=Adapter(raw(date='2026-10-25'))
        with self.assertRaisesRegex(UnsafeState,'DATE_CHANGED'):self.execute(a)
        self.assertEqual(a.signs,0)
    def test_default_ui_without_fresh_response_blocks(self):
        a=Adapter(raw(False,balance='0'));a.state.pop('freshRead')
        with self.assertRaisesRegex(UnsafeState,'FRESH_SERVER_READ_NOT_CONFIRMED'):self.execute(a)
        self.assertEqual((a.signs,a.collects),(0,0))
    def test_conflicting_sign_flags_blocks(self):
        a=Adapter(raw());a.state['signDates'][0]['signFlag']='0'
        with self.assertRaisesRegex(UnsafeState,'SIGN_STATE_CONFLICT'):self.execute(a)
    def test_implementation_change_blocks(self):
        a=Adapter(raw());a.state['methodSources']={}
        with self.assertRaisesRegex(UnsafeState,'IMPLEMENTATION_CHANGED'):self.execute(a)
    def test_unknown_reward_type_blocks(self):
        a=Adapter(raw(pending=[{'ids':[3],'energyType':'4','energyValue':'5'}]))
        with self.assertRaisesRegex(UnsafeState,'UNREVIEWED_REWARD_TYPE'):self.execute(a)
    def test_duplicate_reward_id_blocks(self):
        a=Adapter(raw(pending=[{'ids':[3,3],'energyType':'2','energyValue':'5'}]))
        with self.assertRaisesRegex(UnsafeState,'DUPLICATE_REWARD_ID'):self.execute(a)
    def test_hidden_or_overlay_page_blocks(self):
        for key,value in [('visible','hidden'),('overlay',True)]:
            a=Adapter(raw());a.state[key]=value
            with self.assertRaises(UnsafeState):self.execute(a)
    def test_intent_survives_process_restart_sign(self):
        a=Adapter(raw(False));a.failure='sign-disconnect'
        with self.assertRaises(OSError):self.execute(a)
        self.assertEqual(json.loads((self.dir/'state.json').read_text())['pending']['kind'],'SIGN')
        self.journal=Journal(self.dir);a.failure=None;self.execute(a)
        self.assertEqual(a.signs,1);self.assertIsNone(self.journal.pending)
    def test_intent_survives_collection_disconnect_no_replay(self):
        a=Adapter(raw(pending=[{'ids':[4],'energyType':'2','energyValue':'10'}]));a.failure='collect-disconnect'
        with self.assertRaises(OSError):self.execute(a)
        self.journal=Journal(self.dir);a.failure=None;self.execute(a)
        self.assertEqual(a.collects,1)
    def test_uncertain_collection_stays_pending(self):
        a=Adapter(raw(pending=[{'ids':[4],'energyType':'2','energyValue':'10'}]));a.failure='missing-credit'
        with self.assertRaises(UncertainAction):self.execute(a)
        a.failure=None;self.journal=Journal(self.dir)
        with self.assertRaisesRegex(UncertainAction,'PRIOR_ACTION_UNRESOLVED'):self.execute(a)
        self.assertEqual(a.collects,1)
    def test_midnight_after_submit_does_not_replay(self):
        a=Adapter(raw(False));a.failure='midnight'
        with self.assertRaisesRegex(UnsafeState,'DATE_CHANGED'):self.execute(a)
        self.assertEqual(a.signs,1);self.assertIsNotNone(self.journal.pending)
    def test_reward_difference_reported_not_masked(self):
        class NoReward(Adapter):
            def sign(self,date):
                before=self.state['balance'];result=super().sign(date);self.state['balance']=before;return result
        a=NoReward(raw(False));r=self.execute(a);self.assertEqual(r['status'],'REVIEW');self.assertIsNone(self.journal.pending)

    def test_sign_phase_precedes_and_defers_collection(self):
        a=Adapter(raw(False,[{'ids':[12],'energyType':'2','energyValue':'10'}],'475'))
        result=run_workflow(a,self.journal,DATE,True,PINS,collect=False)
        self.assertEqual(result['phase'],'SIGN_ONLY');self.assertEqual((a.signs,a.collects),(1,0))
        self.assertEqual(len(result['after']['pendingIds']),1)

if __name__=='__main__':unittest.main()
