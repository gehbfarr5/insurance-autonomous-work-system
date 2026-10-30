import unittest
from unittest.mock import patch
import bridge
READY={'status':'SNAPSHOT','customerSelected':False,'isAnswering':False,'contentLoading':False,'stopped':False,'recordHashes':[]}
MISSING={'status':'REVIEW','reason':'RECORDS_NOT_UNIQUE','diagnostics':{'uniqueRecordArrays':0}}
class BaselineReadiness(unittest.TestCase):
    def setUp(self):self.now=0
    def clock(self):return self.now
    def sleep(self,n):self.now+=n
    def call(self,**kw):return bridge.baseline(None,'synthetic',{},sleep=self.sleep,clock=self.clock,**kw)
    def test_unmounted_then_actual_empty_snapshot(self):
        with patch.object(bridge,'capture',side_effect=[MISSING,READY]) as cap:
            self.assertEqual(self.call()['before'],READY);self.assertEqual(cap.call_count,2)
            self.assertEqual(self.now,1)
    def test_never_mounted_times_out_without_fabrication(self):
        with patch.object(bridge,'capture',return_value=MISSING) as cap:
            with self.assertRaisesRegex(RuntimeError,'NOT_MOUNTED_TIMEOUT'):self.call(timeout=2)
            self.assertEqual(cap.call_count,2)
    def test_ambiguity_missing_diagnostic_and_bad_type_fail_immediately(self):
        for s in [{'status':'REVIEW','reason':'RECORDS_NOT_UNIQUE'}, {**MISSING,'diagnostics':{'uniqueRecordArrays':2}}, {**MISSING,'diagnostics':{'uniqueRecordArrays':False}}, {'status':'REVIEW','reason':'WRONG_TARGET'}]:
            with self.subTest(s=s),patch.object(bridge,'capture',return_value=s) as cap:
                with self.assertRaisesRegex(RuntimeError,'BASELINE_UNAVAILABLE'):self.call()
                self.assertEqual(cap.call_count,1)
    def test_selected_or_active_never_accepted(self):
        for key in ['customerSelected','isAnswering','contentLoading','stopped']:
            with self.subTest(key=key),patch.object(bridge,'capture',return_value={**READY,key:True}):
                with self.assertRaises(RuntimeError):self.call()
    def test_transport_failure_propagates_without_retry(self):
        with patch.object(bridge,'capture',side_effect=TimeoutError('synthetic')) as cap:
            with self.assertRaises(TimeoutError):self.call()
            self.assertEqual(cap.call_count,1)
if __name__=='__main__':unittest.main()
