/* Build an expression for the existing exact-target CDP evaluate adapter.
 * Does not connect or execute. Context contains private question/salt; output
 * must remain private. No raw page value is returned by the expression.
 */
const crypto=require('node:crypto');
const {collectAiSnapshot}=require('./ai-snapshot.js');
function buildExpression(context) {
  if(!context || typeof context.origin!=='string'||typeof context.path!=='string'||
     !Array.isArray(context.resourceNames)||!context.resourceNames.length||
     context.resourceNames.some(n=>typeof n!=='string'||!/^[\w.-]+\.js$/.test(n)))throw Error('INVALID_TARGET_PROFILE');
  const url=new URL(context.origin);
  if(url.origin!==context.origin||url.protocol!=='https:'||!/^\/[\w/-]+$/.test(context.path))throw Error('INVALID_TARGET_PROFILE');
  const collector=collectAiSnapshot.toString();
  const binding=crypto.createHash('sha256').update(JSON.stringify({collector,profile:context.versionBinding,origin:context.origin,path:context.path,resources:context.resourceNames})).digest('hex');
  const config={salt:context.salt,expectedQuestion:context.expectedQuestion,versionBinding:binding};
  return `(async()=>{
    if(location.origin!==${JSON.stringify(context.origin)}||location.pathname!==${JSON.stringify(context.path)})return {status:'REVIEW',reason:'WRONG_TARGET'};
    const expected=${JSON.stringify(context.resourceNames)};
    const loaded=performance.getEntriesByType('resource').map(x=>new URL(x.name,location.href).pathname.split('/').pop());
    if(!expected.every(x=>loaded.includes(x)))return {status:'REVIEW',reason:'RESOURCE_PROFILE_NOT_OBSERVED'};
    const digest=async value=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value)))).map(x=>x.toString(16).padStart(2,'0')).join('');
    return (${collector})(document.querySelector('#app'),${JSON.stringify(config)},digest);
  })()`;
}
module.exports={buildExpression};
