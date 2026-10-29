/* Snapshot reconciliation only; never dispatches an action. */
function reconcile(before, after) {
  const result=(verdict,reason)=>({verdict,reason});
  if(!before||!after||before.status!=='SNAPSHOT'||after.status!=='SNAPSHOT')return result('REVIEW','SNAPSHOT_INCOMPLETE');
  const hash=x=>typeof x==='string'&&/^[0-9a-f]{64}$/.test(x);
  if(!hash(before.questionHash)||!hash(after.questionHash)||typeof before.versionBinding!=='string'||typeof after.versionBinding!=='string')return result('REVIEW','CONTEXT_MISSING');
  if(!before.versionBinding || before.versionBinding!==after.versionBinding || before.questionHash!==after.questionHash)return result('FAIL','CONTEXT_CHANGED');
  if(!Array.isArray(before.recordHashes)||!Array.isArray(after.recordHashes))return result('REVIEW','BASELINE_MISSING');
  if(!before.recordHashes.every(hash)||!after.recordHashes.every(hash))return result('REVIEW','RECORD_HASH_INVALID');
  if(before.customerSelected!==false||after.customerSelected!==false)return result('REVIEW','CUSTOMER_NOT_CONFIRMED_UNSELECTED');
  if(before.isAnswering!==false||before.contentLoading!==false||before.stopped!==false)return result('REVIEW','BASELINE_NOT_IDLE');
  const a=after.last;
  if(!a)return result('REVIEW','ANSWER_NOT_OBSERVED');
  if(typeof a.recordHash!=='string'||!a.recordHash)return result('REVIEW','RECORD_HASH_MISSING');
  if(before.recordHashes.includes(a.recordHash)||!after.recordHashes.includes(a.recordHash))return result('FAIL','RECORD_NOT_NEW');
  if(a.questionHash!==after.questionHash||a.groupQuestionHash!==after.questionHash)return result('FAIL','QUESTION_MISMATCH');
  if(!after.conversationHash||a.conversationHash!==after.conversationHash ||
    (before.conversationHash!==null&&before.conversationHash!==after.conversationHash))return result('FAIL','CONVERSATION_MISMATCH');
  for(const flag of [after.isAnswering,after.contentLoading,after.stopped,a.error,a.paused]) {
    if(typeof flag!=='boolean')return result('REVIEW','FLAG_UNKNOWN');
    if(flag!==false)return result('REVIEW','ANSWER_NOT_COMPLETE');
  }
  if(a.endAnswerFlag!==true||a.parserStatus!=='02')return result('REVIEW','ANSWER_NOT_COMPLETE');
  return result('ACCEPT','STRUCTURED_ANSWER_ONLY_REWARD_UNVERIFIED');
}
module.exports={reconcile};
