const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(__dirname + '/provides_component_traversal.js', 'utf8');
const run = vm.runInNewContext(source, {}, {timeout: 1000});
const secret = 'PRIVATE_SECRET_VALUE';
const convSym = Symbol('conversationState');
// Parent provides: inherited Symbol, secret string value must never appear.
const parentProvides = {};
parentProvides[convSym] = {isAnswering: {__v_isRef: true, _value: false}, conversationId: {__v_isRef: true, _value: secret}, setIsAnswering: () => { throw new Error('set-called'); }};
// Child provides inherits parent via prototype, shadows nothing, owns its own symbol.
const childSym = Symbol('childOwn');
const childProvides = Object.create(parentProvides);
childProvides[childSym] = {ownField: 'x'};
const child = {type: {name: 'ChatAnswer'}, setupState: {isAnswering: {__v_isRef: true, _value: true}, recordId: {__v_isRef: true, _value: secret}, answer: secret}, props: {}, provides: childProvides, subTree: null};
Object.defineProperty(child.setupState, 'badGetter', {enumerable: true, get() { throw new Error(secret); }});
const root = {type: {name: 'App'}, setupState: {}, props: {}, provides: {}, subTree: {children: [{component: child}]}};
root.subTree.dynamicChildren = [root.subTree]; // cycle / duplicate
const container = {_vnode: {component: root}};
const result = run(container);
const out = JSON.stringify(result);
assert(!out.includes(secret), 'secret leaked');
assert(!out.includes('set-called'), 'set function was called or leaked');
assert.equal(result.status, 'ROOTS_FOUND');
const chat = result.nodes.find(n => n.name === 'ChatAnswer');
assert(chat, 'ChatAnswer node missing');
// Inherited Symbol: child provides chain must include parent level>=1 with convSym description
const chain = chat.providesChain;
assert(chain.length >= 2, 'provides chain must include inherited level');
const inherited = chain.find(l => l.level >= 1 && l.symbols.some(s => s.description === 'conversationState'));
assert(inherited, 'inherited conversationState symbol not found');
const convFields = inherited.symbols.find(s => s.description === 'conversationState').fields;
const ans = convFields.find(f => f.key === 'isAnswering');
assert(ans && ans.type === 'ref-boolean' && ans.boolean === false, 'whitelist ref boolean must be returned');
const cid = convFields.find(f => f.key === 'conversationId');
assert(cid && cid.type === 'ref' && !('boolean' in cid), 'non-whitelist ref must not return value');
const setF = convFields.find(f => f.key === 'setIsAnswering');
assert(setF && setF.type === 'function' && !('boolean' in setF), 'set function must be type only, never called');
// SetupState ref rules
const setupAns = chat.setupState.find(f => f.key === 'isAnswering');
assert(setupAns && setupAns.type === 'ref-boolean' && setupAns.boolean === true, 'setupState whitelist ref boolean');
const setupRec = chat.setupState.find(f => f.key === 'recordId');
assert(setupRec && setupRec.type === 'ref' && !('boolean' in setupRec), 'non-whitelist ref must not return value');
assert(chat.setupState.find(f => f.key === 'badGetter').type === 'accessor', 'getter must not be invoked');
// Own symbol at level 0
const own = chain.find(l => l.level === 0 && l.symbols.some(s => s.description === 'childOwn'));
assert(own, 'own symbol at level 0 missing');
// Absent root
assert.equal(run({}).status, 'ROOT_NOT_EXPOSED');
console.log('PASS: component provides chain, inherited Symbol, cycles, ref whitelist-boolean only, no secret/set leakage, absent root');

// Traversal pointers must not invoke user-defined getters.
let traversalGetterCalls = 0;
const accessorComponent = {setupState:{}, props:{}, exposed:{}, provides:{}};
Object.defineProperty(accessorComponent, 'subTree', {get(){traversalGetterCalls++; throw Error(secret);}});
const accessorResult = run({_vnode:{component:accessorComponent}});
assert.equal(traversalGetterCalls, 0);
assert.equal(accessorResult.status, 'READ_ERROR');
assert(accessorResult.errors.some(e => e.errorType === 'ACCESSOR_BLOCKED'));
assert(!JSON.stringify(accessorResult).includes(secret));
console.log('PASS: traversal accessors are blocked without invocation and reported as unknown');

let thrownNameGetterCalls = 0;
const thrownByProxy = {};
Object.defineProperty(thrownByProxy, 'name', {get(){thrownNameGetterCalls++; throw Error(secret);}});
const proxyVnode = new Proxy({}, {getOwnPropertyDescriptor(){throw thrownByProxy;}});
const proxyResult = run({_vnode:proxyVnode});
assert.equal(thrownNameGetterCalls, 0);
assert.equal(proxyResult.status, 'READ_ERROR');
assert(proxyResult.errors.some(e => e.errorType === 'READ_FAILED'));
assert(!JSON.stringify(proxyResult).includes(secret));
console.log('PASS: reflection errors are sanitized without inspecting thrown error properties');

let deepType = {name:'Deep'};
for(let i=0;i<300;i++) deepType = Object.create(deepType);
const deepResult = run({_vnode:{component:{type:deepType,setupState:{},props:{},provides:{}}}});
assert.equal(deepResult.status, 'TRUNCATED');
assert(deepResult.truncationReasons.includes('PROPERTY_PROTOTYPE_DEPTH'));
console.log('PASS: property-prototype lookup is explicitly bounded');

// Real accessor traps, shared ancestor coverage, and explicit symbol bounds.
let invoked = 0;
const tricky = {};
Object.defineProperty(tricky, '__v_isRef', {get(){invoked++;throw Error(secret);}});
Object.defineProperty(parentProvides[convSym].isAnswering, '_value', {get(){invoked++;throw Error(secret);}});
parentProvides[convSym].error = tricky;
Object.defineProperty(childProvides, Symbol('accessorSymbol'), {get(){invoked++;throw Error(secret);}});
const safeResult = run(container);
assert.equal(invoked,0);
assert.equal(safeResult.status,'ROOTS_FOUND');
assert(!JSON.stringify(safeResult).includes(secret));
const sibling = {type:{name:'Sibling'}, provides:childProvides};
root.subTree.children.push({component:sibling});
const shared = run(container).nodes.find(n=>n.name==='Sibling');
assert(shared.providesChain.some(l=>l.symbols.some(s=>s.description==='conversationState')));
for(let i=0;i<161;i++) childProvides[Symbol('field'+i)]={};
const bounded=run(container);
assert.equal(bounded.status,'TRUNCATED');
assert(bounded.truncationReasons.includes('PROVIDES_SYMBOLS'));
console.log('PASS: no ref/Symbol getters, shared inherited provides retained, explicit Symbol bounds');
