const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const {collectAiSnapshot}=require('./ai-snapshot.js');
const {reconcile}=require('./reconcile.cjs');
const digest=async s=>crypto.createHash('sha256').update(s).digest('hex');
const secret='PRIVATE_QUESTION_123', id='PRIVATE_RECORD_789', conv='PRIVATE_CONVERSATION_456';
const options={salt:'x'.repeat(32),expectedQuestion:secret,versionBinding:'synthetic-version'};
const ref=value=>({__v_isRef:true,value});
function fixture(){
 const conversation={conversationId:ref(''),isAnswering:ref(false),contentLoading:ref(false),isStopAnswer:ref(false)};
 const customer={globalCustomerId:ref(''),globalZmCustomerId:ref('')};
 const provides={[Symbol()]:conversation,[Symbol()]:customer};
 const records=[];
 const home={type:{name:'Home'},setupState:{},props:{records},provides,subTree:{children:[]}};
 const root={_vnode:{component:home}};
 function finish(){
  conversation.conversationId.value=conv;
  const answer={recordId:id,question:secret,conversationId:conv,streamData:[{endAnswerFlag:true,error:false}]};
  records.push({question:secret,answerList:[answer]});
  const renderer={type:{name:'ChatAnswerThink'},setupState:{parserStatus:ref('02'),isAnswerPaused:ref(false)},
    props:{answerList:[answer],isLastAnswer:true},provides:Object.create(provides)};
  home.subTree.children.push({component:renderer});
  return {answer,renderer};
 }
 return {root,home,conversation,customer,records,finish};
}
let count=0;
async function check(name,fn){await fn();count++;console.log('PASS '+name);}
(async()=>{
 await check('first empty baseline, real tree collection and structured completion',async()=>{
  const f=fixture(), before=await collectAiSnapshot(f.root,options,digest);assert.equal(before.status,'SNAPSHOT');assert.deepEqual(before.recordHashes,[]);
  f.finish();const after=await collectAiSnapshot(f.root,options,digest);assert.equal(reconcile(before,after).verdict,'ACCEPT');
  const output=JSON.stringify({before,after});for(const s of [secret,id,conv])assert(!output.includes(s));
 });
 for(const [name,mutate,expected] of [
  ['stream error',f=>f.answer.streamData[0].error=true,'REVIEW'],
  ['missing error',f=>delete f.answer.streamData[0].error,'REVIEW'],
  ['integer end flag',f=>f.answer.streamData[0].endAnswerFlag=1,'REVIEW'],
  ['not ended',f=>f.answer.streamData[0].endAnswerFlag=false,'REVIEW'],
  ['parser English DONE',f=>f.renderer.setupState.parserStatus.value='DONE','REVIEW'],
  ['paused',f=>f.renderer.setupState.isAnswerPaused.value=true,'REVIEW'],
  ['answer question mismatch',f=>f.answer.question='other','FAIL'],
  ['group question mismatch',f=>f.records[0].question='other','FAIL'],
  ['answer conversation mismatch',f=>f.answer.conversationId='other','FAIL'],
  ['customer selected',f=>f.customer.globalCustomerId.value='customer-secret','REVIEW'],
  ['still answering',f=>f.conversation.isAnswering.value=true,'REVIEW'],
  ['stopped',f=>f.conversation.isStopAnswer.value=true,'REVIEW'],
  ['renderer not last',f=>f.renderer.props.isLastAnswer=false,'REVIEW'],
  ['missing record id',f=>delete f.answer.recordId,'REVIEW'],
  ['missing parser',f=>delete f.renderer.setupState.parserStatus,'REVIEW'],
  ['missing customer state',f=>delete f.customer.globalZmCustomerId,'REVIEW'],
 ])await check(name,async()=>{
  const f=fixture(),before=await collectAiSnapshot(f.root,options,digest);Object.assign(f,f.finish());mutate(f);
  const after=await collectAiSnapshot(f.root,options,digest);assert.equal(reconcile(before,after).verdict,expected);
 });
 await check('existing record replay rejected',async()=>{const f=fixture();f.finish();const a=await collectAiSnapshot(f.root,options,digest);assert.equal(reconcile(a,a).verdict,'FAIL');});
 await check('changed binding rejected',async()=>{const f=fixture(),b=await collectAiSnapshot(f.root,options,digest);f.finish();const a=await collectAiSnapshot(f.root,{...options,versionBinding:'changed'},digest);assert.equal(reconcile(b,a).verdict,'FAIL');});
 await check('new salt invalidates context',async()=>{const f=fixture(),b=await collectAiSnapshot(f.root,options,digest);f.finish();const a=await collectAiSnapshot(f.root,{...options,salt:'y'.repeat(32)},digest);assert.equal(reconcile(b,a).verdict,'FAIL');});
 await check('no root',async()=>assert.equal((await collectAiSnapshot({},options,digest)).status,'REVIEW'));
 await check('missing context',async()=>assert.equal((await collectAiSnapshot(fixture().root,{},digest)).reason,'INVALID_CONTEXT'));
 await check('missing records must not become empty baseline',async()=>{const f=fixture();delete f.home.props.records;assert.equal((await collectAiSnapshot(f.root,options,digest)).reason,'RECORDS_NOT_UNIQUE');});
 await check('duplicate state provider rejected',async()=>{const f=fixture();f.home.provides[Symbol()]={...f.conversation};assert.equal((await collectAiSnapshot(f.root,options,digest)).reason,'PROVIDERS_NOT_UNIQUE');});
 await check('read exception explicit and secret suppressed',async()=>{const f=fixture();Object.defineProperty(f.home.props,'records',{get(){throw Error(secret);}});const a=await collectAiSnapshot(f.root,options,digest);assert.equal(a.reason,'SNAPSHOT_READ_ERROR');assert(!JSON.stringify(a).includes(secret));});
 await check('cycle dedup and width budget',async()=>{const f=fixture();f.home.subTree.children.push(f.root._vnode);assert.equal((await collectAiSnapshot(f.root,options,digest)).status,'SNAPSHOT');f.home.subTree.children=Array.from({length:5001},()=>({}));assert.equal((await collectAiSnapshot(f.root,options,digest)).reason,'TREE_TRUNCATED');});
 console.log('TOTAL '+count+' PASS; synthetic tree tests, no device or business');
})().catch(e=>{console.error(e);process.exitCode=1;});
