const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { escapeHTML, validateModel, comparisonRows, formatBytes } = require('../Sources/MidnightInspector/Resources/app.js');

function fixture() {
  return { id: 'test-model', modelType: 'mistral3', layerCount: 1, hiddenSize: 32,
    weightBytes: 1024 * 1024, attentionHeads: 4, kvHeads: 2,
    layers: [{ index: 0, path: 'model.layers.0', kind: 'sliding_attention', modules: [
      { path: 'model.layers.0.self_attn.q_proj', kind: 'QuantizedLinear', parameters: [
        { name: 'weight', shape: [32, 4], dtype: 'uint32' }
      ] }
    ] }] };
}

test('saved quantized structures retain their actual packed tensor shapes', () => {
  const model = fixture();
  assert.equal(validateModel(model), model);
  assert.deepEqual(model.layers[0].modules[0].parameters[0].shape, [32, 4]);
  assert.equal(formatBytes(model.weightBytes), '1.0 MiB');
});

test('rejects malformed snapshots before they replace a working comparison', () => {
  assert.throws(() => validateModel({}), /snapshot/);
  const model = fixture();
  model.layers[0].modules[0].parameters[0].shape = [-1];
  assert.throws(() => validateModel(model), /tensor shape/);
  const inconsistent = fixture(); inconsistent.layerCount = 3;
  assert.throws(() => validateModel(inconsistent), /snapshot/);
  const duplicate = fixture(); duplicate.layers.push(duplicate.layers[0]); duplicate.layerCount = 2;
  assert.throws(() => validateModel(duplicate), /invalid layer/);
});

test('model comparisons distinguish architecture facts and missing values', () => {
  const primary = fixture(), comparison = fixture();
  comparison.attentionHeads = 8;
  comparison.kvHeads = undefined;
  comparison.expertCount = 32;
  comparison.expertsPerToken = 4;
  const rows = comparisonRows(primary, comparison);
  assert.deepEqual(rows.find(row => row[0] === 'Attention heads'), ['Attention heads', 4, 8]);
  assert.deepEqual(rows.find(row => row[0] === 'Key/value heads'), ['Key/value heads', 2, undefined]);
  assert.deepEqual(rows.find(row => row[0] === 'Experts'), ['Experts', undefined, 32]);
  assert.ok(!rows.some(row => /parameters/i.test(row[0])), 'packed storage must not be labelled logical parameter count');
});

test('untrusted model names and module paths are escaped before markup insertion', () => {
  assert.equal(escapeHTML('<img src=x onerror="oops">&'), '&lt;img src=x onerror=&quot;oops&quot;&gt;&amp;');
  assert.equal(escapeHTML("a'b"), 'a&#39;b');
});

test('question action renders real trace values and model refresh clears stale activity', async () => {
  // A small DOM adapter tests the application state contract without a browser.
  const elements = new Map(), tools = new Map();
  function element(id) {
    if (!elements.has(id)) elements.set(id, { id, hidden:false, disabled:false, value:'',
      textContent:'', innerHTML:'', clientWidth:700, dataset:{}, handlers:{},
      firstElementChild:{textContent:''}, classList:{add(){},remove(){},toggle(){}},
      setAttribute(){}, addEventListener(name, callback){this.handlers[name]=callback;},
      querySelectorAll(){return [];}, querySelector(){return {disabled:false};} });
    return elements.get(id);
  }
  const model = inspectionFixture(); model.runtimeType='FixtureRuntime';
  const trace = {model:model.id, question:'What is 2 + 2?', answer:'4', outputKind:'raw', promptTokenCount:1, generatedTokenCount:1,
    stopReason:'stop', tokens:[{id:1,text:'Question',position:0,phase:'prompt'},{id:2,text:'4',position:1,phase:'answer'}],
    layers:['layer_input','after_attention'].map(site=>({index:0,path:'model.layers.0',site,samples:[0,1].map(tokenIndex=>({tokenIndex,rms:2.25,maxAbs:4,channels:Array(16).fill(2.25)}))}))};
  let offline = false, postBody;
  const context = vm.createContext({
    document:{getElementById:element,body:element('body'),modelContext:{registerTool(tool){tools.set(tool.name,tool);}}},
    window:{addEventListener(){}}, AbortSignal, AbortController, setTimeout, setInterval, clearInterval, structuredClone, Blob, URL,
    ResizeObserver:class{observe(){}}, matchMedia:()=>({matches:true}),
    getComputedStyle:()=>({paddingLeft:'12',paddingRight:'12'}),
    fetch:async(path,options)=>{
      if(offline)throw new Error('Server unavailable');
      let data = path==='/api/connections'?{connections:[{id:'primary'}]}:model;
      if(options.method==='POST'){postBody=JSON.parse(options.body);data=trace;}
      return {ok:true,json:async()=>data};
    }
  });
  vm.runInContext(fs.readFileSync(require.resolve('../Sources/MidnightInspector/Resources/app.js'),'utf8'),context);
  await new Promise(setImmediate);
  assert.equal(element('ask').disabled,false);
  assert.match(element('model-maps').innerHTML,/1 loaded layers/);
  assert.equal(tools.get('read_loaded_model_structure').execute().id,model.id);
  assert.throws(()=>tools.get('inspect_model_layer').execute({index:9}),/not present/);
  const comparison=fixture();comparison.id='saved-model';comparison.attentionHeads=8;
  await element('snapshot-file').handlers.change({target:{value:'snapshot.json',files:[{size:1024,text:async()=>JSON.stringify({format:'midnight-inspector-structure-v1',model:comparison})}]}});
  assert.equal(element('comparison-table').hidden,false);
  assert.match(element('comparison-table').innerHTML,/Attention heads/);
  assert.match(element('model-maps').innerHTML,/saved-model/);
  assert.match(element('model-maps').innerHTML,/Saved structure snapshot/);
  element('structure-mode').handlers.click();
  const result=await tools.get('ask_midnight_with_activations').execute({question:'What is 2 + 2?',maxTokens:32});
  assert.equal(postBody.question,'What is 2 + 2?');
  assert.deepEqual(postBody.layers,[0]);
  assert.deepEqual(postBody.tokenPositions,{prefill:[-1],decode:Array.from({length:32},(_,index)=>index)});
  assert.equal(postBody.capture,'summary');
  assert.equal(postBody.runtimeGeneration,7);
  assert.equal(result.answer,'4');
  assert.equal(element('answer').textContent,'4');
  assert.equal(element('token-controls').hidden,false);
  assert.match(element('layer-detail').innerHTML,/2\.250/);
  assert.equal(element('activity-mode').disabled,false);
  element('playback-site').value='layer_input';
  element('keep-a').handlers.click();
  element('keep-b').handlers.click();
  assert.match(element('capture-a-content').innerHTML,/Question/);
  assert.match(element('capture-flow').innerHTML,/2.250/);
  assert.match(element('playback-note').textContent,/Matching saved model descriptors/);
  offline=true;
  await element('refresh').handlers.click();
  assert.equal(element('comparison-table').hidden,true);
  assert.equal(element('activity-mode').disabled,true);
  assert.equal(element('ask').disabled,true);
  assert.equal(element('answer-panel').hidden,true);
  assert.match(element('model-maps').innerHTML,/Waiting for a loaded model/);
  element('playback-site').handlers.change();
  assert.match(element('capture-a-content').innerHTML,/Question/);
  assert.equal(element('play-captures').disabled,false);
});

test('architecture groups distinguish shared experts without guessing a graph or precision', () => {
  const {architectureGroups, precisionLabel, architectureMarkup} = require('../Sources/MidnightInspector/Resources/app.js');
  const model=fixture(), layer=model.layers[0];
  const base=layer.modules[0];
  layer.modules.push({...base,path:layer.path+'.mlp.shared_expert.gate_proj'}, {...base,path:layer.path+'.mlp.switch_mlp.down_proj'}, {...base,path:layer.path+'.mlp.gate.weight'});
  assert.deepEqual(architectureGroups(layer).map(g=>g.role),['Attention','Expert router','Routed experts','Shared expert']);
  assert.equal(precisionLabel(base),'Quantization unknown');
  base.quantization={format:'mxfp4',bits:4,groupSize:32};
  assert.equal(precisionLabel(base),'MXFP4 · 4-bit · group 32');
  const other=structuredClone(model);other.layers[0].modules[0].quantization={format:'nvfp4',bits:4,groupSize:16};
  const row=comparisonRows(model,other).find(r=>r[0]==='Weight formats (loaded modules)');
  assert.notEqual(row[1],row[2]);
  assert.match(architectureMarkup(model,layer),/not a traced execution graph/);
  base.quantization.bits=-4;assert.throws(()=>validateModel(model),/quantization/);
});


test('dataset imports stay bounded and reject duplicate IDs or unsupported expectations', () => {
  const {validateDataset}=require('../Sources/MidnightInspector/Resources/app.js');
  const data=[{id:'a',question:'Why is the sky blue?',expected:'answer'}];
  assert.deepEqual(validateDataset(data),data);
  assert.deepEqual(validateDataset({dataset:data}),data);
  assert.throws(()=>validateDataset([...data,...data]),/unique/);
  assert.throws(()=>validateDataset([{...data[0],expected:'bypass'}]),/expected/);
  assert.throws(()=>validateDataset(Array(101).fill(data[0])),/100/);
});


test('architecture facts distinguish convolution, GQA, and missing metadata', () => {
  const {blockType, coreFacts} = require('../Sources/MidnightInspector/Resources/app.js');
  const model = fixture();
  assert.equal(blockType(model.layers[0]), 'Attention');
  model.layers[0].kind = 'conv';
  model.layers[0].modules[0].path = 'model.layers.0.conv.conv';
  assert.equal(blockType(model.layers[0]), 'Convolution');
  assert.equal(coreFacts(model)[1][1], 'Grouped-query attention');
  assert.equal(coreFacts(model)[4][1], 'Unknown');
  model.configuredContextLength = 32768; model.contextLength = 4096;
  assert.equal(coreFacts(model)[4][1], '32,768 tokens');
  assert.equal(coreFacts(model)[5][1], '4,096 tokens');
  model.layers[0].kind = 'transformer'; model.layers[0].modules = [];
  assert.equal(blockType(model.layers[0]), 'Unknown');
});

function inspectionFixture() {
  const model=fixture(); model.traceSupported=true; model.runtimeGeneration=7;
  model.traceCapabilities={version:1,captureModes:['summary','raw'],maxSelectedLayers:128,maxDecodeTokens:64,maxCaptureBytes:16777216,
    observationPoints:[{site:'layer_input',hiddenSize:32},{site:'after_attention',hiddenSize:32}]};
  return model;
}

test('explicit inspection request uses one selected layer and bounded token positions',()=>{
  const {makeTraceRequest}=require('../Sources/MidnightInspector/Resources/app.js');
  const model=inspectionFixture();model.layers.push({...structuredClone(model.layers[0]),index:3,path:'model.layers.3'});model.layerCount=2;
  const request=makeTraceRequest(model,3,'  Marker  ',2);
  assert.deepEqual(request.layers,[3]);assert.deepEqual(request.tokenPositions,{prefill:[-1],decode:[0,1]});
  assert.deepEqual(request.sites,['layer_input','after_attention']);assert.equal(request.question,'Marker');
  assert.equal(request.capture,'summary');assert.equal(request.model,model.id);assert.equal(request.runtimeGeneration,7);
  assert.equal(request.maxCaptureBytes,16777216);
  model.layers=model.layers.slice(1);model.layerCount=1;
  assert.deepEqual(makeTraceRequest(model,99,'Marker',2).layers,[3]);
  assert.deepEqual(makeTraceRequest(model,undefined,'Marker',2).layers,[3]);
  model.traceCapabilities.observationPoints=[{site:'after_attention',hiddenSize:32}];model.traceCapabilities.maxCaptureBytes=1024;
  assert.deepEqual(makeTraceRequest(model,3,'Marker',2).sites,['after_attention']);
  assert.equal(makeTraceRequest(model,3,'Marker',2).maxCaptureBytes,1024);
});

test('inspection refuses missing capabilities, generation, sites and excessive limits',()=>{
  const {makeTraceRequest}=require('../Sources/MidnightInspector/Resources/app.js');
  for(const mutate of [m=>delete m.traceCapabilities,m=>delete m.runtimeGeneration,m=>m.runtimeGeneration=Number.MAX_SAFE_INTEGER+1,m=>m.traceCapabilities.observationPoints=[],m=>m.traceCapabilities.maxDecodeTokens=1,m=>{m.layers=[];m.layerCount=0;}]) {
    const model=inspectionFixture();mutate(model);assert.throws(()=>makeTraceRequest(model,0,'Marker',2));
  }
});

test('sparse summaries must match requested layers and sites exactly',()=>{
  const {makeTraceRequest,validateTraceSelection}=require('../Sources/MidnightInspector/Resources/app.js');
  const request=makeTraceRequest(inspectionFixture(),0,'Marker',2);
  const trace={model:request.model,tokens:[],layers:request.sites.map(site=>({index:0,site,samples:[]}))};
  assert.equal(validateTraceSelection(trace,request),trace);
  for(const layers of [[],[trace.layers[0],trace.layers[0]],[...trace.layers,{index:1,site:'layer_input'}]]) {
    assert.throws(()=>validateTraceSelection({...trace,layers},request));
  }
  assert.throws(()=>validateTraceSelection({...trace,model:'other'},request));
});
