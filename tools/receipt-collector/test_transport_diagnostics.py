import subprocess
import unittest
from unittest.mock import patch
from transport_diagnostics import checked_output, TransportFailure

class TransportDiagnostics(unittest.TestCase):
    def test_exact_stage_budget_privacy_and_single_attempt(self):
        secret='PRIVATE_ENDPOINT_OR_TOKEN'
        for stage in ['socket_inventory','target_list']:
            with self.subTest(stage=stage), patch('transport_diagnostics.subprocess.check_output',side_effect=subprocess.TimeoutExpired([secret],7,output=secret,stderr=secret)) as call:
                with self.assertRaises(TransportFailure) as ctx:
                    checked_output(stage,[secret],timeout=7)
                self.assertEqual(call.call_count,1)
                self.assertEqual(ctx.exception.diagnostic,{'stage':stage,'kind':'TIMEOUT','budgetSeconds':7})
                self.assertNotIn(secret,str(ctx.exception));self.assertIsNone(ctx.exception.__cause__)
    def test_nonzero_is_failure_not_fallback(self):
        with patch('transport_diagnostics.subprocess.check_output',side_effect=subprocess.CalledProcessError(1,['PRIVATE'])):
            with self.assertRaisesRegex(TransportFailure,'TRANSPORT_FAILED_TARGET_LIST'):
                checked_output('target_list',['PRIVATE'],timeout=3)
    def test_success_preserves_bytes(self):
        with patch('transport_diagnostics.subprocess.check_output',return_value=b'bytes'):
            self.assertEqual(checked_output('target_list',['unused'],timeout=3),b'bytes')
    def test_unknown_stage_and_budget_rejected(self):
        with self.assertRaises(ValueError):checked_output('arbitrary',['unused'],timeout=3)
        for budget in [True,0,-1,float('nan'),float('inf')]:
            with self.assertRaises(ValueError):TransportFailure('target_list','TIMEOUT',budget)
if __name__=='__main__':unittest.main()
