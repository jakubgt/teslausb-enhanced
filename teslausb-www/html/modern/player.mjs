import {CAMERAS,escapeHTML as esc,timeLabel,stampLabel,eventMarker,validLocation} from './model.mjs';

export class ClipPlayer {
  constructor(container,{api,onDownload,onTrash,onNotice}) {
    Object.assign(this,{container,api,onDownload,onTrash,onNotice});
    this.event=null;this.position=0;this.camera='front';this.mode='single';this.quality='low';this.rate=1;this.playing=false;this.suspended=false;this.generation=0;this.playIntent=0;this.videoIntent=new WeakMap();this.marker=null;this.metadata=null;this.videos=[];
    container.innerHTML=`<section class="player" aria-label="Recording viewer"><div class="player-empty">Select a recording to view its camera angles.</div><div class="player-content" hidden>
      <div class="player-header"><div><h2 data-title>Latest available recording</h2><p data-capture></p></div><div class="player-options"><div class="mode-group" role="group" aria-label="Camera layout"><button type="button" data-mode="single" aria-pressed="true">Single camera</button><button type="button" data-mode="all" aria-pressed="false">All cameras</button></div><label>Quality <select data-quality><option value="low">Low · less data</option><option value="high">High · original</option></select></label></div></div>
      <div class="quality-status" role="status" aria-live="polite"><span data-quality-status>Checking low preview availability…</span><button type="button" data-preview-retry hidden>Check preview</button><button type="button" data-use-original hidden>Play original</button></div>
      <div class="video-grid"></div><div class="player-error" role="status" aria-live="polite" hidden></div>
      <div class="player-controls"><button type="button" data-play aria-label="Play recording">Play</button><button type="button" data-back aria-label="Skip back 10 seconds">−10s</button><button type="button" data-forward aria-label="Skip forward 30 seconds">+30s</button><button type="button" data-jump disabled>Jump to event</button><span class="timecode" data-time>0:00 / 0:00</span><select data-rate aria-label="Playback speed"><option value="0.5">0.5×</option><option value="1" selected>1×</option><option value="2">2×</option><option value="4">4×</option></select><button type="button" data-fullscreen>Fullscreen</button></div>
      <div class="timeline-wrap"><input type="range" data-position aria-label="Playback position in seconds" min="0" max="60" step="0.1" value="0"><span class="event-tick" hidden aria-hidden="true"></span></div>
      <div class="camera-buttons" role="group" aria-label="Focused camera"></div>
      <details class="clip-details"><summary>Clip details &amp; location</summary><div class="details-content"></div></details>
      <div class="player-footer"><span>Downloads keep original quality</span><button type="button" data-download-camera>Download Front</button><button type="button" data-download-all class="primary">Download all cameras</button><button type="button" data-trash class="danger-text">Move to Trash</button></div>
    </div></section>`;
    this.q=s=>container.querySelector(s);
    this.q('[data-play]').onclick=()=>this.toggle();this.q('[data-back]').onclick=()=>this.seek(this.position-10);this.q('[data-forward]').onclick=()=>this.seek(this.position+30);
    this.q('[data-position]').oninput=e=>this.seek(Number(e.target.value));this.q('[data-rate]').onchange=e=>{this.rate=Number(e.target.value);this.videos.forEach(v=>v.playbackRate=this.rate);};
    this.q('[data-jump]').onclick=()=>{if(this.marker!==null)this.seek(this.marker);};
    container.querySelectorAll('[data-mode]').forEach(b=>b.onclick=()=>{if(this.mode===b.dataset.mode)return;this.capturePosition();this.mode=b.dataset.mode;this.loadSegment();this.renderSelection();});
    this.q('[data-quality]').onchange=e=>{this.capturePosition();this.quality=e.target.value;this.loadSegment();};
    this.q('[data-use-original]').onclick=()=>{this.capturePosition();this.quality='high';this.q('[data-quality]').value='high';this.playing=true;this.loadSegment();};
    this.q('[data-preview-retry]').onclick=()=>{this.capturePosition();this.loadSegment({retryFailed:true});};
    this.q('[data-fullscreen]').onclick=async()=>{try{if(document.fullscreenElement)await document.exitFullscreen();else if(this.q('.player').requestFullscreen)await this.q('.player').requestFullscreen();else this.onNotice('Fullscreen is not supported by this browser.');}catch(e){this.onNotice('Could not enter fullscreen: '+e.message);}};
    this.q('[data-download-camera]').onclick=()=>this.onDownload(this.event,this.camera);this.q('[data-download-all]').onclick=()=>this.onDownload(this.event,'all');this.q('[data-trash]').onclick=()=>this.onTrash([this.event]);
    this.visibilityHandler=()=>{if(document.hidden)this.suspend();};
    document.addEventListener('visibilitychange',this.visibilityHandler);
  }
  snapshot(){this.capturePosition();return {id:this.event?.id,position:this.position,camera:this.camera,mode:this.mode,quality:this.quality,rate:this.rate,playing:this.playing};}
  capturePosition(){if(this.master?.readyState>=1 && Number.isFinite(this.master.currentTime))this.position=this.segmentIndex*60+this.master.currentTime;}
  async setEvent(event,restore={}) {
    if(!event){this.clear();return;}
    this.generation++;this.playIntent++;this.releaseMedia();this.metadataAbort?.abort();this.metadata=null;this.marker=null;
    this.event=event;this.position=Math.min(Math.max(0,restore.position||0),Math.max(0,event.duration-.1));this.camera=event.cameras.includes(restore.camera||this.camera)?(restore.camera||this.camera):event.cameras[0];
    this.mode=restore.mode||this.mode;this.quality=restore.quality||'low';this.rate=restore.rate||this.rate;this.playing=restore.playing||false;this.suspended=restore.suspended===true||document.hidden;
    this.q('.player-empty').hidden=true;this.q('.player-content').hidden=false;this.q('[data-quality]').value=this.quality;this.q('[data-rate]').value=String(this.rate);
    this.q('[data-title]').textContent=`${event.category} recording`;this.q('[data-capture]').textContent=stampLabel(event.start)+' · Snapshot footage';this.q('[data-position]').max=String(event.duration-.1);
    this.q('[data-trash]').hidden=event.group==='RecentClips';this.q('[data-jump]').disabled=true;
    this.q('.camera-buttons').innerHTML=event.cameras.map(c=>`<button type="button" data-camera="${c}" aria-pressed="${c===this.camera}">${esc(CAMERAS[c])}</button>`).join('');
    this.container.querySelectorAll('[data-camera]').forEach(b=>b.onclick=()=>{this.capturePosition();this.camera=b.dataset.camera;this.loadSegment();this.renderSelection();});
    this.q('.video-grid').replaceChildren();this.renderSelection();this.renderDetails();this.renderMarker();this.updateControls();this.loadSegment();
    if(this.suspended)this.q('[data-quality-status]').textContent='Playback is paused.';
    await this.loadMetadata(event);
  }
  async loadMetadata(event){
    if(!event?.metadata||this.suspended||document.hidden)return;
    this.metadataAbort?.abort();this.metadataAbort=new AbortController();const signal=this.metadataAbort.signal;
    const timeout=setTimeout(()=>this.metadataAbort?.signal===signal&&this.metadataAbort.abort(),15000);
    try{
      const response=await fetch(event.metadata,{cache:'no-store',signal,credentials:'same-origin'});if(!response.ok)throw new Error('Metadata unavailable');
      let text='';const reader=response.body?.getReader();
      if(reader){const decoder=new TextDecoder();let bytes=0;try{while(true){const {done,value}=await reader.read();if(done)break;bytes+=value.byteLength;if(bytes>131072){await reader.cancel();throw new Error('Metadata too large');}text+=decoder.decode(value,{stream:true});}text+=decoder.decode();}finally{reader.releaseLock();}}
      else{text=await response.text();if(text.length>131072)throw new Error('Metadata too large');}
      const data=JSON.parse(text);if(this.event!==event||signal.aborted||this.suspended||document.hidden)return;
      this.metadata=data;this.marker=eventMarker(event,data);this.q('[data-jump]').disabled=this.marker===null;this.renderDetails();this.renderMarker();
    }catch(e){if(!signal.aborted&&this.event===event)this.renderDetails();}finally{clearTimeout(timeout);}
  }
  renderSelection(){this.container.querySelectorAll('[data-camera]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.camera===this.camera)));this.container.querySelectorAll('[data-mode]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.mode===this.mode)));this.q('[data-download-camera]').textContent='Download '+CAMERAS[this.camera];this.q('.video-grid').classList.toggle('all',this.mode==='all');}
  renderMarker(){const marker=this.q('.event-tick');marker.hidden=this.marker===null;if(this.marker!==null)marker.style.left=`calc(18px + (100% - 36px) * ${this.marker/this.event.duration})`;}
  renderDetails(){
    const e=this.event,meta=this.metadata,location=validLocation(meta);
    const details=this.q('.details-content');details.replaceChildren();
    const dl=document.createElement('dl');dl.innerHTML=`<dt>Recorded</dt><dd>${esc(stampLabel(e.start))}</dd><dt>Available cameras</dt><dd>${esc(e.cameras.map(c=>CAMERAS[c]).join(', '))}</dd><dt>Duration</dt><dd>About ${timeLabel(e.duration)} · ${e.segments.length} segment${e.segments.length===1?'':'s'}</dd><dt>Event timestamp</dt><dd>${esc(meta?.timestamp||'Not provided')}</dd><dt>Download size</dt><dd>Calculated when preparing your download</dd>`;details.append(dl);
    const extra=document.createElement('div');extra.innerHTML=`<dl><dt>Location</dt><dd>${esc(meta?.city||'Not provided')}</dd><dt>Source</dt><dd>${e.owned?'Restored recording copy':'Completed snapshot'} · ${esc(e.category)}</dd></dl><p>Camera timestamps have no timezone. Event navigation is available when metadata matches a recorded segment.</p>`;details.append(extra);
    if(location){const map=document.createElement('div');map.className='map-content';const load=document.createElement('button');load.type='button';load.textContent='Load location map';const hint=document.createElement('p');hint.textContent='Opens map data from OpenStreetMap using this event’s location.';hint.className='small';map.append(load,hint);details.append(map);load.onclick=()=>{const {lat,lon}=location;const frame=document.createElement('iframe');frame.title='Recording location map';frame.loading='lazy';frame.referrerPolicy='no-referrer';const params=new URLSearchParams({bbox:[Math.max(-180,lon-.004),Math.max(-90,lat-.004),Math.min(180,lon+.004),Math.min(90,lat+.004)].join(','),layer:'mapnik',marker:lat+','+lon});frame.src='https://www.openstreetmap.org/export/embed.html?'+params;map.replaceChildren(frame);};}
  }
  pauseVideo(video){this.videoIntent.set(video,(this.videoIntent.get(video)||0)+1);video.pause();}
  releaseMedia(){this.loadAbort?.abort();clearTimeout(this.previewTimer);for(const video of this.videos){this.pauseVideo(video);video.removeAttribute('src');video.load();}this.videos=[];this.master=null;this.buffering=false;}
  stopPlayback(message){this.playing=false;this.playIntent++;this.videos.forEach(video=>this.pauseVideo(video));this.updateControls();if(message)this.onNotice(message);}
  async playVideo(video,generation,intent=this.playIntent){
    if(generation!==this.generation||intent!==this.playIntent||!this.playing||this.suspended||document.hidden||(this.buffering&&video!==this.master))return;
    const revision=(this.videoIntent.get(video)||0)+1;this.videoIntent.set(video,revision);
    try{await video.play();if(generation!==this.generation||!this.playing||this.suspended||document.hidden)this.pauseVideo(video);}
    catch{if(generation===this.generation&&intent===this.playIntent&&revision===this.videoIntent.get(video)&&this.playing&&!this.suspended&&!document.hidden)this.stopPlayback('Playback could not start. Try a single camera or refresh the recording.');}
  }
  async fetchPreview(path,signal,retryFailed=false){
    const route='/api/v1/recordings/preview?'+new URLSearchParams({path});let preview=await this.api(route,{signal});
    if(preview.state==='not_requested'||(retryFailed&&preview.state==='failed'))preview=await this.api(route,{method:'POST',signal});
    return {...preview,retryFailed:retryFailed&&preview.reason==='preview_worker_busy'};
  }
  previewPending(result){return result.state==='preparing'||result.reason==='preview_worker_busy';}
  schedulePreviews(generation,pending){
    clearTimeout(this.previewTimer);if(!pending.length)return;
    this.previewTimer=setTimeout(async()=>{
      if(generation!==this.generation||this.suspended||document.hidden)return;
      try{
        const next=[];let changed=false;
        for(const item of pending){const preview=await this.fetchPreview(item.path,this.loadAbort.signal,item.retryFailed);if(generation!==this.generation||this.suspended||document.hidden)return;const value={...preview,path:item.path};if(preview.state!==item.state||preview.reason!==item.reason)changed=true;if(this.previewPending(value))next.push(value);}
        if(changed){this.capturePosition();this.loadSegment({retryPaths:new Set(next.filter(item=>item.retryFailed).map(item=>item.path))});}else this.schedulePreviews(generation,next);
      }catch{if(generation!==this.generation||this.suspended||document.hidden)return;this.q('[data-quality-status]').textContent='Could not check the Low preview. Check again or play the original.';this.q('[data-preview-retry]').hidden=false;}
    },5000);
  }
  async loadSegment({retryFailed=false,retryPaths=new Set()}={}){
    if(!this.event||this.suspended||document.hidden)return;const generation=++this.generation;this.releaseMedia();this.loadAbort=new AbortController();const signal=this.loadAbort.signal;
    const event=this.event;this.segmentIndex=Math.min(event.segments.length-1,Math.floor(this.position/60));const segment=event.segments[this.segmentIndex];
    const cameras=this.mode==='all'?event.cameras:[this.camera];const grid=this.q('.video-grid');grid.replaceChildren();this.q('.player-error').hidden=true;
    this.q('[data-quality-status]').textContent=this.quality==='low'?'Checking smaller previews…':'Playing original-quality camera files.';this.q('[data-preview-retry]').hidden=true;this.q('[data-use-original]').hidden=this.quality!=='low';
    const results=[];
    for(const camera of cameras){
      const cell=document.createElement('div');cell.className='video-cell';const label=document.createElement('span');label.className='video-label';label.textContent=CAMERAS[camera];const placeholder=document.createElement('div');placeholder.className='video-error';placeholder.textContent='Loading…';cell.append(placeholder,label);grid.append(cell);
      const file=segment.files[camera];if(!file){placeholder.textContent='This camera is missing for this segment.';results.push({state:'missing'});continue;}
      let source=file.url,state='ready';
      if(this.quality==='low'){
        if(event.owned){placeholder.textContent='Low preview unavailable for this restored copy.';results.push({state:'unavailable'});continue;}
        try{const preview=await this.fetchPreview(file.path,signal,retryFailed||retryPaths.has(file.path));if(generation!==this.generation||this.suspended||document.hidden)return;state=preview.state;
          if(state==='ready' && typeof preview.preview_url==='string' && preview.preview_url.startsWith('/api/v1/recordings/preview/media?'))source=preview.preview_url;
          else{placeholder.textContent=state==='preparing'?'Smaller preview is preparing.':preview.reason==='preview_worker_busy'?'Another smaller preview is preparing. This camera will be checked shortly.':'Low preview is unavailable. Check again or choose High to play the original.';results.push({...preview,state:state==='ready'?'unavailable':state,path:file.path});continue;}
        }catch(error){if(signal.aborted)return;placeholder.textContent='Low preview unavailable. Choose High to play the original.';results.push({state:'unavailable'});continue;}
      }
      if(generation!==this.generation||this.suspended||document.hidden)return;
      const video=document.createElement('video');video.muted=true;video.playsInline=true;video.preload='metadata';video.disableRemotePlayback=true;video.setAttribute('aria-label',CAMERAS[camera]+' recording');video.playbackRate=this.rate;video.src=source;cell.insertBefore(video,label);this.videos.push(video);results.push({state:'ready'});
      if(!this.master || camera===this.camera)this.master=video;
      video.addEventListener('loadedmetadata',()=>{if(generation!==this.generation||this.suspended||document.hidden)return;const offset=this.position-this.segmentIndex*60;try{video.currentTime=Math.min(offset,Number.isFinite(video.duration)?Math.max(0,video.duration-.02):offset);}catch{};placeholder.hidden=true;if(this.playing)this.playVideo(video,generation);});
      video.addEventListener('error',()=>{if(generation!==this.generation)return;placeholder.textContent='This segment could not be loaded. Refresh the library or try another camera.';placeholder.hidden=false;if(video===this.master)this.stopPlayback();});
      video.addEventListener('waiting',()=>{if(generation===this.generation&&video===this.master&&this.playing&&!this.suspended&&!document.hidden){this.buffering=true;this.videos.filter(v=>v!==video).forEach(v=>this.pauseVideo(v));this.q('.player-error').textContent='Buffering… Try Low quality or Single camera on a slower connection.';this.q('.player-error').hidden=false;}});
      video.addEventListener('playing',()=>{if(generation!==this.generation||video!==this.master||this.suspended||document.hidden)return;this.q('.player-error').hidden=true;if(this.buffering){this.buffering=false;for(const v of this.videos)if(v!==video&&v.readyState>=1){try{v.currentTime=video.currentTime;}catch{}if(this.playing)this.playVideo(v,generation);}}});
      video.addEventListener('timeupdate',()=>{if(generation!==this.generation||video!==this.master||this.suspended||document.hidden)return;this.position=this.segmentIndex*60+video.currentTime;for(const v of this.videos)if(v!==video&&v.readyState>=2&&Math.abs(v.currentTime-video.currentTime)>.45){try{v.currentTime=video.currentTime;}catch{}}this.updateControls();});
      video.addEventListener('ended',()=>{if(generation!==this.generation||video!==this.master||this.suspended||document.hidden)return;if(this.segmentIndex+1<event.segments.length){this.position=(this.segmentIndex+1)*60;this.loadSegment();}else this.stopPlayback();});
    }
    if(generation!==this.generation)return;
    if(this.quality==='low'){const ready=results.filter(r=>r.state==='ready').length,pending=results.filter(r=>this.previewPending(r));this.q('[data-quality-status]').textContent=ready===cameras.length?'Low preview · Original downloads remain unchanged.':pending.length?'Smaller preview is preparing. You can play the original now.':ready?`${ready} of ${cameras.length} low previews available. High quality plays the originals.`:'Low preview is unavailable. Play the original to continue.';this.q('[data-preview-retry]').hidden=ready===cameras.length;this.q('[data-use-original]').hidden=ready===cameras.length;
      this.schedulePreviews(generation,pending);
    }
    this.updateControls();
  }
  updateControls(){if(!this.event)return;this.q('[data-position]').value=String(Math.min(this.position,this.event.duration-.1));this.q('[data-time]').textContent=timeLabel(this.position)+' / '+timeLabel(this.event.duration);this.q('[data-play]').textContent=this.playing?'Pause':'Play';this.q('[data-play]').setAttribute('aria-label',this.playing?'Pause recording':'Play recording');this.q('[data-play]').disabled=!this.master&&!this.playing;}
  seek(position){if(!this.event)return;position=Math.max(0,Math.min(this.event.duration-.1,position));const nextIndex=Math.floor(position/60);this.position=position;if(nextIndex!==this.segmentIndex||!this.master){this.loadSegment();}else{for(const v of this.videos){try{v.currentTime=position-nextIndex*60;}catch{}}}this.updateControls();}
  async toggle(){if(this.suspended||document.hidden)return;if(this.playing){this.stopPlayback();return;}if(!this.master)return;this.playing=true;const generation=this.generation,intent=++this.playIntent;this.updateControls();await Promise.all(this.videos.map(video=>this.playVideo(video,generation,intent)));if(generation===this.generation)this.updateControls();}
  suspend(){const state=this.snapshot();this.suspended=true;this.generation++;this.releaseMedia();this.metadataAbort?.abort();return state;}
  resume(){if(!this.event||document.hidden)return;this.suspended=false;this.loadSegment();if(!this.metadata)this.loadMetadata(this.event);}
  clear(){this.generation++;this.releaseMedia();this.metadataAbort?.abort();this.event=null;this.playing=false;this.position=0;this.q('.player-empty').hidden=false;this.q('.player-content').hidden=true;}
  destroy(){document.removeEventListener('visibilitychange',this.visibilityHandler);this.clear();this.container.replaceChildren();}
}
