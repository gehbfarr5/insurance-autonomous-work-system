const assert=require('node:assert/strict');const {createTrigger}=require('./trigger.js');
let t=createTrigger();assert.equal(t.observe(false,0),false);assert.equal(t.observe(true,1),true);
for(let i=2;i<100;i++)assert.equal(t.observe(true,i),false);
assert.equal(t.observe(false,100),false);assert.equal(t.observe(true,200),false);
t.observe(false,300);t.observe(false,1800);assert.equal(t.observe(true,1801),true);
assert.equal(t.observe(true,1802),false);
console.log('PASS: one trigger per login page, transient overlay cannot rearm, stable exit permits new login');
