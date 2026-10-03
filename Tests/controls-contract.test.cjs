const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const {validateProfile,sameProfile,escapeHTML,contextPresets}=require('../Sources/MidnightInspector/Resources/controls.js');

test('context presets follow the selected model limit including exact non-power-of-two maxima',()=>{
  assert.equal(contextPresets(262144).at(-1).label,'256K');
  assert.equal(contextPresets(1048576).at(-1).value,1048576);
  assert.equal(contextPresets(128000).at(-1).value,128000);
  assert.ok(contextPresets(128000).every(p=>p.value<=128000));
  assert.deepEqual(contextPresets(2048),[{value:2048,label:'2K'}]);
  assert.equal(contextPresets(null).at(-1).value,32768);
  assert.equal(contextPresets(33554432).at(-1).value,16777216);
});

function fixture(){
  const defaults={modelID:'local-model',servedModelName:'test-model',contextLength:4096,maximumTokens:512,prefillStepSize:128,kvCompression:'none',engine:'metal'};
  return {id:'local-model',name:'Local test model',path:'/models/test',architecture:'gpt_oss',layerCount:24,architectureContextLength:8192,weightBytes:1024**3,supported:true,supportsKVCompression:false,defaults};
}
test('configuration validation preserves runtime limits and leaves room for prompts',()=>{
  const model=fixture(),p=model.defaults;
  assert.equal(validateProfile(p,model),p);
  for(const patch of [{contextLength:8193},{contextLength:0},{contextLength:4096.5},{maximumTokens:4096},{maximumTokens:0},{prefillStepSize:8193},{engine:'cuda'},{kvCompression:'affine4'},{servedModelName:' leading'},{servedModelName:'\n'}]){
    assert.throws(()=>validateProfile({...p,...patch},model));
  }
  assert.equal(validateProfile({...p,servedModelName:'-valid-name'},model).servedModelName,'-valid-name');
  assert.throws(()=>validateProfile(p,{...model,supported:false,warning:'Audio model'}),/Audio model/);
  assert.throws(()=>validateProfile({...p,modelID:'missing'},model),/Select a model/);
});
test('profile comparison distinguishes active settings, saved defaults, and another model',()=>{
  const p=fixture().defaults;
  assert.equal(sameProfile(p,{...p}),true);
  assert.equal(sameProfile(p,{...p,contextLength:8192}),false);
  assert.equal(sameProfile(p,{...p,modelID:'other'}),false);
  assert.equal(sameProfile(p,null),false);
  assert.equal(escapeHTML('<name>&"'), '&lt;name&gt;&amp;&quot;');
});
test('UI stages, saves, loads, polls without overwriting drafts, and unloads through real actions',async()=>{
  const model=fixture(),elements=new Map(),registered=new Map(),calls=[];
  const timers=new Map();let timerID=0;
  function element(id){
    if(!elements.has(id))elements.set(id,{id,hidden:false,disabled:false,value:'',innerHTML:'',textContent:'',handlers:{},dataset:{},firstElementChild:{textContent:''},classList:{toggle(){},add(){},remove(){}},setAttribute(){},querySelectorAll(){return[];},addEventListener(name,fn){this.handlers[name]=fn;}});
    return elements.get(id);
  }
  let runtime={mode:'external',phase:'idle',message:'External',endpoint:'http://localhost:8080',savedProfiles:[],logs:[]};
  let externalOnline=true, holdNextState=false, releaseState;
  const context=vm.createContext({TextEncoder,AbortSignal,AbortController,
    document:{hidden:false,getElementById:element,addEventListener(){},modelContext:{registerTool(tool){registered.set(tool.name,tool);}}},
    window:{addEventListener(){}},setTimeout(fn){timers.set(++timerID,fn);return timerID;},clearTimeout(id){timers.delete(id);},
    fetch:async(path,options)=>{
      const payload=options.body?JSON.parse(options.body):null;calls.push({path,payload});
      let result;
      if(path==='/api/control/models')result={models:[model]};
      else if(path==='/api/model?connection=primary'){
        if(!externalOnline)throw new Error('External model stopped');
        result={id:'existing',layerCount:24,contextLength:2048};
      }
      else if(path==='/api/control/profile'){runtime={...runtime,savedProfiles:[payload]};result=runtime;}
      else if(path==='/api/control/load'){runtime={...runtime,mode:'managed',phase:'loading',activeProfile:payload,endpoint:'http://localhost:8082'};result=runtime;}
      else if(path==='/api/control/unload'){runtime={...runtime,phase:'idle',activeProfile:null,processID:123};result=runtime;}
      else if(path==='/api/control/external'){runtime={...runtime,mode:'external',phase:'idle',activeProfile:null,processID:null};result=runtime;}
      else if(path==='/api/control/state'&&holdNextState){holdNextState=false;result=structuredClone(runtime);await new Promise(resolve=>{releaseState=resolve;});}
      else result=runtime;
      return{ok:true,json:async()=>result};
    }
  });
  vm.runInContext(fs.readFileSync(require.resolve('../Sources/MidnightInspector/Resources/controls.js'),'utf8'),context);
  await new Promise(setImmediate);
  assert.equal(element('load-model').disabled,false);
  assert.equal(element('selection-title').textContent,model.name,'configuration target is named at the top');
  const stage=registered.get('configure_midnight_model');
  assert.throws(()=>stage.execute({modelID:model.id,contextLength:9999}));
  assert.equal(element('context-length').value,4096,'failed staging leaves prior form intact');
  stage.execute({modelID:model.id,contextLength:8192});
  assert.equal(element('context-length').value,8192);
  await registered.get('save_midnight_defaults').execute();
  assert.equal(runtime.savedProfiles[0].contextLength,8192);
  await registered.get('load_configured_midnight_model').execute();
  assert.equal(runtime.activeProfile.contextLength,8192);
  assert.equal(element('load-model').disabled,true);
  assert.equal(element('unload').disabled,true,'unload waits until the runner finishes transitioning');
  runtime={...runtime,phase:'loaded',processID:123,message:'Ready'};
  await registered.get('read_midnight_runtime').execute();
  assert.equal(element('load-model').disabled,false);
  assert.equal(element('unload').hidden,false);
  element('context-length').value='4096';element('configuration-form').handlers.input();
  await registered.get('read_midnight_runtime').execute();
  assert.equal(element('context-length').value,'4096','polling must preserve unsaved form values');
  assert.equal(runtime.activeProfile.contextLength,8192,'draft changes cannot silently alter loaded settings');
  element('unload').handlers.click();await new Promise(setImmediate);
  assert.equal(runtime.phase,'idle');assert.equal(element('unload').hidden,true);
  element('use-external').handlers.click();await new Promise(setImmediate);
  assert.equal(runtime.mode,'external');
  assert.equal(element('session-name').textContent,'existing');
  assert.deepEqual(calls.filter(c=>c.path==='/api/control/load').map(c=>c.payload.contextLength),[8192]);
  externalOnline=false;
  await [...timers.values()].at(-1)();
  assert.equal(element('session-status').textContent,'Existing connection offline');
  assert.equal(element('inspect-active').hidden,true);
  holdNextState=true;
  const pendingPoll=[...timers.values()].at(-1)();
  await new Promise(setImmediate);
  await registered.get('load_configured_midnight_model').execute();
  assert.equal(element('session-status').textContent,'Loading model');
  releaseState();await pendingPoll;
  assert.equal(element('session-status').textContent,'Loading model','a response from before a mutation must not replace its state');
});
