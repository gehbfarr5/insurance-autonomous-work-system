const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync(__dirname + '/vue-root-metadata.js', 'utf8');
function probe(container) {
  return JSON.parse(JSON.stringify(vm.runInNewContext(source,
    {document: {querySelector(selector) { assert.equal(selector, '#app'); return container; }}}, {timeout: 1000})));
}
const secret = 'PRIVATE_CUSTOMER_OR_ANSWER_VALUE';
const child = {type: {name: 'ChatAnswer'}, setupState: {isAnswering: false, recordId: secret, answer: secret}, props: {}, subTree: null};
Object.defineProperty(child.setupState, 'unrelatedGetter', {enumerable: true, get() { throw new Error(secret); }});
const root = {type: {name: 'App'}, setupState: {}, props: {}, subTree: {children: [{component: child}]}};
const container = {__vue_app__: {_instance: null}, _vnode: {component: root}};
container.__vue_app__._container = container;
// Real production-style missing _instance, fragment child, duplicate root and cycles.
root.subTree.dynamicChildren = [root.subTree];
const result = probe(container);
assert.equal(result.status, 'ROOTS_FOUND');
assert.equal(result.nodeCount, 2);
assert.equal(result.nodes[1].name, 'ChatAnswer');
assert.equal(result.nodes[1].setupState.find(x => x.key === 'isAnswering').boolean, false);
assert.equal(result.nodes[1].setupState.find(x => x.key === 'unrelatedGetter').type, 'accessor');
assert(!JSON.stringify(result).includes(secret));
assert.equal(probe({}).status, 'ROOT_NOT_EXPOSED');
const bad = {get _vnode() { throw new Error(secret); }};
const errorResult = probe(bad);
assert.equal(errorResult.status, 'READ_ERROR');
assert(!JSON.stringify(errorResult).includes(secret));
let deep = {component: {type: {name: 'DeepAnswer'}, setupState: {endAnswerFlag: true}, props: {}}};
for (let i = 0; i < 90; i++) deep = {children: [deep]};
const deepResult = probe({_vnode: deep});
assert.equal(deepResult.status, 'ROOTS_FOUND');
assert.equal(deepResult.nodes[0].name, 'DeepAnswer');
const tooWide = probe({_vnode: {children: Array.from({length: 301}, () => ({}))}});
assert.equal(tooWide.status, 'TRUNCATED');
assert(tooWide.truncationReasons.includes('VNODE_CHILDREN'));
console.log('PASS: production root, breadth traversal, deep fragments, dedup/cycles, privacy, absent root, explicit errors and truncation reasons');
