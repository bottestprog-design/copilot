const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const state = {
  page: 'studio', task: 'image', workflows: [], models: {}, catalog: [], jobs: [],
  mappingId: null, mappingDetail: null, lastDiagnostic: null, busy: false,
  dimensionsEdited: false, samplingEdited: false, videoTimingEdited: false, batchEdited: false,
  healthBusy: false, healthFailureShown: false, lastHealthErrorAt: 0, pollingBusy: false
};

function esc(value) {
  return String(value ?? '').replace(/[&<>"']/g, (ch) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
}
function safeMediaUrl(value) {
  const candidate = String(value ?? '');
  // Generated assets are always proxied through this application's local media endpoint.
  // Do not let a malformed/corrupt local history record inject javascript:, data: or remote URLs.
  return candidate.startsWith('/api/media?') && !candidate.startsWith('//') ? candidate : '';
}
function safeExternalUrl(value) {
  try {
    const parsed = new URL(String(value ?? ''));
    return parsed.protocol === 'https:' && parsed.hostname && !parsed.username && !parsed.password ? parsed.href : '';
  } catch { return ''; }
}
async function api(url, options = {}) {
  const response = await fetch(url, options);
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.detail || data.message || `HTTP ${response.status}`);
  return data;
}
function toast(message, type = 'info') {
  const item = document.createElement('div');
  item.className = `toast ${type}`;
  item.textContent = message;
  $('#toast-stack').appendChild(item);
  setTimeout(() => item.remove(), 4200);
}
function alertBox(id, message, success = false) {
  const el = $(id);
  el.hidden = !message;
  el.classList.toggle('success', !!success);
  el.textContent = message || '';
}
function setPage(page) {
  state.page = page;
  $$('.page').forEach(el => el.classList.toggle('active', el.id === `page-${page}`));
  $$('.nav-item').forEach(el => el.classList.toggle('active', el.dataset.page === page));
  const titles = {studio:'الاستوديو الإبداعي',library:'المكتبة والنتائج',models:'النماذج المحلية',workflows:'إدارة سير العمل',diagnostics:'فحص النظام'};
  $('#breadcrumb-title').textContent = titles[page] || 'LocalAI';
  if (page === 'library') loadLibrary();
  if (page === 'models') loadCatalog();
  if (page === 'workflows') loadWorkflows();
  if (page === 'diagnostics') { runDiagnostic(); loadSettings(); }
  window.scrollTo({top:0, behavior:'smooth'});
}
$$('.nav-item').forEach(button => button.addEventListener('click', () => setPage(button.dataset.page)));
$$('[data-open-page]').forEach(button => button.addEventListener('click', () => setPage(button.dataset.openPage)));

function setTask(task) {
  state.task = task;
  $$('.task-tab').forEach(button => button.classList.toggle('selected', button.dataset.task === task));
  $$('.video-only').forEach(el => { el.hidden = task !== 'video'; el.style.display = task === 'video' ? 'block' : 'none'; });
  $('#generate-button span:nth-child(2)').textContent = task === 'video' ? 'ابدأ إنشاء الفيديو' : 'ابدأ التوليد';
  renderWorkflowSelect();
  $('#reference-block').querySelector('.field-hint').textContent = task === 'video' ? 'لتحريك صورة أو بدء المشهد من إطار مرجعي' : 'اختياري إذا كان مسار الصور يدعم Image-to-Image';
}
$$('.task-tab').forEach(button => button.addEventListener('click', () => setTask(button.dataset.task)));

async function refreshHealth({ notify = false } = {}) {
  if (state.healthBusy) return;
  state.healthBusy = true;
  try {
    const health = await api('/api/health');
    updateServicePill('#comfy-pill', health.comfyui.ok, health.comfyui.ok ? 'متصل' : 'غير متصل');
    updateServicePill('#ollama-pill', health.ollama.ok, health.ollama.ok ? 'متصل' : 'غير متصل');
    $('#comfy-state').textContent = health.comfyui.ok ? 'متصل' : 'غير متصل';
    $('#ollama-state').textContent = health.ollama.ok ? 'متصل' : 'غير متصل';
    $('#comfy-state').closest('.engine-row').classList.toggle('ok', health.comfyui.ok);
    $('#comfy-state').closest('.engine-row').classList.toggle('bad', !health.comfyui.ok);
    $('#ollama-state').closest('.engine-row').classList.toggle('ok', health.ollama.ok);
    $('#ollama-state').closest('.engine-row').classList.toggle('bad', !health.ollama.ok);
    $('#local-state-text').textContent = health.comfyui.ok ? 'محرك التوليد المحلي جاهز' : 'شغّل ComfyUI على المنفذ 8188 لبدء التوليد';
    if ($('#app-version') && health.version) $('#app-version').textContent = `v${health.version}`;
    state.healthFailureShown = false;
  } catch (error) {
    updateServicePill('#comfy-pill', false, 'فشل الاتصال');
    updateServicePill('#ollama-pill', false, 'فشل الاتصال');
    $('#comfy-state').textContent = 'غير متصل';
    $('#ollama-state').textContent = 'غير متصل';
    $('#comfy-state').closest('.engine-row').classList.add('bad');
    $('#ollama-state').closest('.engine-row').classList.add('bad');
    $('#local-state-text').textContent = 'تعذر الوصول إلى حالة الخدمات المحلية';
    const now = Date.now();
    // A service being offline is an ordinary state, not a reason to spam a toast every poll.
    if (notify && (!state.healthFailureShown || now - state.lastHealthErrorAt > 30000)) {
      toast(`تعذر قراءة حالة الخدمات: ${error.message}`, 'error');
      state.healthFailureShown = true;
      state.lastHealthErrorAt = now;
    }
  } finally {
    state.healthBusy = false;
  }
}
function updateServicePill(id, ok, label) {
  const el = $(id);
  el.classList.toggle('ok', ok);
  el.classList.toggle('bad', !ok);
  el.querySelector('b').textContent = label;
}
$('#refresh-top').addEventListener('click', () => refreshHealth({ notify: true }));

async function loadWorkflows() {
  try {
    const data = await api('/api/workflows');
    state.workflows = data.workflows || [];
    renderWorkflowSelect();
    renderWorkflowList();
  } catch (error) { toast(`تعذر تحميل المسارات: ${error.message}`, 'error'); }
}
function renderWorkflowSelect() {
  const select = $('#workflow-select');
  const matches = state.workflows.filter(w => !w.error && w.task === state.task);
  const current = select.value;
  select.innerHTML = matches.length
    ? matches.map(w => `<option value="${esc(w.id)}">${esc(w.name)} · ${esc(w.model_name||'ComfyUI')} · ${w.nodes} nodes</option>`).join('')
    : `<option value="">لا يوجد مسار ${state.task === 'image' ? 'صور' : 'فيديو'} — أضف Workflow أولاً</option>`;
  if (matches.some(w => w.id === current)) select.value = current;
  const wf = matches.find(w => w.id === select.value) || matches[0];
  if (wf && wf.id !== state.lastWorkflowDefaultsId) applyWorkflowDefaults(wf);
  $('#workflow-help').textContent = wf
    ? `المسار المحدد: ${wf.nodes} عقدة. ${wf.defaults?.width && wf.defaults?.height ? `المقاس الأصلي ${wf.defaults.width}×${wf.defaults.height}. ` : ''}الإعدادات الأصلية للمسار محفوظة؛ لن نغيّرها إلا عند تعديل حقول التحكم.`
    : state.task === 'image'
      ? 'يمكنك بدءاً بمسار SDXL القياسي إذا كان لديك Checkpoint متوافق، أو استيراد FLUX / Qwen Image من ComfyUI.'
      : 'استورد مسار Wan 2.2 أو HunyuanVideo أو LTX من قوالب ComfyUI بصيغة API أولاً.';
}
function applyWorkflowDefaults(workflow) {
  const defaults = workflow.defaults || {};
  state.lastWorkflowDefaultsId = workflow.id;
  state.dimensionsEdited = false;
  state.samplingEdited = false;
  state.videoTimingEdited = false;
  state.batchEdited = false;
  for (const key of ['steps', 'cfg', 'frames', 'fps', 'batch_size']) {
    const element = document.getElementById(key === 'batch_size' ? 'batch-size' : key);
    if (element && defaults[key] !== undefined && defaults[key] !== null) element.value = defaults[key];
  }
  if (Number.isFinite(Number(defaults.width)) && Number.isFinite(Number(defaults.height)) && defaults.width && defaults.height) {
    const width = Number(defaults.width), height = Number(defaults.height);
    const ratio = width / height;
    const ratios = {'1:1':1, '16:9':16/9, '9:16':9/16, '4:3':4/3, '3:2':3/2};
    const bestRatio = Object.entries(ratios).sort((a,b)=>Math.abs(a[1]-ratio)-Math.abs(b[1]-ratio))[0];
    if (bestRatio) $('#aspect').value = bestRatio[0];
    const choices = [...$('#resolution').options].map(o=>Number(o.value)).filter(Number.isFinite);
    if (choices.length) $('#resolution').value = String(choices.sort((a,b)=>Math.abs(a-Math.max(width,height))-Math.abs(b-Math.max(width,height)))[0]);
  }
}

$('#workflow-select').addEventListener('change', () => { renderWorkflowSelect(); loadModels(); });
$('#resolution').addEventListener('change', () => { state.dimensionsEdited = true; });
$('#aspect').addEventListener('change', () => { state.dimensionsEdited = true; });
['#steps','#cfg'].forEach(selector => $(selector).addEventListener('change', () => { state.samplingEdited = true; }));
['#frames','#fps'].forEach(selector => $(selector).addEventListener('change', () => { state.videoTimingEdited = true; }));
$('#batch-size').addEventListener('change', () => { state.batchEdited = true; });

async function loadModels() {
  try {
    const data = await api('/api/models');
    state.models = data.folders || {};
    const ckpts = state.models.checkpoints || [];
    const select = $('#checkpoint');
    const current = select.value;
    select.innerHTML = `<option value="">اختر Checkpoint مثبتاً (إن كان مطلوباً)</option>` + ckpts.map(v => `<option value="${esc(v)}">${esc(v)}</option>`).join('');
    if (ckpts.includes(current)) select.value = current;
    const workflow = state.workflows.find(w => w.id === $('#workflow-select').value);
    const hasCheckpoint = workflow?.bindings?.checkpoint;
    $('.wide-control').style.display = hasCheckpoint ? 'block' : 'none';
  } catch (error) { console.warn(error); }
}

function getAspectSize() {
  const base = Number($('#resolution').value || 1024);
  const ratio = $('#aspect').value;
  const map = {'1:1':[1,1], '16:9':[16,9], '9:16':[9,16], '4:3':[4,3], '3:2':[3,2]};
  const [rw,rh] = map[ratio] || [1,1];
  let width, height;
  if (rw >= rh) { width = base; height = base * rh/rw; }
  else { height = base; width = base * rw/rh; }
  return {width:Math.max(256, Math.round(width/64)*64), height:Math.max(256, Math.round(height/64)*64)};
}

async function enhancePrompt() {
  const prompt = $('#prompt').value.trim();
  if (!prompt) return toast('اكتب فكرة أولاً قبل تحسين الوصف.', 'error');
  const button = $('#enhance-prompt');
  button.disabled = true;
  button.textContent = 'يعمل Qwen المحلي...';
  alertBox('#studio-alert', '');
  try {
    const result = await api('/api/prompt/enhance', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body:JSON.stringify({prompt, task:state.task, style:'cinematic, high fidelity'})
    });
    $('#prompt').value = result.positive_prompt;
    $('#negative-prompt').value = result.negative_prompt || $('#negative-prompt').value;
    $('#prompt-count').textContent = `${$('#prompt').value.length} / 8000`;
    $('#enhance-notes').hidden = !result.notes;
    $('#enhance-notes').textContent = result.notes || '';
    toast('تم تحسين الوصف باستخدام النموذج المحلي.', 'success');
  } catch (error) { alertBox('#studio-alert', error.message); }
  finally { button.disabled = false; button.innerHTML = '<span>✧</span> تحسين الوصف بالذكاء الاصطناعي'; }
}
$('#enhance-prompt').addEventListener('click', enhancePrompt);
$('#prompt').addEventListener('input', () => $('#prompt-count').textContent = `${$('#prompt').value.length} / 8000`);

let referenceObjectUrl = null;
$('#reference-image').addEventListener('change', () => {
  const file = $('#reference-image').files[0];
  if (referenceObjectUrl) { URL.revokeObjectURL(referenceObjectUrl); referenceObjectUrl = null; }
  const preview = $('#reference-preview');
  if (!file) { preview.hidden = true; return; }
  if (file.size > 30*1024*1024) { toast('حجم الصورة أكبر من 30MB.', 'error'); $('#reference-image').value=''; return; }
  const url = URL.createObjectURL(file);
  referenceObjectUrl = url;
  preview.hidden = false;
  preview.innerHTML = `<img src="${url}" alt="مرجع"><span>${esc(file.name)} · ${(file.size/1024/1024).toFixed(1)}MB</span><button type="button" id="clear-reference">إزالة</button>`;
  $('#clear-reference').addEventListener('click', (event) => { event.preventDefault(); $('#reference-image').value=''; preview.hidden=true; preview.innerHTML=''; if(referenceObjectUrl){URL.revokeObjectURL(referenceObjectUrl);referenceObjectUrl=null;} });
});

async function generate() {
  if (state.busy) return;
  const prompt = $('#prompt').value.trim();
  const workflowId = $('#workflow-select').value;
  if (!prompt) return alertBox('#studio-alert', 'اكتب وصفاً للمحتوى قبل بدء التوليد.');
  if (!workflowId) return alertBox('#studio-alert', 'لا يوجد Workflow مناسب لهذا النوع. أضف مساراً من صفحة سير العمل.');
  const workflow = state.workflows.find(w => w.id === workflowId);
  if (!workflow?.bindings?.positive) return alertBox('#studio-alert', 'اربط خانة Positive Prompt أولاً من إدارة سير العمل.');
  const size = getAspectSize();
  const payload = {
    workflow_id: workflowId, task:state.task, prompt,
    negative_prompt:$('#negative-prompt').value.trim(),
    seed:$('#seed').value.trim() === '' ? null : Number($('#seed').value),
    width:state.dimensionsEdited ? size.width : null,
    height:state.dimensionsEdited ? size.height : null,
    steps:state.samplingEdited ? Number($('#steps').value||28) : null,
    cfg:state.samplingEdited ? Number($('#cfg').value||6) : null,
    frames:state.task==='video' && state.videoTimingEdited ? Number($('#frames').value||81) : null,
    fps:state.task==='video' && state.videoTimingEdited ? Number($('#fps').value||24) : null,
    checkpoint:$('#checkpoint').value || null,
    batch_size:state.batchEdited ? Number($('#batch-size').value||1) : null
  };
  const form = new FormData();
  form.append('request_json', JSON.stringify(payload));
  const image = $('#reference-image').files[0];
  if (image) form.append('image', image);
  const button = $('#generate-button');
  state.busy = true; button.disabled = true;
  button.querySelector('span:nth-child(2)').textContent = 'جارٍ إرسال المهمة...';
  alertBox('#studio-alert','');
  try {
    const result = await api('/api/generate', {method:'POST', body:form});
    toast(`تم إرسال المهمة إلى الطابور (#${result.queue_number ?? '—'}).`, 'success');
    await loadRecentJobs();
  } catch (error) { alertBox('#studio-alert', error.message); }
  finally {
    state.busy = false; button.disabled = false;
    button.querySelector('span:nth-child(2)').textContent = state.task==='video' ? 'ابدأ إنشاء الفيديو' : 'ابدأ التوليد';
  }
}
$('#generate-button').addEventListener('click', generate);

async function refreshQueue(){
  try{
    const queue=await api('/api/queue');
    const running=Array.isArray(queue.queue_running)?queue.queue_running.length:0;
    const pending=Array.isArray(queue.queue_pending)?queue.queue_pending.length:0;
    $('#queue-count').textContent=`${running} قيد التنفيذ · ${pending} في الانتظار`;
  }catch(error){$('#queue-count').textContent='الطابور غير متاح — تحقق من ComfyUI';}
}
$('#interrupt-queue').addEventListener('click',async()=>{
  if(!confirm('سيتم إرسال طلب إيقاف للعملية الجارية حالياً. هل تريد المتابعة؟'))return;
  try{const result=await api('/api/queue/interrupt',{method:'POST'});if(result.interrupted){toast('تم إرسال طلب إيقاف مهمة الاستوديو.','success');}else{toast(result.message||'لم يتم إيقاف أي مهمة؛ المهمة الجارية ليست مهمة مؤكدة لهذا الاستوديو.','info');}await refreshQueue();}
  catch(error){toast(error.message,'error');}
});
$('#clear-queue').addEventListener('click',async()=>{
  if(!confirm('سيتم حذف المهام المنتظرة التي أرسلها هذا الاستوديو فقط. المهام الأخرى في ComfyUI لن تتأثر. هل تريد المتابعة؟'))return;
  try{const result=await api('/api/queue/clear',{method:'POST'});toast(`تم حذف ${result.deleted||0} مهمة من مهام الاستوديو فقط.`,'success');await refreshQueue();await loadRecentJobs();}
  catch(error){toast(error.message,'error');}
});

function statusLabel(status) {
  const labels = {submitting:'جارٍ تأكيد الإرسال',queued:'في الانتظار',running:'قيد التنفيذ',completed:'اكتمل',failed:'فشل',cancelled:'أُلغي',missing:'غير موجود في سجل المحرك'};
  return esc(labels[String(status || '')] || 'غير معروف');
}
function outputElement(output) {
  const url = safeMediaUrl(output?.url);
  if (!url) return '<div class="processing">مسار المعاينة غير صالح</div>';
  const filename = String(output.filename || '');
  const video = /\.(mp4|webm|mov|m4v|mkv)$/i.test(filename) || output.kind === 'videos';
  const audio = /\.(wav|mp3|ogg|flac|m4a|aac)$/i.test(filename) || output.kind === 'audio';
  if (video) return `<video src="${esc(url)}" controls preload="metadata"></video>`;
  if (audio) return `<audio src="${esc(url)}" controls preload="metadata"></audio>`;
  return `<img src="${esc(url)}" alt="نتيجة مولدة" loading="lazy">`;
}
function jobCard(job, compact=false, showAllOutputs=false) {
  const outputs = Array.isArray(job.outputs) ? job.outputs.filter(output => output && typeof output === 'object') : [];
  const visibleOutputs = showAllOutputs ? outputs : outputs.slice(0, 1);
  const preview = visibleOutputs.length
    ? visibleOutputs.map((output, index) => showAllOutputs
      ? `<div class="job-output" aria-label="نتيجة ${index + 1}">${outputElement(output)}</div>`
      : outputElement(output)).join('')
    : `<div class="processing">${job.status==='failed' ? 'تعذر إكمال العملية' : job.status==='completed' ? 'اكتملت العملية' : job.status==='cancelled' ? 'أُلغيت قبل التشغيل' : job.status==='missing' ? 'اختفت من سجل ComfyUI' : job.status==='submitting' ? 'جارٍ تأكيد إرسال المهمة...' : '◌ قيد التوليد...'}</div>`;
  const previewClass = showAllOutputs && outputs.length > 1 ? 'job-output-grid' : '';
  const outputCount = outputs.length > 1 ? `<span class="output-count">${outputs.length} نتائج</span>` : '';
  const title = (job.prompt || 'Generation').replace(/\s+/g,' ').slice(0,85);
  return `<article class="job-card ${compact?'compact-card':''}"><div class="job-preview ${previewClass}">${preview}${outputCount}</div><div class="job-info"><strong title="${esc(job.prompt||'')}">${esc(title)}</strong><small>${esc(new Date((job.created_at||Date.now()/1000)*1000).toLocaleString('ar'))}</small><span class="job-status ${esc(job.status)}">${statusLabel(job.status)}</span>${job.error?`<small class="job-error">${esc(job.error).slice(0,130)}</small>`:''}</div></article>`;
}
function renderRecentJobs() {
  const active = state.jobs.slice(0,6);
  $('#recent-jobs').innerHTML = active.length ? active.map(job=>jobCard(job,true)).join('') : `<div class="empty-state"><span>◌</span><strong>لا توجد عمليات بعد</strong><small>ابدأ أول عملية توليد وستظهر هنا حالتها ونتائجها.</small></div>`;
}
async function loadRecentJobs() {
  try {
    const data = await api('/api/jobs?limit=60');
    state.jobs = data.jobs || [];
    renderRecentJobs();
  } catch (error) { console.warn(error); }
}
async function pollActiveJobs() {
  const active = state.jobs.filter(job => ['queued','running'].includes(job.status)).slice(0,8);
  let changed = false;
  for (const job of active) {
    try {
      const updated = await api(`/api/jobs/${encodeURIComponent(job.id)}`);
      const index = state.jobs.findIndex(x => x.id === job.id);
      if (index >= 0) {
        if (updated.status !== state.jobs[index].status || (updated.outputs||[]).length !== (state.jobs[index].outputs||[]).length) changed = true;
        state.jobs[index] = {...state.jobs[index], ...updated};
      }
    } catch (error) { console.warn(error); }
  }
  if (changed) { renderRecentJobs(); if (state.page==='library') renderLibrary(); }
}

function renderLibrary() {
  const content = $('#library-content');
  const completed = state.jobs.filter(job => (job.outputs||[]).length);
  if (!completed.length) {
    content.innerHTML = `<div class="empty-state"><span>▧</span><strong>مكتبتك فارغة حالياً</strong><small>أول صورة أو فيديو تنشئه سيظهر هنا.</small></div>`;
    return;
  }
  content.innerHTML = completed.map(job => `<article class="library-card">${jobCard(job,false,true)}</article>`).join('');
}
async function loadLibrary() { await loadRecentJobs(); renderLibrary(); }
$('#refresh-library').addEventListener('click', loadLibrary);

async function loadCatalog() {
  try {
    const data = await api('/api/catalog');
    state.catalog = data.models || [];
    const h = data.hardware || {};
    const gpu = h.gpus?.length ? h.gpus.map(g=>g.name).join('، ') : 'لم يتم اكتشاف NVIDIA GPU عبر nvidia-smi';
    $('#hardware-summary').innerHTML = `
      <div class="hardware-card"><small>بطاقة الرسوميات</small><strong>${esc(gpu)}</strong><span>${h.gpus?.[0]?.vram_total_gb ? esc(h.gpus[0].vram_total_gb)+' GB VRAM' : 'تحقق يدوياً من GPU'}</span></div>
      <div class="hardware-card"><small>ذاكرة النظام</small><strong>${esc(h.ram_total_gb||'—')} GB</strong><span>${esc(h.ram_available_gb||'—')} GB متاحة حالياً</span></div>
      <div class="hardware-card"><small>المعالج</small><strong>${esc(h.cpu_logical||'—')} Threads</strong><span>المعالجة عبر محركات محلية</span></div>
      <div class="hardware-card"><small>مساحة القرص</small><strong>${esc(h.disk_free_gb||'—')} GB</strong><span>المتاح في قرص تشغيل التطبيق</span></div>`;
    renderCatalog('all');
  } catch (error) { toast(`تعذر قراءة دليل النماذج: ${error.message}`, 'error'); }
}
function renderCatalog(filter) {
  const models = state.catalog.filter(m=>filter==='all'||m.kind===filter);
  $('#model-grid').innerHTML = models.map(m=>`<article class="model-card">
    <div class="model-top"><h3>${esc(m.name)}</h3><span class="model-kind">${m.kind==='image'?'IMAGE':'VIDEO'}</span></div>
    <p>${esc(m.strength)}</p><div class="model-meta"><span>${esc(m.license)}</span><span>${esc(m.source)}</span><span>${m.tier==='quality'?'جودة قصوى':'متوازن'}</span></div>
    <div class="model-hardware">المتطلبات: ${esc(m.hardware)}</div>
    <div class="model-bottom"><span class="model-fit ${esc(m.fit)}">${m.fit==='candidate'?'مرشح مناسب للفحص':m.fit==='heavy'?'ثقيل على الجهاز':m.fit==='not-recommended'?'غير موصى به لهذه الذاكرة':'تحقق من المواصفات'}</span>${safeExternalUrl(m.url) ? `<a href="${esc(safeExternalUrl(m.url))}" target="_blank" rel="noopener noreferrer">المصدر الرسمي ↗</a>` : '<span>المصدر غير متاح</span>'}</div>
  </article>`).join('') || `<div class="empty-state"><strong>لا توجد نتائج بهذا التصنيف</strong></div>`;
}
$$('.filter-chip').forEach(button=>button.addEventListener('click',()=>{$$('.filter-chip').forEach(x=>x.classList.toggle('active',x===button));renderCatalog(button.dataset.filter);}));
$('#refresh-models').addEventListener('click',loadCatalog);

function renderWorkflowList() {
  $('#workflow-count').textContent = state.workflows.filter(w=>!w.error).length;
  const list = state.workflows.filter(w=>!w.error);
  $('#workflow-list').innerHTML = list.length ? list.map(w=>`<div class="workflow-item"><div class="wf-icon">${w.task==='video'?'▶':'▧'}</div><div class="wf-info"><strong>${esc(w.name)}</strong><small>${w.task==='video'?'فيديو':'صور'} · ${esc(w.model_name||'مسار ComfyUI')} · ${w.nodes} nodes</small></div><div class="wf-actions"><button data-config-wf="${esc(w.id)}">ضبط</button><button data-delete-wf="${esc(w.id)}">حذف</button></div></div>`).join('') : `<div class="empty-state"><span>⌘</span><strong>لا توجد مسارات</strong><small>استورد API Workflow من ComfyUI للبدء.</small></div>`;
  $$('[data-config-wf]').forEach(button=>button.addEventListener('click',()=>openMapping(button.dataset.configWf)));
  $$('[data-delete-wf]').forEach(button=>button.addEventListener('click',()=>deleteWorkflow(button.dataset.deleteWf)));
}
$('#workflow-file').addEventListener('change',()=>{
  const file=$('#workflow-file').files[0];
  if(file && !$('#workflow-name').value) $('#workflow-name').value=file.name.replace(/\.json$/i,'');
});
$('#import-workflow').addEventListener('click',async()=>{
  const file=$('#workflow-file').files[0];
  if(!file) return alertBox('#workflow-alert','اختر ملف API Workflow بصيغة JSON أولاً.');
  const form=new FormData();form.append('file',file);form.append('task',$('#workflow-task').value);form.append('name',$('#workflow-name').value.trim());
  const button=$('#import-workflow');button.disabled=true;button.textContent='جارٍ الفحص والاستيراد...';
  try{
    const result=await api('/api/workflows/import',{method:'POST',body:form});
    alertBox('#workflow-alert',`تم استيراد ${result.name} بنجاح. راجع ربط المدخلات قبل الاستخدام.`,true);
    $('#workflow-file').value='';$('#workflow-name').value='';
    await loadWorkflows();await openMapping(result.id);toast('تمت إضافة سير العمل.', 'success');
  }catch(error){alertBox('#workflow-alert',error.message);}
  finally{button.disabled=false;button.innerHTML='استيراد المسار <span>←</span>';}
});

const mappingKeys = [
  ['positive','Positive prompt'],['negative','Negative prompt'],['init_image','Reference image'],
  ['seed','Seed'],['steps','Steps'],['cfg','CFG / Guidance'],['width','Width'],['height','Height'],
  ['frames','Frames / Length'],['fps','FPS'],['checkpoint','Checkpoint'],['image_subfolder','Image subfolder']
];
async function openMapping(id) {
  try {
    const detail=await api(`/api/workflows/${encodeURIComponent(id)}`);
    state.mappingId=id;state.mappingDetail=detail;
    $('#mapping-title').textContent=`ربط المدخلات: ${detail.name}`;
    const fields=detail.fields||[];
    const options=fields.map(f=>({value:`${f.node_id}::${f.input}`,label:`#${f.node_id} · ${f.node_title} → ${f.input} (${f.value_type})`}));
    $('#mapping-fields').innerHTML=mappingKeys.map(([key,label])=>{
      const selected=detail.bindings?.[key];const val=selected?`${selected.node_id}::${selected.input}`:'';
      return `<div class="mapping-field"><label for="map-${key}">${label}</label><select id="map-${key}"><option value="">— غير مربوط —</option>${options.map(o=>`<option value="${esc(o.value)}" ${o.value===val?'selected':''}>${esc(o.label)}</option>`).join('')}</select></div>`;
    }).join('') + `<div class="mapping-field"><label for="map-task">نوع سير العمل</label><select id="map-task"><option value="image" ${detail.task==='image'?'selected':''}>Image</option><option value="video" ${detail.task==='video'?'selected':''}>Video</option></select></div>`;
    $('#mapping-panel').hidden=false;alertBox('#mapping-alert','');
    $('#mapping-panel').scrollIntoView({behavior:'smooth',block:'center'});
  }catch(error){toast(error.message,'error');}
}
$('#close-mapping').addEventListener('click',()=>$('#mapping-panel').hidden=true);
$('#save-mapping').addEventListener('click',async()=>{
  if(!state.mappingId)return;
  const bindings={};
  for(const [key] of mappingKeys){
    const raw=$(`#map-${key}`)?.value||'';
    if(raw){const [node_id,input]=raw.split('::');bindings[key]={node_id,input};}
  }
  try{
    await api(`/api/workflows/${encodeURIComponent(state.mappingId)}/config`,{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({task:$('#map-task').value,name:state.mappingDetail.name,bindings})});
    await loadWorkflows();await loadModels();alertBox('#mapping-alert','تم حفظ ربط المدخلات.',true);toast('تم حفظ إعدادات الـ Workflow.', 'success');
  }catch(error){alertBox('#mapping-alert',error.message);}
});
$('#delete-workflow').addEventListener('click',()=>state.mappingId&&deleteWorkflow(state.mappingId));
async function deleteWorkflow(id){
  if(!confirm('هل تريد حذف هذا المسار وملف إعداداته من الاستوديو؟'))return;
  try{await api(`/api/workflows/${encodeURIComponent(id)}`,{method:'DELETE'});$('#mapping-panel').hidden=true;await loadWorkflows();toast('تم حذف المسار.','success');}
  catch(error){toast(error.message,'error');}
}

$('#toggle-advanced').addEventListener('click',()=>{
  const el=$('#advanced-grid');const expanded=$('#toggle-advanced').getAttribute('aria-expanded')==='true';
  $('#toggle-advanced').setAttribute('aria-expanded',String(!expanded));el.hidden=expanded;$('#toggle-advanced').textContent=expanded?'⌄':'⌃';
});

async function loadSettings(){
  try{
    const data=await api('/api/settings');
    $('#setting-comfy').value=data.comfy_url||'http://127.0.0.1:8188';
    $('#setting-ollama').value=data.ollama_url||'http://127.0.0.1:11434';
    $('#setting-model').value=data.ollama_model||'local-qwen35:latest';
    $('#settings-state').textContent='الإعدادات المحفوظة';
  }catch(error){alertBox('#settings-alert',error.message);}
}
$('#save-settings').addEventListener('click',async()=>{
  const button=$('#save-settings');button.disabled=true;
  try{
    const data=await api('/api/settings',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({comfy_url:$('#setting-comfy').value.trim(),ollama_url:$('#setting-ollama').value.trim(),ollama_model:$('#setting-model').value.trim()})});
    alertBox('#settings-alert','تم حفظ إعدادات الاتصال المحلية.',true);$('#settings-state').textContent='تم الحفظ';
    toast('تم حفظ الإعدادات.','success');await refreshHealth();
  }catch(error){alertBox('#settings-alert',error.message);}
  finally{button.disabled=false;}
});

async function runDiagnostic(){
  const container=$('#diagnostic-content');container.innerHTML='<div class="empty-state"><span>◌</span><strong>جارٍ فحص الخدمات...</strong></div>';
  try{
    const data=await api('/api/diagnostic');state.lastDiagnostic=data;
    const checks=[
      ['ComfyUI API',data.comfyui.ok, data.comfyui.ok?'يستجيب على المنفذ المحلي':'غير متصل أو غير مشغّل'],
      ['Ollama API',data.ollama.ok, data.ollama.ok?'يستجيب على المنفذ المحلي':'غير متصل أو غير مشغّل'],
      ['نموذج Qwen',data.checks.ollama_local_model_present, data.checks.ollama_local_model_present?'local-qwen35 موجود':'لم يتم العثور على alias المحلي'],
      ['مجلد البيانات',data.checks.studio_data_writable, data.checks.studio_data_writable?'قابل للكتابة':'لا توجد صلاحية كتابة'],
      ['مجلد Workflows',data.checks.workflow_dir_exists, data.checks.workflow_dir_exists?`${data.workflow_count} مسارات محفوظة`:'المجلد غير موجود']
    ];
    container.innerHTML=`<div class="diagnostic-card"><h3>الخدمات</h3>${checks.slice(0,3).map(renderCheck).join('')}</div>
      <div class="diagnostic-card"><h3>الموارد</h3>${renderCheck(['RAM',true,`${data.hardware.ram_available_gb} / ${data.hardware.ram_total_gb} GB متاحة`])}${renderCheck(['Disk',data.hardware.disk_free_gb>10,`${data.hardware.disk_free_gb} GB مساحة متاحة`])}${renderCheck(['GPU',data.hardware.gpus.length>0,data.hardware.gpus.map(g=>`${g.name} (${g.vram_total_gb||'?'} GB)`).join('، ')||'لم يتم اكتشاف NVIDIA GPU'])}</div>
      <div class="diagnostic-card"><h3>ملفات الاستوديو</h3>${checks.slice(3).map(renderCheck).join('')}${renderCheck(['Python',true,data.python])}</div>
      <div class="diagnostic-card"><h3>حماية البيانات</h3>${renderCheck(['Local only',true,'الخادم مربوط على 127.0.0.1'])}${renderCheck(['Ollama model store',true,'لا يتم تغيير أو حذف ملفات نماذج Ollama'])}${renderCheck(['Media generation',data.comfyui.ok,'يستخدم ComfyUI وليس Ollama'])}</div>`;
    $('#diagnostic-json').textContent=JSON.stringify(data,null,2);$('#copy-diagnostic').disabled=false;
  }catch(error){container.innerHTML=`<div class="inline-alert">${esc(error.message)}</div>`;}
}
function renderCheck([name,ok,detail]){return `<div class="check-row"><span>${esc(name)}</span><b class="${ok?'':'bad'}">${ok?'OK':'CHECK'} · ${esc(detail)}</b></div>`;}
$('#run-diagnostic').addEventListener('click',runDiagnostic);
$('#copy-diagnostic').addEventListener('click',async()=>{try{await navigator.clipboard.writeText($('#diagnostic-json').textContent);toast('تم نسخ التقرير.','success');}catch(e){toast('تعذر النسخ من المتصفح.','error');}});

async function boot(){
  await Promise.all([refreshHealth(),loadWorkflows(),loadRecentJobs(),refreshQueue()]);
  await loadModels();
  $('#checkpoint').title='اختر Checkpoint من نماذج ComfyUI المثبتة والمتوافقة مع هذا المسار.';
  setTask('image');
  setInterval(async()=>{
    if (state.pollingBusy) return;
    state.pollingBusy = true;
    try { await refreshHealth(); await pollActiveJobs(); await refreshQueue(); }
    finally { state.pollingBusy = false; }
  }, 7000);
  setInterval(loadRecentJobs,20000);
}
boot();
