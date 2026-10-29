/* Read-only Vue snapshot collector. No navigation, requests, setters or storage.
 * Caller supplies an existing root, per-intent random salt and expected question.
 * Raw question/customer/record/conversation values never leave this function.
 * Known computed/ref fields may be read; only hash/boolean metadata is returned.
 */
async function collectAiSnapshot(root, options, digest) {
  const missing = code => ({status:'REVIEW', reason:code});
  if (!options || typeof options.salt !== 'string' || options.salt.length < 32 ||
      typeof options.expectedQuestion !== 'string' || !options.expectedQuestion ||
      typeof options.versionBinding !== 'string' || !options.versionBinding) return missing('INVALID_CONTEXT');
  const fingerprint = value => digest(options.salt + '\0' + value);
  const ref = value => value && typeof value === 'object' && value.__v_isRef === true ? value.value : value;
  try {
    const queue = [], seen = new WeakSet(), nodes = [];
    const push = x => {if(x && typeof x==='object' && !seen.has(x)){seen.add(x);queue.push(x);}};
    push(root && root._vnode); push(root && root.__vueParentComponent);
    push(root && root.__vue_app__ && root.__vue_app__._instance);
    if (!queue.length) return missing('ROOT_NOT_EXPOSED');
    for(let i=0;i<queue.length;i++) {
      if(queue.length>5000) return missing('TREE_TRUNCATED');
      const x=queue[i];
      if(x.type && x.setupState && x.props) nodes.push(x);
      push(x.component);push(x.subTree);
      for(const k of ['children','dynamicChildren']) if(Array.isArray(x[k])) {
        if(x[k].length>5000) return missing('TREE_TRUNCATED');
        x[k].forEach(push);
      }
      if(x.suspense)push(x.suspense.activeBranch);
    }
    const arrays = new Set(), conversations = new Set(), customers = new Set(), provided = new WeakSet();
    for(const n of nodes) {
      const records = n.props.records;
      if(Array.isArray(records)) arrays.add(records);
      let p=n.provides; const chain=new WeakSet();let depth=0;
      while(p && typeof p==='object') {
        if(chain.has(p) || ++depth>32) return missing('PROVIDES_TRUNCATED');
        chain.add(p);
        if(!provided.has(p)) {
          provided.add(p);
          const symbols=Object.getOwnPropertySymbols(p);
          if(symbols.length>160)return missing('PROVIDES_TRUNCATED');
          for(const symbol of symbols) {
            const d=Object.getOwnPropertyDescriptor(p,symbol);
            if(!d || !('value' in d))continue;
            const v=d.value;
            if(!v || typeof v!=='object')continue;
            if('conversationId' in v && 'isAnswering' in v && 'contentLoading' in v && 'isStopAnswer' in v)conversations.add(v);
            if('globalCustomerId' in v && 'globalZmCustomerId' in v)customers.add(v);
          }
        }
        p=Object.getPrototypeOf(p);
      }
    }
    if(arrays.size!==1)return missing('RECORDS_NOT_UNIQUE');
    if(conversations.size!==1 || customers.size!==1)return missing('PROVIDERS_NOT_UNIQUE');
    const records=[...arrays][0], state=[...conversations][0], customer=[...customers][0];
    if(records.length>1000)return missing('RECORDS_TRUNCATED');
    const a=ref(customer.globalCustomerId), b=ref(customer.globalZmCustomerId);
    if(typeof a!=='string'||typeof b!=='string')return missing('CUSTOMER_STATE_UNKNOWN');
    const flags={isAnswering:ref(state.isAnswering),contentLoading:ref(state.contentLoading),stopped:ref(state.isStopAnswer)};
    if(Object.values(flags).some(x=>typeof x!=='boolean'))return missing('CONVERSATION_FLAGS_UNKNOWN');
    const conversationId=ref(state.conversationId);
    if(typeof conversationId!=='string')return missing('CONVERSATION_ID_UNKNOWN');
    const recordHashes=[];
    for(const record of records) {
      if(!record || !Array.isArray(record.answerList))return missing('RECORD_SHAPE_UNKNOWN');
      if(record.answerList.length>100)return missing('ANSWERS_TRUNCATED');
      for(const answer of record.answerList) {
        if(!answer || typeof answer.recordId!=='string')return missing('RECORD_ID_UNKNOWN');
        if(recordHashes.length>=2000)return missing('HASH_BUDGET_EXCEEDED');
        if(answer.recordId)recordHashes.push(await fingerprint(answer.recordId));
      }
    }
    const out={status:'SNAPSHOT', versionBinding:options.versionBinding,
      questionHash:await fingerprint(options.expectedQuestion), recordHashes,
      conversationHash:conversationId?await fingerprint(conversationId):null,
      customerSelected:a!==''||b!=='', ...flags, last:null};
    if(!records.length)return out;
    const group=records[records.length-1], answer=group.answerList[0];
    if(!answer)return missing('LAST_ANSWER_ABSENT');
    const matching=nodes.filter(n=>n.type.name==='ChatAnswerThink' && n.props.isLastAnswer===true &&
      Array.isArray(n.props.answerList) && n.props.answerList[0]===answer);
    if(matching.length!==1)return missing('LAST_RENDERER_NOT_UNIQUE');
    const n=matching[0], parser=ref(n.setupState.parserStatus), paused=ref(n.setupState.isAnswerPaused);
    if(typeof parser!=='string'||typeof paused!=='boolean')return missing('PARSER_STATE_UNKNOWN');
    if(typeof group.question!=='string' || typeof answer.question!=='string' ||
       typeof answer.conversationId!=='string' || !answer.conversationId || !answer.recordId)return missing('LAST_ASSOCIATION_UNKNOWN');
    if(!Array.isArray(answer.streamData)||!answer.streamData.length)return missing('STREAM_ABSENT');
    const last=answer.streamData[answer.streamData.length-1];
    if(!last || typeof last.endAnswerFlag!=='boolean'||typeof last.error!=='boolean')return missing('END_OR_ERROR_UNKNOWN');
    out.last={recordHash:await fingerprint(answer.recordId),groupQuestionHash:await fingerprint(group.question),
      questionHash:await fingerprint(answer.question),conversationHash:await fingerprint(answer.conversationId),
      endAnswerFlag:last.endAnswerFlag,error:last.error,parserStatus:parser,paused};
    return out;
  } catch (_) {return missing('SNAPSHOT_READ_ERROR');}
}
if(typeof module!=='undefined')module.exports={collectAiSnapshot};
