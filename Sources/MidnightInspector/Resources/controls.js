(() => {
  'use strict';
  const fields = {servedModelName:'served-name',contextLength:'context-length',maximumTokens:'maximum-tokens',prefillStepSize:'prefill-step-size',kvCompression:'kv-compression',engine:'engine'};
  const numericFields = new Set(['contextLength','maximumTokens','prefillStepSize']);
  const escapeHTML = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const number = value => value == null ? '—' : Number(value).toLocaleString();
  const bytes = value => value == null ? '' : `${(value / 1024 ** 3).toFixed(1)} GiB`;
  const sameProfile = (a,b) => !!a && !!b && a.modelID === b.modelID && Object.keys(fields).every(key=>a[key]===b[key]);
  function validateProfile(profile, model) {
    if(!model || profile?.modelID!==model.id) throw new Error('Select a model from the library.');
    if(!model.supported) throw new Error(model.warning || 'This checkpoint cannot be loaded by Model Control.');
    const name=profile.servedModelName;
    if(typeof name!=='string' || !name || name!==name.trim() || new TextEncoder().encode(name).length>128 || /[\u0000-\u001f\u007f-\u009f]/.test(name)) throw new Error('Use a model name of 1–128 bytes without surrounding spaces or control characters.');
    if(!Number.isSafeInteger(profile.contextLength) || profile.contextLength<2 || profile.contextLength>16777216) throw new Error('Enter a context window from 2 to 16,777,216 tokens.');
    if(model.architectureContextLength && profile.contextLength>model.architectureContextLength) throw new Error(`This model supports a context window of at most ${number(model.architectureContextLength)} tokens.`);
    if(!Number.isSafeInteger(profile.maximumTokens) || profile.maximumTokens<1 || profile.maximumTokens>=profile.contextLength) throw new Error('Maximum output must be positive and smaller than the context window, leaving space for a prompt.');
    if(!Number.isSafeInteger(profile.prefillStepSize) || profile.prefillStepSize<1 || profile.prefillStepSize>8192) throw new Error('Prefill chunk size must be from 1 to 8,192 tokens.');
    if(!['auto','metal','cpu'].includes(profile.engine)) throw new Error('Choose an available execution engine.');
    if(!['none','affine8','affine4','turbo8v4'].includes(profile.kvCompression)) throw new Error('Choose a supported KV cache format.');
    if(profile.kvCompression!=='none' && !model.supportsKVCompression) throw new Error('KV cache compression is not supported for this model.');
    return profile;
  }
  function contextPresets(modelLimit) {
    const known=Number.isSafeInteger(modelLimit) && modelLimit>=2;
    const limit=known?Math.min(modelLimit,16777216):32768;
    const values=[];
    for(let value=4096;value<=limit;value*=2)values.push(value);
    if(known && !values.includes(limit))values.push(limit);
    return values.map(value=>({value,label:value%1024===0?`${value/1024}K`:`Max · ${number(value)}`}));
  }
  if(typeof module!=='undefined' && module.exports) module.exports={validateProfile,sameProfile,escapeHTML,bytes,contextPresets};
  if(typeof document==='undefined') return;
  const $=id=>document.getElementById(id);
  const state={models:[],runtime:null,externalModel:null,externalChecked:false,selectedID:null,draft:null,drafts:new Map(),sending:false,refreshing:false,online:false,pollTimer:null,lastPhase:null,epoch:0};
  const selected=()=>state.models.find(model=>model.id===state.selectedID);
  const savedProfile=id=>state.runtime?.savedProfiles?.find(profile=>profile.modelID===id);
  const transitioning=()=>['loading','stopping'].includes(state.runtime?.phase);
  function notice(message, success=false) { $('notice').textContent=message||''; $('notice').hidden=!message; $('notice').classList.toggle('success',success); }
  async function api(path, payload) {
    const options={signal:AbortSignal.timeout(20000)};
    if(payload!==undefined) {options.method='POST';options.headers={'Content-Type':'application/json'};options.body=JSON.stringify(payload);}
    const response=await fetch(path,options);
    const result=await response.json().catch(()=>({}));
    if(!response.ok)throw new Error(result.error?.message || `Midnight returned HTTP ${response.status}.`);
    return result;
  }
  function profileFor(model) {
    if(state.drafts.has(model.id))return {...state.drafts.get(model.id)};
    if(state.runtime?.activeProfile?.modelID===model.id && state.runtime.phase==='loaded')return {...state.runtime.activeProfile};
    return {...(savedProfile(model.id)||model.defaults)};
  }
  function selectModel(id) {
    const model=state.models.find(model=>model.id===id);
    if(!model)throw new Error('That model is no longer in the library. Refresh models.');
    if(state.draft)state.drafts.set(state.selectedID,{...state.draft});
    state.selectedID=id;state.draft=profileFor(model);renderLibrary();renderForm();
  }
  function renderLibrary() {
    $('model-count').textContent=String(state.models.length);
    if(!state.models.length){$('model-list').innerHTML='<p class="empty-note">No checkpoints found in the configured model folders. Add a local MLX checkpoint and refresh.</p>';return;}
    $('model-list').innerHTML=state.models.map(model=>{
      const active=state.runtime?.mode==='managed' && state.runtime.activeProfile?.modelID===model.id && state.runtime.phase==='loaded';
      const metadata=[model.architecture,bytes(model.weightBytes)].filter(Boolean);
      return `<button type="button" class="model-card ${state.selectedID===model.id?'selected':''}" data-model-id="${escapeHTML(model.id)}" aria-pressed="${state.selectedID===model.id}"><span class="model-card-name">${escapeHTML(model.name)}</span><span class="model-card-meta">${metadata.map(value=>`<span>${escapeHTML(value)}</span>`).join('')}${active?'<span class="running">● Loaded</span>':''}${!model.supported?'<span class="unavailable">Unavailable</span>':''}</span>${model.quantization?`<span class="model-card-kind">${escapeHTML(model.quantization)}</span>`:''}</button>`;
    }).join('');
  }
  function renderForm() {
    const model=selected();
    $('selection-title').textContent=model?.name || 'No model selected';
    $('selection-description').textContent=model ? `Settings below belong to this checkpoint. ${model.architecture}${model.quantization ? ' · '+model.quantization : ''}` : 'Choose a model from the library to view its settings.';
    $('selection-empty').hidden=!!model; $('configuration-content').hidden=!model;
    if(!model){updateActions();return;}
    $('selected-name').textContent=model.name;
    $('selected-meta').textContent=[model.architecture,model.layerCount?`${model.layerCount} layers`:null,model.quantization,model.weightBytes?`${bytes(model.weightBytes)} checkpoint`:null].filter(Boolean).join(' · ');
    $('selected-path').textContent=model.path;
    $('model-warning').textContent=model.warning||''; $('model-warning').hidden=!model.warning;
    for(const [key,id] of Object.entries(fields))$(id).value=state.draft[key];
    $('context-length').max=model.architectureContextLength||16777216;
    $('context-ceiling').textContent=model.architectureContextLength?`Model limit ${number(model.architectureContextLength)}`:'Runtime-validated limit';
    const presets=contextPresets(model.architectureContextLength);
    $('context-presets').innerHTML=presets.map(({value,label})=>`<button type="button" data-context="${value}" title="${number(value)} tokens" aria-pressed="false">${label}</button>`).join('');
    $('compression-help').textContent=model.supportsKVCompression?'Compressed caches trade precision for storage. These formats are experimental.':'This architecture currently supports uncompressed KV caching.';
    $('profile-fields').disabled=!model.supported;
    $('kv-compression').disabled=!model.supportsKVCompression;
    updateActions();
  }
  function updateActions() {
    const model=selected(), active=state.runtime?.phase==='loaded'?state.runtime.activeProfile:null;
    const saved=model?savedProfile(model.id):null;
    const edited=state.draft && !sameProfile(state.draft,saved||model?.defaults);
    $('draft-status').textContent=!model?'':sameProfile(state.draft,active)?'Active configuration':sameProfile(state.draft,saved)?'Saved defaults':edited?'Edited configuration':'Checkpoint defaults';
    $('draft-status').classList.toggle('dirty',!!edited && !sameProfile(state.draft,active));
    $('load-model').disabled=!state.online || state.sending || state.refreshing || transitioning() || !model?.supported;
    $('save-profile').disabled=!state.online || state.sending || state.refreshing || !model?.supported;
    $('refresh-models').disabled=state.sending || state.refreshing;
    const sameModel=active?.modelID===state.selectedID;
    $('load-model').firstElementChild.textContent=state.sending?'Applying…':transitioning()?'Runtime busy…':sameModel?'Apply & reload':'Load model';
    $('apply-note').textContent=state.runtime?.mode==='managed' && state.runtime?.processID?'Applying this configuration reloads the managed model.':'Load this model to apply its configuration.';
    $('maximum-tokens').max=Math.max(1,(state.draft?.contextLength||2)-1);
    for(const button of $('context-presets').querySelectorAll('button')){const active=Number(button.dataset.context)===state.draft?.contextLength;button.classList.toggle('active',active);button.setAttribute('aria-pressed',String(active));}
    $('unload').disabled=state.sending || !state.online || transitioning();
    $('use-external').disabled=state.sending || !state.online;
  }
  function renderSession() {
    const runtime=state.runtime;
    if(!runtime)return;
    const managed=runtime.mode==='managed', loaded=managed?runtime.phase==='loaded':!!state.externalModel;
    const phase=managed?runtime.phase:loaded?'loaded':'idle';
    const labels={idle:'No managed model loaded',loading:'Loading model',loaded:'Model ready',stopping:'Releasing model',error:'Runtime needs attention'};
    $('session-dot').className=`status-dot ${state.online?phase:'error'}`;
    $('session-status').textContent=!state.online?'Control server unavailable':managed?(labels[runtime.phase]||runtime.phase):loaded?'Existing Midnight connection':state.externalChecked?'Existing connection offline':'Checking existing connection…';
    $('session-name').textContent=managed?(runtime.activeProfile?.servedModelName||'Ready to load a model'):(state.externalModel?.id||'Load a model from the library');
    $('session-message').textContent=!state.online?'Reconnect to manage the runtime.':managed?runtime.message:loaded?'Connected to a Midnight process started outside this app.':'Select a checkpoint below to start an app-managed Midnight process.';
    const facts=[];
    if(managed && loaded){facts.push([number(runtime.activeProfile.contextLength),'context tokens'],[number(runtime.activeProfile.maximumTokens),'output limit'],[runtime.activeProfile.engine,'requested engine']);}
    else if(!managed && loaded){facts.push([number(state.externalModel.contextLength),'context tokens'],[state.externalModel.layerCount,'layers']);}
    $('session-facts').innerHTML=facts.map(([value,label])=>`<div class="session-fact"><strong>${escapeHTML(value)}</strong><span>${label}</span></div>`).join('');
    $('inspect-active').hidden=!loaded;
    $('unload').hidden=!managed || (!runtime.activeProfile && !transitioning());
    $('unload').textContent='Unload model';
    $('runtime-endpoint').textContent=runtime.endpoint;
    $('runtime-log').textContent=runtime.logs?.join('\n')||'No app-managed runtime activity yet.';
    if(runtime.phase==='error')$('runtime-details').open=true;
    $('ownership-note').textContent=managed?'The inspector follows this managed runtime. Refresh its layer view after loading a different model.':loaded?'Loading here starts a separate Midnight process. This app only unloads the models it starts.':'Models loaded here run in a local Midnight process managed by this app.';
    $('use-external').hidden=!managed;
    updateActions();
  }
  function applyState(runtime) {
    const previous=state.runtime;
    state.runtime=runtime;state.online=true;
    renderSession();
    if(!previous || previous.mode!==runtime.mode || previous.phase!==runtime.phase || previous.activeProfile?.modelID!==runtime.activeProfile?.modelID)renderLibrary();
    if(runtime.phase==='error' && state.lastPhase!=='error')notice(runtime.lastError||runtime.message);
    state.lastPhase=runtime.phase;
  }
  async function refreshCatalog() {
    if(state.refreshing || state.sending)return;
    state.epoch++;
    state.refreshing=true;updateActions();notice('');
    try{
      const [catalog,runtime]=await Promise.all([api('/api/control/models'),api('/api/control/state')]);
      if(!Array.isArray(catalog.models) || !Array.isArray(runtime.savedProfiles))throw new Error('The control server returned an invalid response.');
      state.models=catalog.models;applyState(runtime);renderLibrary();
      if(runtime.mode==='external'){
        state.externalModel=await api('/api/model?connection=primary').catch(()=>null);
        state.externalChecked=true;renderSession();
      }
      if(!selected()){
        const active=state.models.find(model=>model.id===runtime.activeProfile?.modelID);
        const supported=state.models.filter(model=>model.supported).sort((a,b)=>(a.weightBytes??Infinity)-(b.weightBytes??Infinity));
        const matches=state.externalModel ? state.models.filter(model=>model.name===state.externalModel.id || model.path===state.externalModel.id) : [];
        const initial=active||(matches.length===1 ? matches[0] : null)||supported[0]||state.models[0];
        if(initial)selectModel(initial.id);else{state.selectedID=null;state.draft=null;renderForm();}
      }else renderForm();
    }catch(error){state.online=false;notice(error.message);$('session-status').textContent='Control server unavailable';$('session-dot').className='status-dot error';}
    finally{state.refreshing=false;updateActions();schedulePoll();}
  }
  function schedulePoll() {
    clearTimeout(state.pollTimer);
    if(document.hidden)return;
    state.pollTimer=setTimeout(pollState,transitioning()?1000:4000);
  }
  async function pollState() {
    if(state.sending || state.refreshing){schedulePoll();return;}
    const epoch=state.epoch;
    try{
      const runtime=await api('/api/control/state');
      if(epoch!==state.epoch)return;
      applyState(runtime);
      if(runtime.mode==='external'){
        const external=await api('/api/model?connection=primary').catch(()=>null);
        if(epoch!==state.epoch || state.runtime?.mode!=='external')return;
        state.externalModel=external;state.externalChecked=true;renderSession();
      }
    }
    catch{if(epoch===state.epoch){state.online=false;renderSession();}}
    finally{schedulePoll();}
  }
  async function mutate(action,payload={}) {
    if(state.sending || state.refreshing)throw new Error('Wait for the current control request to finish.');
    if(!state.online)throw new Error('Reconnect to the control server first.');
    if(['load','profile'].includes(action))validateProfile(payload,selected());
    state.epoch++;
    state.sending=true;clearTimeout(state.pollTimer);updateActions();notice('');
    try{
      const runtime=await api(`/api/control/${action}`,payload);applyState(runtime);
      if(action==='profile')notice('Defaults saved for this model.',true);
      if(action==='external'){
        state.externalModel=await api('/api/model?connection=primary').catch(()=>null);
        state.externalChecked=true;renderSession();
      }
      return runtime;
    }finally{state.sending=false;updateActions();schedulePoll();}
  }
  function readDraft() {
    if(!state.draft)return;
    for(const [key,id] of Object.entries(fields))state.draft[key]=numericFields.has(key)?Number($(id).value):$(id).value;
    state.drafts.set(state.selectedID,{...state.draft});updateActions();
  }
  async function handle(action,payload){try{return await mutate(action,payload);}catch(error){notice(error.message);throw error;}}
  $('model-list').addEventListener('click',event=>{const button=event.target.closest('[data-model-id]');if(button)selectModel(button.dataset.modelId);});
  $('configuration-form').addEventListener('input',readDraft);
  $('configuration-form').addEventListener('change',readDraft);
  $('configuration-form').addEventListener('submit',event=>{event.preventDefault();readDraft();handle('load',{...state.draft}).catch(()=>{});});
  $('save-profile').addEventListener('click',()=>{readDraft();handle('profile',{...state.draft}).catch(()=>{});});
  $('context-presets').addEventListener('click',event=>{const button=event.target.closest('[data-context]');if(button){$('context-length').value=button.dataset.context;readDraft();}});
  $('refresh-models').addEventListener('click',refreshCatalog);
  $('unload').addEventListener('click',()=>handle('unload').catch(()=>{}));
  $('use-external').addEventListener('click',()=>handle('external').catch(()=>{}));
  document.addEventListener('visibilitychange',()=>{if(document.hidden)clearTimeout(state.pollTimer);else pollState();});
  window.addEventListener('pagehide',()=>clearTimeout(state.pollTimer),{once:true});
  if(document.modelContext?.registerTool){
    const lifecycle=new AbortController();
    const tools=[
      {name:'read_midnight_runtime',description:'Read current managed or external Midnight status and saved model profiles.',inputSchema:{type:'object',properties:{},additionalProperties:false},annotations:{readOnlyHint:true,untrustedContentHint:true},execute:async()=>{const epoch=state.epoch;const runtime=await api('/api/control/state');if(epoch===state.epoch&&!state.sending&&!state.refreshing)applyState(runtime);return runtime;}},
      {name:'configure_midnight_model',description:'Select an installed model and stage validated settings in the configuration form. Does not save or load it.',inputSchema:{type:'object',properties:{modelID:{type:'string'},contextLength:{type:'integer'},maximumTokens:{type:'integer'},prefillStepSize:{type:'integer'},servedModelName:{type:'string'},engine:{type:'string',enum:['auto','metal','cpu']},kvCompression:{type:'string',enum:['none','affine8','affine4','turbo8v4']}},required:['modelID'],additionalProperties:false},execute:input=>{const model=state.models.find(m=>m.id===input?.modelID);if(!model)throw new Error('Unknown model.');const profile={...profileFor(model)};for(const key of Object.keys(fields))if(input[key]!==undefined)profile[key]=input[key];validateProfile(profile,model);selectModel(model.id);state.draft=profile;state.drafts.set(model.id,{...profile});renderForm();return profile;}},
      {name:'save_midnight_defaults',description:'Persist the settings currently staged in the form as app-specific defaults for this model.',inputSchema:{type:'object',properties:{},additionalProperties:false},execute:()=>handle('profile',{...state.draft})},
      {name:'load_configured_midnight_model',description:'Load the model and settings staged in the configuration form. Replaces any app-managed runtime and makes the layer inspector follow it.',inputSchema:{type:'object',properties:{},additionalProperties:false},execute:()=>handle('load',{...state.draft})}
    ];
    for(const tool of tools){try{Promise.resolve(document.modelContext.registerTool(tool,{signal:lifecycle.signal})).catch(()=>{});}catch{}}
    window.addEventListener('pagehide',()=>lifecycle.abort(),{once:true});
  }
  refreshCatalog();
})();
