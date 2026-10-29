"""Evidence-driven forest policy. No customer data or credentials belong in this module."""
from decimal import Decimal, InvalidOperation
import datetime as dt, hashlib, json

class UnsafeState(RuntimeError): pass
class UncertainAction(RuntimeError): pass

def amount(value):
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        raise UnsafeState('INVALID_AMOUNT')
    try: number = Decimal(str(value))
    except InvalidOperation as error: raise UnsafeState('INVALID_AMOUNT') from error
    if not number.is_finite() or number < 0: raise UnsafeState('INVALID_AMOUNT')
    return number

def snapshot(raw, expected_date, pins):
    if raw.get('ready') is not True or raw.get('component') != 'mhdsl' or raw.get('visible') != 'visible':
        raise UnsafeState('FOREST_NOT_READY_OR_NOT_FOREGROUND')
    if raw.get('businessDate') != expected_date: raise UnsafeState('DATE_CHANGED')
    day = dt.date.fromisoformat(expected_date)
    expected_label = day.strftime('%m.%d') + ' 周' + '一二三四五六日'[day.weekday()]
    if raw.get('dateLabel') != expected_label: raise UnsafeState('DATE_CARD_CONFLICT')
    if raw.get('methodSources') != pins: raise UnsafeState('WEB_IMPLEMENTATION_CHANGED')
    if raw.get('overlay') is not False: raise UnsafeState('FOREST_OVERLAY_PRESENT')
    if raw.get('freshRead') != {'energyResponse':True,'signAssignment':True,'responseCode':'00','observedAfterOriginalQueries':True}:
        raise UnsafeState('FRESH_SERVER_READ_NOT_CONFIRMED')
    records = raw.get('signDates')
    if not isinstance(records, list): raise UnsafeState('MISSING_SIGN_DATES')
    today = [x for x in records if x.get('date') == expected_date]
    if len(today) != 1 or raw.get('signFlag') not in ('0','1') or today[0].get('signFlag') != raw['signFlag']:
        raise UnsafeState('SIGN_STATE_CONFLICT')
    if raw.get('signDisabled') != (raw['signFlag'] == '1'): raise UnsafeState('SIGN_CONTROL_CONFLICT')
    balance = amount(raw.get('balance'))
    pending, ids, expected = [], set(), Decimal('0')
    if not isinstance(raw.get('pending'), list): raise UnsafeState('MISSING_PENDING_LIST')
    for item in raw['pending']:
        if item.get('energyType') not in ('1','2'): raise UnsafeState('UNREVIEWED_REWARD_TYPE')
        group = item.get('ids')
        if not isinstance(group,list) or not group: raise UnsafeState('MISSING_REWARD_IDS')
        value = amount(item.get('energyValue'))
        if value <= 0: raise UnsafeState('INVALID_REWARD_VALUE')
        normalized=[]
        for reward_id in group:
            if isinstance(reward_id,bool) or not isinstance(reward_id,(str,int)) or not str(reward_id).isdigit() or int(reward_id)<=0:
                raise UnsafeState('INVALID_REWARD_ID')
            reward_id=str(reward_id)
            if reward_id in ids: raise UnsafeState('DUPLICATE_REWARD_ID')
            ids.add(reward_id); normalized.append(reward_id)
        pending.append({'ids':sorted(normalized), 'energyType':item['energyType'], 'energyValue':str(value)})
        expected += value*len(normalized)
    if raw.get('oneKeyVisible') != bool(pending): raise UnsafeState('COLLECT_CONTROL_CONFLICT')
    return {'date':expected_date,'observedAt':raw['observedAt'],'signed':raw['signFlag']=='1',
        'balance':str(balance),'pending':pending,'pendingIds':sorted(ids),'expectedCollection':str(expected),
        'treeStage':raw['treeStage'],'treeCount':raw['treeCount'],'medalCount':raw['medalCount'],
        'signDates':records,'methodFingerprint':hashlib.sha256(json.dumps(pins,sort_keys=True).encode()).hexdigest()}

def reconcile(pending, current):
    if pending['kind']=='SIGN':
        records=[x for x in current['signDates'] if x['date']==pending['date']]
        if len(records)==1 and records[0]['signFlag']=='1': return 'SIGNED_CONFIRMED_BY_FRESH_READ'
    elif pending['kind']=='COLLECT':
        absent=set(pending['ids']).isdisjoint(current['pendingIds'])
        increased=amount(current['balance'])>=amount(pending['beforeBalance'])+amount(pending['expectedDelta'])
        if absent and increased: return 'COLLECTION_EFFECT_OBSERVED_NO_REPLAY'
    raise UncertainAction('PRIOR_ACTION_UNRESOLVED_NO_REPLAY')

def run_workflow(adapter, journal, date, execute, pins, collect=True):
    def read(): return snapshot(adapter.read_fresh(), date, pins)
    current=read(); before=current
    decisions=[]; warnings=[]
    if journal.pending:
        outcome=reconcile(journal.pending,current)
        journal.complete({'outcome':outcome,'snapshot':current})
        decisions.append({'action':'RECONCILE','outcome':outcome})
    if not execute: return {'status':'PASS','mode':'INSPECT','before':before,'after':current,'decisions':decisions}
    if current['signed']:
        decisions.append({'action':'SIGN','outcome':'SKIP_ALREADY_SIGNED'})
    else:
        intent={'kind':'SIGN','date':date,'beforeBalance':current['balance'],'expectedDelta':'0.5'}
        journal.begin(intent)
        ack=adapter.sign(date)
        if ack.get('status')!='CLICKED':
            journal.complete({'outcome':'NOT_SENT','ack':ack})
            raise UnsafeState('SIGN_NOT_SENT_STATE_CHANGED')
        after=read()
        if not after['signed']: raise UncertainAction('SIGN_NOT_CONFIRMED_NO_REPLAY')
        delta=amount(after['balance'])-amount(current['balance'])
        if delta!=Decimal('0.5'): warnings.append('SIGN_REWARD_DELTA_REQUIRES_REVIEW')
        journal.complete({'outcome':'SIGNED','delta':str(delta),'snapshot':after})
        decisions.append({'action':'SIGN','outcome':'SIGNED','delta':str(delta)})
        current=after
    if warnings:
        return {'status':'REVIEW','mode':'RUN','before':before,'after':current,'decisions':decisions,'warnings':warnings}
    if not collect:
        return {'status':'PASS','mode':'RUN','phase':'SIGN_ONLY','before':before,'after':current,'decisions':decisions}
    if not current['pendingIds']:
        decisions.append({'action':'COLLECT','outcome':'SKIP_EMPTY'})
    else:
        intent={'kind':'COLLECT','date':date,'ids':current['pendingIds'],
            'beforeBalance':current['balance'],'expectedDelta':current['expectedCollection']}
        journal.begin(intent)
        ack=adapter.collect(current)
        if ack.get('status')!='CLICKED':
            journal.complete({'outcome':'NOT_SENT','ack':ack})
            raise UnsafeState('COLLECTION_NOT_SENT_STATE_CHANGED')
        after=read()
        if set(current['pendingIds']).intersection(after['pendingIds']):
            raise UncertainAction('COLLECTION_IDS_STILL_PRESENT_NO_REPLAY')
        delta=amount(after['balance'])-amount(current['balance'])
        if delta < amount(current['expectedCollection']):
            raise UncertainAction('COLLECTION_CREDIT_UNCONFIRMED_NO_REPLAY')
        if delta!=amount(current['expectedCollection']): warnings.append('EXTRA_CREDIT_REQUIRES_REVIEW')
        journal.complete({'outcome':'COLLECTED','delta':str(delta),'snapshot':after})
        decisions.append({'action':'COLLECT','outcome':'COLLECTED','delta':str(delta)})
        current=after
    return {'status':'REVIEW' if warnings else 'PASS','mode':'RUN','before':before,'after':current,
        'observedTotalDelta':str(amount(current['balance'])-amount(before['balance'])),
        'decisions':decisions,'warnings':warnings}
