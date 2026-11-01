import test from 'node:test';
import assert from 'node:assert/strict';
import { listIcloudGroups, BridgeFailure } from './bridge-client.mjs';
const env = { ICLOUD_BRIDGE_URL: 'https://bridge.example.org', ICLOUD_BRIDGE_TOKEN: 'test-only-secret' };
const reply = (body, status = 200) => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

async function errorCode(promise) {
  await assert.rejects(promise, (e) => e instanceof BridgeFailure && !!e.code);
  try { await promise; } catch (e) { return e.code; }
}

test('only POST fixed path with empty body; no arbitrary forwarding; retains secret in header only', async () => {
  let called = false;
  const events = [];
  const result = await listIcloudGroups({env, traceId:'test-trace', record:(e) => events.push(e), fetchImpl: async (url, init) => {
    called = true;
    assert.equal(url, 'https://bridge.example.org/v1/contacts/groups/list');
    assert.equal(init.method, 'POST');
    assert.equal(init.body, '{}');
    assert.equal(init.headers.Authorization, 'Bearer test-only-secret');
    assert.equal(init.headers['X-Request-ID'], 'test-trace');
    return reply({groups:[{name:'One',member_count:1,contact_ids:['must-never-leak']}],token:'never-return'});
  }});
  assert.equal(called, true);
  assert.deepEqual(result, {groups:[{name:'One',member_count:1}]});
  assert.ok(events.some((e) => e.phase === 'fetch_started'));
  assert.ok(events.some((e) => e.phase === 'success'));
  assert.equal(JSON.stringify(events).includes('test-only-secret'),false);
  assert.equal(JSON.stringify(result).includes('must-never-leak'),false);
});
test('missing secrets prevent all fetches', async () => {
  let called = false;
  assert.equal(await errorCode(listIcloudGroups({env:{},fetchImpl:()=>{called=true;}})), 'BRIDGE_UNCONFIGURED');
  assert.equal(called,false);
});
test('unsafe HTTP and URL path are rejected before fetch', async () => {
  for (const url of ['http://bridge.example.org','https://bridge.example.org/other','https://user:pass@bridge.example.org']) {
    assert.equal(await errorCode(listIcloudGroups({env:{...env,ICLOUD_BRIDGE_URL:url},fetchImpl:()=>{throw Error('SHOULD_NOT_FETCH');}})), 'BRIDGE_CONFIG_INVALID');
  }
});
test('401 is classified without exposing body', async () => {
  assert.equal(await errorCode(listIcloudGroups({env,fetchImpl:async()=>reply({authorization:'private'},401)})), 'BRIDGE_AUTH_FAILED');
});
test('network errors are differentiated from local prefetch failures', async () => {
  const events=[];
  assert.equal(await errorCode(listIcloudGroups({env,record:(e)=>events.push(e),fetchImpl:async()=>{throw Error('secret-or-url-in-message')}})), 'BRIDGE_NETWORK_ERROR');
  assert.ok(events.some((x)=>x.phase==='fetch_started'));
  assert.ok(events.some((x)=>x.phase==='fetch_error'));
  assert.ok(!JSON.stringify(events).includes('secret-or-url-in-message'));
});
test('bad JSON and schema are classified', async () => {
  assert.equal(await errorCode(listIcloudGroups({env,fetchImpl:async()=>reply('invalid json')})), 'BRIDGE_BAD_JSON');
  assert.equal(await errorCode(listIcloudGroups({env,fetchImpl:async()=>reply({groups:[{name:'X',member_count:'1'}]})})), 'BRIDGE_BAD_SCHEMA');
});
test('timeout is classified with abort', async () => {
  const promise = listIcloudGroups({env,timeoutMs:20,fetchImpl:async(_u,init)=>new Promise((resolve,reject)=>{
    init.signal.addEventListener('abort',()=>reject(Error('aborted')),{once:true});
  })});
  assert.equal(await errorCode(promise),'BRIDGE_TIMEOUT');
});

test('Funnel /bridge path prefix routes to the bridge listener, not root MCP', async () => {
  let target;
  const result=await listIcloudGroups({env:{...env,ICLOUD_BRIDGE_URL:'https://bridge.example.org/bridge'},fetchImpl:async(url)=>{
    target=url;
    return reply({groups:[{name:'Real group',member_count:1}]});
  }});
  assert.equal(target,'https://bridge.example.org/bridge/v1/contacts/groups/list');
  assert.equal(result.groups[0].member_count,1);
});
