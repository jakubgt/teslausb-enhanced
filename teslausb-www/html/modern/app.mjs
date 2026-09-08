import {resolveLibrary,validTrash,recordingPage,recordingNeighbors,RECORDINGS_PER_PAGE,escapeHTML as esc,bytesLabel,stampLabel,timeLabel,downloadQuery,CAMERAS} from './model.mjs';
import {ClipPlayer} from './player.mjs';
import {mountDevice,hasPendingPowerAction} from './device.js';
import {mountFiles,configuredFileDrives} from './files.js';
import {mountTrash} from './trash.js';
import {mountConnectionBanner} from './connection.mjs';

const $=s=>document.querySelector(s);
const state={page:'recordings',events:[],paths:[],category:'all',query:'',selected:new Set(),clipPage:1,hour:'latest',day:'latest',library:null,trash:null,trashAvailable:false,config:{},inFlight:false,speedTest:false,downloadCount:0};
let healthTimer=null,device=null,files=null,trashView=null,libraryAbort=null,connection=null;
export async function api(path,options={}) {
  if(!path.startsWith('/api/v1/'))throw new Error('Unsupported API URL.');
  const contact=connection?.beginRequest();let received=false;
  const controller=new AbortController(),parent=options.signal,abort=()=>controller.abort(parent?.reason);if(parent?.aborted)abort();else parent?.addEventListener('abort',abort,{once:true});
  const timeout=setTimeout(()=>controller.abort(new DOMException('The device did not respond in time.','TimeoutError')),options.timeout||30000);
  try{
    const method=options.method||'GET';const headers={'Accept':'application/json',...options.headers};let body=options.body;
    if(method!=='GET'){headers['X-TeslaUSB-Request']='1';if(body && typeof body==='object'){body=JSON.stringify(body);headers['Content-Type']='application/json';}}
    const response=await fetch(path,{...options,method,headers,body,signal:controller.signal,credentials:'same-origin',cache:'no-store'});
    received=true;connection?.receivedResponse(contact);
    const text=await response.text();if(text.length>32*1024*1024)throw new Error('Response is too large. Choose a single recording day.');
    let data;try{data=JSON.parse(text);}catch{const error=new Error(response.status===401?'Sign in again to continue.':'The device returned an unexpected response.');error.status=response.status;throw error;}
    if(!data||typeof data!=='object'||Array.isArray(data))throw new Error('The device returned an invalid response.');
    if(!response.ok||data.ok===false){const error=new Error(data.error||data.message||`Request failed (HTTP ${response.status}).`);error.status=response.status;throw error;}return data;
  }catch(error){if(!received&&!parent?.aborted)connection?.requestFailed(contact);if(controller.signal.aborted&&!parent?.aborted)throw new Error('Request timed out. Check the connection and try again.');throw error;}
  finally{clearTimeout(timeout);parent?.removeEventListener('abort',abort);}
}
function notice(message,action){$('#notice span').textContent=String(message);$('#notice').hidden=false;$('#notice-action').hidden=!action;$('#notice-action').textContent=action?.label||'';$('#notice-action').onclick=action?.run||null;}
$('#notice-dismiss').onclick=()=>$('#notice').hidden=true;
connection=mountConnectionBanner($('#connection-banner'),{retry:async()=>{if(device)await device.refresh();else await refreshHealth(true);},isPaused:hasPendingPowerAction});
const player=new ClipPlayer($('#player'),{api,onDownload:prepareDownload,onTrash:confirmMove,onNotice:notice,onNavigate:navigateClip,onMediaError:()=>void refreshHealth(true)});

let theme='auto';try{theme=localStorage.getItem('teslausb-modern-theme')||'auto';}catch{}
function applyTheme(){if(!['auto','light','dark'].includes(theme))theme='auto';document.documentElement.style.colorScheme=theme==='auto'?'light dark':theme;$('#theme-toggle').textContent='Appearance: '+theme[0].toUpperCase()+theme.slice(1);}
$('#theme-toggle').onclick=()=>{theme=theme==='auto'?'dark':theme==='dark'?'light':'auto';applyTheme();try{localStorage.setItem('teslausb-modern-theme',theme);}catch{}};applyTheme();

async function navigate(page){
  if(hasPendingPowerAction()&&page!=='device'){notice('A power action is pending. Use Device → Refresh status to check the connection before continuing.');return;}
  if(page==='files'&&!configuredFileDrives(state.config).length)return;
  if(state.page===page)return;
  if(state.page==='recordings')player.suspend();
  if(state.page==='device'){device?.destroy();device=null;}if(state.page==='files'){files?.destroy();files=null;}if(state.page==='trash'){trashView?.destroy();trashView=null;}
  state.page=page;for(const p of ['recordings','trash','device','files'])$('#'+p+'-page').hidden=p!==page;
  document.querySelectorAll('[data-page]').forEach(b=>{if(b.dataset.page===page)b.setAttribute('aria-current','page');else b.removeAttribute('aria-current');});$('#breadcrumb').textContent=page[0].toUpperCase()+page.slice(1);document.title='TeslaUSB · '+$('#breadcrumb').textContent;
  if(page==='recordings'){
    const current=state.events.find(e=>e.id===player.event?.id);if(current)await player.setEvent(current,{...player.snapshot(),suspended:state.speedTest});else if(state.events[0])await player.setEvent(state.events[0],{suspended:state.speedTest});else player.clear();renderGrid();
  }else if(page==='device')device=mountDevice($('#device-page'),{api,onNotice:notice});
  else if(page==='files')files=mountFiles($('#files-page'),{api,onNotice:notice,config:state.config});
  else trashView=mountTrash($('#trash-page'),{api,onNotice:notice,onLibraryChanged:()=>loadLibrary(state.day)});
}
document.querySelectorAll('[data-page]').forEach(b=>b.onclick=()=>navigate(b.dataset.page));
function currentPage(){return recordingPage(state.events,{category:state.category,query:state.query,hour:state.hour,page:state.clipPage});}
function updateClipNavigation(view=currentPage()){
  const neighbors=recordingNeighbors(view.events,player.event?.id);
  const scope=state.category==='RecentClips'&&view.hour!=='all'&&view.hour?`${view.hour}:00–${view.hour}:59`:'Selected recordings';
  player.setNavigation({...neighbors,previous:!!neighbors.previous,next:!!neighbors.next,scope,blocked:state.page!=='recordings'||state.inFlight||state.speedTest||hasPendingPowerAction()});
}
async function navigateClip(direction,{autoplay=false}={}){
  if(state.page!=='recordings'||state.inFlight||state.speedTest||hasPendingPowerAction()||document.hidden||player.suspended)return;
  const view=currentPage(),neighbors=recordingNeighbors(view.events,player.event?.id),event=direction<0?neighbors.previous:neighbors.next;
  if(!event)return;
  const saved=player.snapshot();state.clipPage=Math.floor(view.events.findIndex(item=>item.id===event.id)/RECORDINGS_PER_PAGE)+1;state.selected.clear();
  const loading=player.setEvent(event,{...saved,position:0,playing:autoplay||saved.playing});renderGrid();await loading;
}
function renderGrid(){
  const focused=document.activeElement?.dataset.select;const view=currentPage(),events=view.events,shown=view.items;
  state.clipPage=view.page;if(state.category==='RecentClips')state.hour=view.hour||'latest';
  updateClipNavigation(view);
  $('#hour-filter').hidden=state.category!=='RecentClips';
  const hours=$('#recording-hour');hours.replaceChildren();
  for(const {value,count} of view.hours)hours.add(new Option(`${value}:00–${value}:59 · ${count} clip${count===1?'':'s'}`,value));
  hours.add(new Option('All hours','all'));hours.value=view.hour||'all';hours.disabled=!view.hours.length;
  $('#recording-search').placeholder=state.category==='RecentClips'&&view.hour!=='all'?'Search this hour':'Search this day';
  $('#recording-search').setAttribute('aria-label',state.category==='RecentClips'&&view.hour!=='all'?'Search recordings in the selected hour':'Search recordings in the selected day');
  state.selected=new Set([...state.selected].filter(id=>shown.some(e=>e.id===id)));
  $('#clip-grid').innerHTML=shown.length?shown.map(e=>`<article class="clip-card${player.event?.id===e.id?' active':''}${state.selected.has(e.id)?' selected':''}">${e.group!=='RecentClips'?`<label class="clip-check"><input type="checkbox" data-select="${esc(e.id)}" aria-label="Select ${esc(e.category+' '+stampLabel(e.start))}" ${state.selected.has(e.id)?'checked':''}></label>`:''}<button type="button" class="clip-image" data-open="${esc(e.id)}" aria-label="View ${esc(e.category+' '+stampLabel(e.start))}">${e.thumb?`<img src="${esc(e.thumb)}" alt="" loading="lazy" decoding="async">`:`<span class="camera-placeholder" aria-hidden="true">▷</span><span>${e.cameras.length} camera angles</span>`}<span class="duration">${timeLabel(e.duration)}</span></button><div class="clip-body"><button type="button" data-open="${esc(e.id)}">${esc(e.category)} recording</button><div class="clip-meta"><span>${esc(e.start.slice(11).replaceAll('-',':'))}</span><span>${esc(e.date)}</span></div><div class="clip-meta"><span>${e.cameras.length} cameras · ${e.segments.length} segment${e.segments.length===1?'':'s'}</span>${e.owned?'<span>Restored</span>':''}</div></div></article>`).join(''):`<div class="empty"><h2>${state.library?'No recordings found':'Recordings unavailable'}</h2><p>${state.library?'Try a different category, search, or day.':'Check your connection, then refresh.'}</p></div>`;
  for(const img of document.querySelectorAll('#clip-grid img'))img.onerror=()=>{img.remove();};
  $('#selection-count').textContent=state.selected.size?`${state.selected.size} selected on this page`:events.length?`${view.start}–${view.end} of ${view.total} recordings`:'0 recordings';$('#bulk-trash').hidden=!state.selected.size;$('#bulk-trash').disabled=!state.trashAvailable||state.inFlight;
  const eligible=shown.filter(e=>e.group!=='RecentClips');$('#select-all').disabled=!eligible.length||!state.trashAvailable;$('#select-all').checked=!!eligible.length&&eligible.every(e=>state.selected.has(e.id));$('#select-all').indeterminate=eligible.some(e=>state.selected.has(e.id))&&!$('#select-all').checked;
  $('#clip-pagination').hidden=view.pages<=1;$('#page-status').textContent=`Page ${view.page} of ${view.pages} · ${view.start}–${view.end} of ${view.total}`;
  $('#page-prev').disabled=view.page<=1;$('#page-next').disabled=view.page>=view.pages;
  const jump=$('#page-jump');if(jump.options.length!==view.pages){jump.replaceChildren();for(let n=1;n<=view.pages;n++)jump.add(new Option(String(n),String(n)));}jump.value=String(view.page);
  if(focused)document.querySelector(`[data-select="${CSS.escape(focused)}"]`)?.focus();
}
$('#clip-grid').onclick=e=>{const b=e.target.closest('[data-open]');if(!b||state.inFlight||state.speedTest)return;const event=state.events.find(x=>x.id===b.dataset.open);if(event){player.setEvent(event);renderGrid();$('#player').scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'start'});}};
$('#clip-grid').onchange=e=>{if(!e.target.dataset.select)return;if(e.target.checked)state.selected.add(e.target.dataset.select);else state.selected.delete(e.target.dataset.select);renderGrid();};
document.querySelectorAll('[data-category]').forEach(b=>b.onclick=()=>{state.category=b.dataset.category;state.clipPage=1;state.selected.clear();document.querySelectorAll('[data-category]').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));renderGrid();});
$('#recording-search').oninput=e=>{state.query=e.target.value;state.clipPage=1;state.selected.clear();renderGrid();};
$('#recording-hour').onchange=e=>{state.hour=e.target.value;state.clipPage=1;state.selected.clear();renderGrid();};
$('#select-all').onchange=e=>{for(const event of currentPage().items.filter(x=>x.group!=='RecentClips'))e.target.checked?state.selected.add(event.id):state.selected.delete(event.id);renderGrid();};
function changeClipPage(page){state.clipPage=page;state.selected.clear();renderGrid();$('#clip-grid').scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'start'});}
$('#page-prev').onclick=()=>changeClipPage(state.clipPage-1);$('#page-next').onclick=()=>changeClipPage(state.clipPage+1);$('#page-jump').onchange=e=>changeClipPage(Number(e.target.value));
$('#recording-day').onchange=e=>loadLibrary(e.target.value);$('#refresh-recordings').onclick=()=>loadLibrary(state.day);

function updateDayOptions(data){const select=$('#recording-day');select.replaceChildren(new Option(data.selected_day&&state.day==='latest'?'Latest · '+data.selected_day:'Latest available day','latest'));
  const days=[...new Set([...(Array.isArray(data.available_days)?data.available_days:[]),...(state.trash?.restored||[]).map(e=>e.event_time?.slice(0,10))])].filter(x=>/^\d{4}-\d{2}-\d{2}$/.test(x||'')).sort().reverse();for(const day of days)select.add(new Option(day,day));
  if(state.day!=='latest'&&!days.includes(state.day))select.add(new Option(state.day,state.day));select.value=state.day;}
async function loadLibrary(day='latest'){
  if(state.inFlight||state.speedTest){notice(state.speedTest?'Wait for the network test to finish before refreshing footage.':'A recording refresh is already running.');return;}
  state.inFlight=true;libraryAbort=new AbortController();const saved=player.suspend();updateClipNavigation();const previousDay=state.day;state.day=day;$('#refresh-recordings').disabled=true;$('#recording-day').disabled=true;$('#library-state').textContent='Refreshing the snapshot library…';
  try{
    const [libraryResult,trashResult]=await Promise.allSettled([api('/api/v1/videos?'+new URLSearchParams({day}),{signal:libraryAbort.signal}),api('/api/v1/trash',{signal:libraryAbort.signal})]);
    if(trashResult.status!=='fulfilled'){state.trashAvailable=false;throw new Error('Trash status is unavailable. The library cannot refresh until hidden recordings can be verified.');}
    let trash;try{trash=validTrash(trashResult.value);}catch(error){state.trashAvailable=false;throw error;}
    if(libraryResult.status!=='fulfilled')throw libraryResult.reason;
    const {data,events,selectedDay}=await resolveLibrary(libraryResult.value,trash,day,candidate=>api('/api/v1/videos?'+new URLSearchParams({day:candidate}),{signal:libraryAbort.signal}),candidate=>{$('#library-state').textContent='Checking available recordings for '+candidate+'…';});
    state.trash=trash;state.trashAvailable=true;$('#trash-count').textContent=trash.items.length||'';
    const changedDay=previousDay!==day||state.library?.selected_day!==data.selected_day;
    state.paths=data.videos;state.library=data;
    state.events=events;state.selected=new Set([...state.selected].filter(id=>events.some(e=>e.id===id)));
    if(changedDay){state.clipPage=1;state.hour='latest';state.selected.clear();}
    else if(state.category==='RecentClips'&&state.hour!=='all'&&!events.some(e=>e.group==='RecentClips'&&e.start.slice(11,13)===state.hour)){state.hour='latest';state.clipPage=1;}
    updateDayOptions(data);
    $('#fresh-recording').textContent=stampLabel(events[0]?.newest);$('#fresh-refresh').textContent=new Date().toLocaleTimeString();
    $('#library-state').textContent=`${events.length} recordings available${selectedDay?' · '+selectedDay:''}. Latest snapshots are delayed footage, not a live camera feed.`;
    const same=events.find(e=>e.id===saved.id),event=same||events[0];if(state.page==='recordings'&&!document.hidden){if(event)await player.setEvent(event,same?saved:{});else player.clear();}
    renderGrid();
  }catch(error){state.day=previousDay;$('#recording-day').value=previousDay;$('#library-state').textContent=`Refresh failed: ${error.message}${state.library?' Showing the previous list; it may be out of date.':''}`;if(state.page==='recordings'&&!document.hidden)player.resume();renderGrid();}
  finally{state.inFlight=false;updateClipNavigation();$('#refresh-recordings').disabled=false;$('#recording-day').disabled=false;refreshHealth();}
}

let healthInFlight=null;
function refreshHealth(force=false){if(healthInFlight)return healthInFlight;if(document.hidden||(!force&&state.speedTest)||hasPendingPowerAction())return Promise.resolve();healthInFlight=(async()=>{
  const [status,maintenance]=await Promise.allSettled([api('/api/v1/status'),api('/api/v1/maintenance')]);
  if(hasPendingPowerAction())return;
  if(status.status==='fulfilled'){const s=status.value.status||status.value;$('#connection-status').textContent='USB: '+String(s.camera_drive_state||'unknown');$('#storage-text').textContent=s.free_space!=null?bytesLabel(s.free_space)+' free':'Storage not reported';const alerts=[];
    if(s.encrypted_clips?.detected)alerts.push(s.encrypted_clips.message||'Encrypted recordings detected. Built-in processing is paused.');
    const temp=Number(s.cpu_temp);if(Number.isFinite(temp)&&(temp>1000?temp/1000:temp)>=68)alerts.push('Device temperature is high. Check Device for details.');
    $('#recording-alert').textContent=alerts.join(' ');$('#recording-alert').hidden=!alerts.length;
  }else $('#connection-status').textContent='USB: status unavailable';
  if(maintenance.status==='fulfilled'){const health=maintenance.value.health||{};const snapshot=health.snapshots;$('#fresh-snapshot').textContent=snapshot?.available===true&&snapshot.scan_complete===true&&snapshot.last_completed?.completed_at_utc?new Date(snapshot.last_completed.completed_at_utc).toLocaleString():'Not verified';}
  else $('#fresh-snapshot').textContent='Unavailable';
})().finally(()=>{healthInFlight=null;});return healthInFlight;}

let pendingMove=[];
function confirmMove(events){if(!state.trashAvailable){notice('Trash is unavailable. Refresh the library before deleting recordings.');return;}pendingMove=events.filter(e=>e&&e.group!=='RecentClips');if(!pendingMove.length)return;
  $('#move-copy').textContent=`Move ${pendingMove.length} recording${pendingMove.length===1?'':'s'} and all their camera angles to Trash?`;$('#move-progress').textContent='';$('#move-cancel').disabled=false;$('#move-confirm').disabled=false;$('#move-dialog').showModal();}
$('#bulk-trash').onclick=()=>confirmMove(state.events.filter(e=>state.selected.has(e.id)));
let moving=false;$('#move-dialog').addEventListener('cancel',e=>{if(moving)e.preventDefault();});
$('#move-confirm').onclick=async()=>{if(moving)return;moving=true;$('#move-confirm').disabled=true;$('#move-cancel').disabled=true;player.suspend();let moved=0,error=null,ids=[];
  try{for(const event of pendingMove){$('#move-progress').textContent=`Keeping a recovery copy: recording ${moved+1} of ${pendingMove.length}…`;const result=await api('/api/v1/trash/move',{method:'POST',body:{event:event.event},timeout:75000});moved++;const movedItem=result.items?.find(item=>item.event===event.event);if(movedItem?.id)ids.push(movedItem.id);}}
  catch(e){error=e;}
  finally{moving=false;$('#move-dialog').close();state.selected.clear();await loadLibrary(state.day);if(error)notice(`${moved} recordings moved. ${error.message} Refresh Trash to verify the result before retrying.`);else notice(`${moved} recordings moved to Trash. Restore them there within 30 days.`,ids.length?{label:'Undo',run:async()=>{const button=$('#notice-action');button.disabled=true;try{for(let i=0;i<ids.length;i+=20)await api('/api/v1/trash/restore',{method:'POST',body:{ids:ids.slice(i,i+20)}});await loadLibrary(state.day);notice('Recordings restored.');}catch(e){notice('Restore could not finish: '+e.message+' Open Trash to check the result.');}finally{button.disabled=false;}}}:null);}
};

const downloadTasks=new Set();
async function prepareDownload(event,camera){
  if(!event)return;if(downloadTasks.size>=6){notice('Dismiss a finished download before preparing another.');return;}
  const row=document.createElement('div');row.className='download-row';row.innerHTML='<div class="download-copy"><strong></strong><p role="status" aria-live="polite"></p><progress aria-label="Preparing download"></progress></div><button type="button" class="cancel-download">Cancel</button>';
  row.querySelector('strong').textContent=`${event.category} · ${stampLabel(event.start)} · ${camera==='all'?'All cameras':CAMERAS[camera]}`;
  $('#download-list').append(row);$('#downloads').hidden=false;const task={row,controller:null};downloadTasks.add(task);
  const remove=()=>{task.controller?.abort();downloadTasks.delete(task);row.remove();$('#downloads').hidden=!downloadTasks.size;};row.querySelector('.cancel-download').onclick=remove;
  async function prepare(){
    task.controller=new AbortController();row.classList.remove('error');row.querySelector('p').textContent='Preparing original files and checking size…';row.querySelector('progress').hidden=false;row.querySelectorAll('.retry-download,.save-download').forEach(n=>n.remove());
    const paused=player.snapshot();if(state.page==='recordings')player.suspend();
    try{const params=downloadQuery(event,camera);params.set('info','1');const info=await api('/api/v1/recordings/download?'+params,{signal:task.controller.signal,timeout:60000});
      if(!downloadTasks.has(task))return;if(!info.download_url?.startsWith('/api/v1/recordings/download?')||typeof info.filename!=='string')throw new Error('The device returned an invalid download.');
      row.querySelector('p').textContent=`Ready · ${bytesLabel(info.total_bytes)} · ${info.files?.length||1} original file(s) · ${String(info.format||'file').toUpperCase()}`;
      const link=document.createElement('a');link.className='button primary save-download';link.href=info.download_url;link.download=info.filename;link.textContent='Save '+String(info.format||'file').toUpperCase();row.insertBefore(link,row.querySelector('.cancel-download'));
      link.onclick=()=>{row.querySelector('p').textContent='Handed to your browser. View progress, pause, or cancel in your browser’s Downloads. Completion is not verified here.';row.querySelector('.cancel-download').textContent='Dismiss';};
    }catch(e){if(!downloadTasks.has(task))return;row.classList.add('error');row.querySelector('p').textContent=e.message;const retry=document.createElement('button');retry.type='button';retry.className='retry-download';retry.textContent='Retry';retry.onclick=prepare;row.insertBefore(retry,row.querySelector('.cancel-download'));}
    finally{if(downloadTasks.has(task))row.querySelector('progress').hidden=true;if(state.page==='recordings'&&!document.hidden&&!state.inFlight&&!state.speedTest&&player.event?.id===paused.id)player.resume();}
  }
  await prepare();row.scrollIntoView({block:'nearest'});
}

window.addEventListener('teslausb:pause-media',()=>player.suspend());
window.addEventListener('teslausb:power-state',()=>{connection.setPaused();updateClipNavigation();});
window.addEventListener('teslausb:speed-test',e=>{state.speedTest=e.detail?.active===true;$('#refresh-recordings').disabled=state.speedTest||state.inFlight;$('#recording-day').disabled=state.speedTest||state.inFlight;if(state.speedTest)player.suspend();else if(state.page==='recordings'&&!document.hidden&&!state.inFlight)player.resume();updateClipNavigation();});
document.addEventListener('visibilitychange',()=>{if(document.hidden){player.suspend();libraryAbort?.abort();}else if(state.page==='recordings'&&!state.inFlight&&!state.speedTest)player.resume();});
window.addEventListener('pagehide',event=>{clearInterval(healthTimer);if(!event.persisted)connection.destroy();player.suspend();device?.destroy();device=null;files?.destroy();files=null;trashView?.destroy();trashView=null;libraryAbort?.abort();for(const t of downloadTasks)t.controller?.abort();});
window.addEventListener('pageshow',e=>{if(!e.persisted)return;if(state.page==='recordings')player.resume();else if(state.page==='device')device=mountDevice($('#device-page'),{api,onNotice:notice});else if(state.page==='files')files=mountFiles($('#files-page'),{api,onNotice:notice,config:state.config});else trashView=mountTrash($('#trash-page'),{api,onNotice:notice,onLibraryChanged:()=>loadLibrary(state.day)});startHealthTimer();});

function startHealthTimer(){clearInterval(healthTimer);healthTimer=setInterval(()=>{if(!player.playing&&!state.inFlight)refreshHealth();},60000);}

async function boot(){
  try{state.config=await api('/api/v1/config');const data=state.config.config||state.config;state.config=data;document.querySelector('[data-page="files"]').hidden=!configuredFileDrives(data).length;if(data.fixture_mode)notice('Local test fixtures — no connection to your Pi and no real files are modified.');}catch(e){notice('Device configuration is unavailable: '+e.message);}
  await loadLibrary('latest');startHealthTimer();
}
boot();
