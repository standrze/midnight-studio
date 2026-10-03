'use strict';
const StudioUI = {
  escape(value) { return String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); },
  busy(state) { return (state?.jobs || []).some(j => ['running','cancelling'].includes(j.phase)); },
  label(kind) { return ({download:'Download', 'stream-quantize':'Streaming Q4', quantize:'Local Q4', finetune:'LoRA fine-tuning', cpt:'LoRA continued pretraining'})[kind] || kind; },
  async datasetFile(file) {
    if (!file || file.size > 2 * 1024 * 1024) throw new Error('Choose a JSONL file of at most 2 MiB for each split.');
    return file.text();
  }
};
if (typeof module !== 'undefined') module.exports = StudioUI;
if (typeof document !== 'undefined') {
  const $ = id => document.getElementById(id);
  let state = null, models = [], submitting = false, polling = false, jobSignature = '';
  const fail = e => { $('notice').textContent = e.message; $('notice').hidden = false; };
  async function api(path, payload) {
    const response = await fetch(path, payload === undefined ? {} : {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
    const value = await response.json();
    if (!response.ok) throw new Error(value.error?.message || `Request failed (${response.status}).`);
    return value;
  }
  function options(id, values, label, empty) {
    const signature = JSON.stringify(values.map(v => [v.id,label(v)]));
    if ($(id).dataset.signature === signature) return;
    $(id).dataset.signature = signature;
    const previous = $(id).value;
    $(id).replaceChildren();
    $(id).add(new Option(values.length ? 'Choose one…' : empty, ''));
    for (const value of values) $(id).add(new Option(label(value), value.id));
    if (values.some(v => v.id === previous)) $(id).value = previous;
  }
  function renderSettings() {
    const training = ['finetune','cpt'].includes($('operation').value), streaming = $('hub-action').value === 'stream-quantize';
    const model = models.find(m => m.id === $('source-model').value);
    $('training-settings').hidden = !training; $('quantize-settings').hidden = training;
    $('training-settings').querySelectorAll('input,select').forEach(e => { e.disabled = !training; });
    $('hub-method').disabled = !streaming;
    $('hub-start').textContent = streaming ? 'Stream & quantize ↗' : 'Download checkpoint ↗';
    $('model-start').textContent = training ? 'Train adapter ↗' : 'Quantize model ↗';
    $('objective-help').textContent = $('operation').value === 'cpt'
      ? 'Adapter-based domain adaptation on plain text. Uses next-token loss across the entire example; base weights stay frozen.'
      : 'LoRA / QLoRA on complete prompt-and-answer examples. Use your model’s chat formatting. Loss covers the entire example.';
    $('model-detail').textContent = model ? `${model.architecture} · ${model.quantization || 'Unquantized'}${model.warning ? ' · '+model.warning : ''}` : 'Download a checkpoint or add a model folder when launching Studio.';
    const ready = state && (training ? state.trainerAvailable : state.quantizerAvailable);
    $('worker-status').textContent = ready ? '' : `The native ${training ? 'training' : 'quantization'} worker needs to be built. See Native worker setup below.`;
    if (!training && model?.quantization) $('worker-status').textContent = 'This model is already quantized. Choose an unquantized source.';
    const busy = submitting || !state || StudioUI.busy(state);
    $('hub-start').disabled = busy || (streaming && !state?.trainerAvailable);
    $('model-start').disabled = busy || !model || !model.supported || !ready || (training ? !$('dataset').value : !!model.quantization);
    $('cancel-job').hidden = !StudioUI.busy(state);
    $('cancel-job').disabled = submitting || state?.jobs[0]?.phase === 'cancelling';
  }
  function render() {
    options('dataset', state.datasets, d => `${d.name} · ${d.trainingExamples} train / ${d.validationExamples} validation`, 'Add a dataset below');
    $('library-path').textContent = `Studio model library: ${state.libraryPath}`;
    const signature = JSON.stringify(state.jobs);
    if (signature !== jobSignature) {
      const expanded = new Set([...$('jobs').querySelectorAll('details[open]')].map(e => e.dataset.job));
      const e = StudioUI.escape;
      $('jobs').innerHTML = state.jobs.map(j => `<article class="job"><div class="job-header"><strong>${e(StudioUI.label(j.request.kind))} · ${e(j.request.repository || models.find(m=>m.id===j.request.modelID)?.name || 'Local model')}</strong><span class="job-phase">${e(j.phase)}</span></div><p class="job-message">${e(j.message)}</p>${j.output ? `<p class="job-message">Output: <code>${e(j.output)}</code></p>${['finetune','cpt'].includes(j.request.kind) ? `<button class="quiet-button" data-load-adapter="${e(j.id)}">Load trained model ↗</button>` : '<a class="quiet-button" href="/control">Open model controls ↗</a>'}` : ''}<details data-job="${e(j.id)}" ${expanded.has(j.id) ? 'open' : ''}><summary>Job log · ${e(new Date(j.createdAt * 1000 + Date.UTC(2001,0,1)).toLocaleString())}</summary><pre>${e(j.logs.join('\n'))}</pre></details></article>`).join('') || '<p class="empty-note">No preparation jobs yet.</p>';
      jobSignature = signature;
    }
    renderSettings();
  }
  async function refresh() {
    if (polling || submitting) return;
    polling = true;
    try {
      const [next, catalog] = await Promise.all([api('/api/studio/state'),api('/api/control/models')]);
      state = next; models = catalog.models;
      options('source-model', models, m => m.name, 'No local models yet');
      render();
    } catch (e) { fail(e); } finally { polling = false; }
  }
  async function mutate(path, payload) {
    if (submitting) return;
    submitting = true; $('notice').hidden = true; renderSettings();
    try { state = await api(path, payload); render(); return true; }
    catch (e) { fail(e); }
    finally { submitting = false; renderSettings(); }
  }
  $('hub-form').addEventListener('submit', e => { e.preventDefault(); mutate('/api/studio/jobs',{kind:$('hub-action').value, repository:$('repository').value.trim(),revision:$('revision').value.trim(),method:$('hub-method').value}); });
  $('model-form').addEventListener('submit', e => {
    e.preventDefault();
    mutate('/api/studio/jobs',{kind:$('operation').value,modelID:$('source-model').value,method:$('local-method').value,
      datasetID:$('dataset').value,iterations:Number($('iterations').value),learningRate:Number($('rate').value),layers:Number($('layers').value),rank:Number($('rank').value),sequenceLength:Number($('sequence-length').value)});
  });
  $('dataset-form').addEventListener('submit', async e => {
    e.preventDefault();
    try {
      const [train,validation] = await Promise.all([StudioUI.datasetFile($('train-file').files[0]),StudioUI.datasetFile($('valid-file').files[0])]);
      await mutate('/api/studio/datasets',{name:$('dataset-name').value.trim(),train,validation});
      $('dataset-status').textContent = state ? `${state.datasets.length} dataset(s) available.` : '';
    } catch (e) { fail(e); }
  });
  $('jobs').addEventListener('click', async e => {
    const button = e.target.closest('[data-load-adapter]');
    if (button && await mutate('/api/studio/load-adapter',{jobID:button.dataset.loadAdapter})) location.assign('/control');
  });
  $('cancel-job').addEventListener('click',()=>mutate('/api/studio/cancel',{}));
  for (const id of ['source-model','operation','hub-action','dataset']) $(id).addEventListener('change',renderSettings);
  renderSettings(); refresh(); setInterval(refresh,2000);
}
// Keep the global runtime indicator live on companion pages.
if (typeof window !== 'undefined' && typeof window.setInterval === 'function' && document.getElementById('header-refresh')) {
  (() => {
    const label = document.getElementById('connection-status');
    const dot = document.getElementById('status-dot');
    const button = document.getElementById('header-refresh');
    let pending = false;
    async function updateRuntimeStatus() {
      if (pending) return;
      pending = true;
      button.disabled = true;
      try {
        const response = await fetch('/api/model', {signal: AbortSignal.timeout(8000), cache: 'no-store'});
        if (!response.ok) throw new Error('Runtime unavailable');
        await response.json();
        label.textContent = 'Midnight connected';
        dot.className = 'status-dot live';
      } catch {
        label.textContent = 'Midnight is offline';
        dot.className = 'status-dot offline';
      } finally { pending = false; button.disabled = false; }
    }
    button.addEventListener('click', updateRuntimeStatus);
    updateRuntimeStatus();
    setInterval(() => { if (!document.hidden) updateRuntimeStatus(); }, 15000);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) updateRuntimeStatus(); });
  })();
}
