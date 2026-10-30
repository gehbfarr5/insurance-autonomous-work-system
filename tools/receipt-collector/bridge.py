"""Local bridge for the existing adapter. No dispatch, navigation or network here.
The caller injects its already authorized exact-target evaluate function.
"""
import json, pathlib, secrets, subprocess, time
ROOT = pathlib.Path(__file__).resolve().parent

def node(action, value, timeout=5):
    script = "const fs=require('node:fs');const x=JSON.parse(fs.readFileSync(0,'utf8'));"
    if action == 'expression':
        script += "process.stdout.write(require('./build-expression.cjs').buildExpression(x));"
    elif action == 'reconcile':
        script += "process.stdout.write(JSON.stringify(require('./reconcile.cjs').reconcile(x.before,x.after)));"
    else:
        raise ValueError('UNSUPPORTED_LOCAL_ACTION')
    result = subprocess.run(['node', '-e', script], input=json.dumps(value), text=True,
                            capture_output=True, timeout=timeout, cwd=ROOT)
    if result.returncode:
        raise RuntimeError('RECEIPT_NODE_FAILED')  # never expose stderr/context
    return result.stdout if action == 'expression' else json.loads(result.stdout)

def baseline(evaluate, question, profile, timeout=20, sleep=time.sleep, clock=time.monotonic):
    context = {**profile, 'salt': secrets.token_hex(32), 'expectedQuestion': question}
    deadline = clock() + timeout
    while True:
        remaining = deadline - clock()
        if remaining <= 0:
            raise RuntimeError('RECEIPT_BASELINE_RECORDS_NOT_MOUNTED_TIMEOUT')
        snapshot = capture(evaluate, context, timeout=remaining)
        if snapshot.get('status') == 'SNAPSHOT':
            break
        diagnostic = snapshot.get('diagnostics', {})
        count = diagnostic.get('uniqueRecordArrays')
        if not (snapshot.get('reason') == 'RECORDS_NOT_UNIQUE' and
                type(count) is int and count == 0):
            raise RuntimeError('RECEIPT_BASELINE_UNAVAILABLE')
        # The observed page exists before records mount. Wait for real state;
        # never substitute an empty array or proceed on ambiguous candidates.
        sleep(min(1, max(0, deadline - clock())))
    if snapshot.get('customerSelected') is not False:
        raise RuntimeError('RECEIPT_BASELINE_UNAVAILABLE')
    if any(snapshot.get(k) is not False for k in ['isAnswering','contentLoading','stopped']):
        raise RuntimeError('RECEIPT_BASELINE_NOT_IDLE')
    return {'context': context, 'before': snapshot}

def capture(evaluate, context, timeout=30):
    deadline = time.monotonic() + timeout
    expression = node('expression', context, timeout=min(5,timeout))
    remaining = deadline-time.monotonic()
    if remaining <= 0:raise TimeoutError('RECEIPT_CAPTURE_DEADLINE')
    value = evaluate(expression, context['path'], context['origin'],
                     timeout=min(15,remaining), total_timeout=remaining)
    if not isinstance(value, dict):
        raise RuntimeError('RECEIPT_SNAPSHOT_INVALID')
    return value

def poll(evaluate, bundle, timeout=60, sleep=time.sleep, clock=time.monotonic):
    if not isinstance(bundle, dict) or not all(k in bundle for k in ['context','before']):
        return {'verdict':'REVIEW','reason':'BASELINE_MISSING'}
    deadline = clock() + timeout
    last = {'verdict':'REVIEW','reason':'ANSWER_NOT_OBSERVED'}
    while clock() < deadline:
        after = capture(evaluate, bundle['context'], timeout=deadline-clock())
        remaining = deadline-clock()
        if remaining <= 0:return {'verdict':'REVIEW','reason':'ANSWER_DEADLINE','timedOut':True}
        last = node('reconcile', {'before':bundle['before'], 'after':after}, timeout=min(5,remaining))
        if last['verdict'] in ('ACCEPT','FAIL'):
            return {**last, 'snapshot':after}
        sleep(min(2, max(0,deadline-clock())))
    return {**last, 'verdict':'REVIEW', 'timedOut':True}
