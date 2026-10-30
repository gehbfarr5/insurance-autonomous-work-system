const assert=require('node:assert/strict');const {runAttempt}=require('./attempt.js');
const req={id:'abcd1234abcd1234',issuedAt:1000,expiresAt:31000};
const config={width:100,height:200,points:[[10,20],[20,40],[40,80],[80,160]]};
function setup(mode='success'){
 let time=1000,input=0,guard=null,reports=[];
 const env={wallNow:()=>1000,now:()=>time,sleep:n=>{time+=n},guardExists:()=>guard!==null,
 report:(state,reason)=>reports.push({state,reason}),writeGuard:id=>{guard=id},
 clearOwnGuard:id=>{if(mode==='wrong_owner'||guard!==id)return false;guard=null;return true;},
 input:()=>{input++;if(mode==='throw')throw Error('PRIVATE_CREDENTIAL_MUST_NOT_LEAK');},
 observe:()=>({target:mode!=='wrong_app',gesturePage:input===0||mode==='unchanged',accountMatch:mode!=='wrong_account',screenOn:mode!=='screen_off',width:mode==='geometry'?101:100,height:200,knownPostLoginActivity:mode!=='unknown_activity'})};
 return {env,get input(){return input},get guard(){return guard},reports,setGuard:v=>{guard=v}};
}
let count=0;const check=(name,fn)=>{fn();count++;console.log('PASS '+name)};
check('one input, stable page-left, own marker cleared',()=>{const x=setup();assert.equal(runAttempt(x.env,config,req).state,'page_left');assert.equal(x.input,1);assert.equal(x.guard,null);assert.equal(x.reports[0].state,'attempting')});
for(const mode of ['wrong_app','wrong_account','screen_off','geometry'])check(mode,()=>{const x=setup(mode);assert.equal(runAttempt(x.env,config,req).state,'blocked');assert.equal(x.input,0)});
for(const mode of ['unchanged','unknown_activity','wrong_owner','throw'])check(mode,()=>{const x=setup(mode);const r=runAttempt(x.env,config,req);assert.notEqual(r.state,'page_left');assert.equal(x.input,1);assert.equal(x.guard,req.id);assert(!JSON.stringify(r).includes('PRIVATE_CREDENTIAL'));assert.equal(runAttempt(x.env,config,req).reason,'PRIOR_ATTEMPT_UNRECONCILED');assert.equal(x.input,1)});
check('old protection not automatically cleared',()=>{const x=setup();x.setGuard('old');assert.equal(runAttempt(x.env,config,req).reason,'PRIOR_ATTEMPT_UNRECONCILED');assert.equal(x.input,0)});
for(const request of [{...req,expiresAt:999},{...req,issuedAt:7000},{...req,expiresAt:100000},{...req,id:'bad'},null])check('invalid/expired request',()=>{const x=setup();assert.equal(runAttempt(x.env,config,request).reason,'REQUEST_INVALID_OR_EXPIRED');assert.equal(x.input,0)});
for(const points of [[],[[NaN,1],[2,3]],[[100,10],[1,2]],[[1,'2'],[2,3]],[[1,2]]])check('invalid private configuration',()=>{const x=setup();assert.equal(runAttempt(x.env,{...config,points},req).reason,'CONFIG_INVALID');assert.equal(x.input,0)});
check('page changes after durable marker',()=>{const x=setup();let seen=0;const observe=x.env.observe;x.env.observe=()=>{const s=observe();if(++seen>1)s.target=false;return s};assert.equal(runAttempt(x.env,config,req).reason,'CONTEXT_CHANGED_BEFORE_INPUT');assert.equal(x.input,0);assert.equal(x.guard,req.id)});
console.log('TOTAL '+count+' PASS; synthetic inputs only');
