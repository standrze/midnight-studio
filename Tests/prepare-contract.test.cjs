const test = require('node:test');
const assert = require('node:assert/strict');
const {escape,busy,datasetFile,label} = require('../Sources/MidnightInspector/Resources/prepare.js');

test('job logs and remote repository labels escape markup before rendering', () => {
  assert.equal(escape('<img src=x onerror="alert(1)">'), '&lt;img src=x onerror=&quot;alert(1)&quot;&gt;');
  assert.equal(escape(null), '');
  assert.equal(label('cpt'), 'LoRA continued pretraining');
});
test('cancelling continues to block a second preparation job', () => {
  assert.equal(busy({jobs:[{phase:'cancelling'}]}), true);
  assert.equal(busy({jobs:[{phase:'running'}]}), true);
  assert.equal(busy({jobs:[{phase:'failed'},{phase:'completed'}]}), false);
});
test('oversized dataset files are rejected before reading into browser memory', async () => {
  let reads = 0;
  await assert.rejects(datasetFile({size:2*1024*1024+1,text:()=>{reads++;}}), /2 MiB/);
  assert.equal(reads,0);
  assert.equal(await datasetFile({size:12,text:async()=>'{"text":"x"}'}), '{"text":"x"}');
});
