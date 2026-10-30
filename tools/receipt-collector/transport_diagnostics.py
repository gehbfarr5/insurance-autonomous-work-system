"""Stage-tagged transport failures; never retain commands, output or endpoints."""
import math
import subprocess

STAGES = frozenset({'socket_inventory', 'target_list', 'bridge_handshake', 'runtime_send', 'runtime_receive'})

class TransportFailure(RuntimeError):
    def __init__(self, stage, kind, budget):
        if stage not in STAGES or kind not in {'TIMEOUT', 'FAILED'}:
            raise ValueError('INVALID_TRANSPORT_DIAGNOSTIC')
        if isinstance(budget, bool) or not isinstance(budget, (int, float)) or not math.isfinite(budget) or budget <= 0:
            raise ValueError('INVALID_TRANSPORT_BUDGET')
        self.diagnostic = {'stage': stage, 'kind': kind, 'budgetSeconds': round(budget, 3)}
        super().__init__('TRANSPORT_' + kind + '_' + stage.upper() + '_BUDGET_' + str(round(budget, 3)))

def checked_output(stage, command, *, timeout, **kwargs):
    if stage not in {'socket_inventory', 'target_list'}:
        raise ValueError('INVALID_OUTPUT_STAGE')
    try:
        return subprocess.check_output(command, timeout=timeout, **kwargs)
    except subprocess.TimeoutExpired:
        raise TransportFailure(stage, 'TIMEOUT', timeout) from None
    except subprocess.CalledProcessError:
        raise TransportFailure(stage, 'FAILED', timeout) from None
