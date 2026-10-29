const assert=require('node:assert/strict');
const vm=require('node:vm');
const {webcrypto}=require('node:crypto');
const {buildExpression}=require('./build-expression.cjs');
const profile={origin:'https://example.invalid',path:'/app/home',resourceNames:['home-example.js'],versionBinding:'synthetic-source-profile',salt:'x'.repeat(32),expectedQuestion:'PRIVATE_EXPECTED_QUESTION'};
const expr=buildExpression(profile);
(async()=>{
 const run=(origin,names)=>vm.runInNewContext(expr,{location:{origin,pathname:'/app/home',href:'https://example.invalid/app/home'},performance:{getEntriesByType:()=>names.map(name=>({name}))},URL,TextEncoder,crypto:webcrypto,document:{querySelector:()=>null}},{timeout:1000});
 assert.equal((await run('https://wrong.invalid',[])).reason,'WRONG_TARGET');
 assert.equal((await run(profile.origin,[])).reason,'RESOURCE_PROFILE_NOT_OBSERVED');
 assert.equal((await run(profile.origin,['https://example.invalid/assets/home-example.js?private=query'])).reason,'ROOT_NOT_EXPOSED');
 assert.throws(()=>buildExpression({...profile,resourceNames:['../private.js']}));
 assert.throws(()=>buildExpression({...profile,origin:'http://example.invalid'}));
 console.log('PASS: exact target, required loaded resources, no root, invalid profiles; no connection');
})().catch(e=>{console.error(e);process.exitCode=1;});
