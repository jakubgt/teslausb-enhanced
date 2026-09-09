// A thumbnail status check and its JPEG delivery share the recording-store lock.
// Keep the complete transaction serial, with viewer requests ahead of grid work.
const pending=[];
let active=false;
const aborted=()=>new DOMException('Thumbnail request cancelled.','AbortError');
function drain(){
  if(active)return;
  pending.sort((a,b)=>b.priority-a.priority);
  const item=pending.shift();if(!item)return;
  item.started=true;item.signal?.removeEventListener('abort',item.cancel);
  if(item.signal?.aborted){item.reject(aborted());queueMicrotask(drain);return;}
  active=true;
  Promise.resolve().then(item.task).then(item.resolve,item.reject).finally(()=>{
    const release=()=>{active=false;drain();};
    // Removing an image src / aborting fetch settles locally before the old
    // HTTP connection closes at the Pi. Keep the queue occupied briefly so a
    // layout switch cannot immediately race that cancelled recording read.
    if(item.signal?.aborted)setTimeout(release,100);else release();
  });
}
export function queueThumbnailRequest(task,{signal,priority=0}={}){
  if(signal?.aborted)return Promise.reject(aborted());
  return new Promise((resolve,reject)=>{
    const item={task,signal,priority,resolve,reject,started:false};
    item.cancel=()=>{if(item.started)return;const index=pending.indexOf(item);if(index>=0)pending.splice(index,1);signal.removeEventListener('abort',item.cancel);reject(aborted());};
    signal?.addEventListener('abort',item.cancel,{once:true});pending.push(item);queueMicrotask(drain);
  });
}

function wait(ms,signal){return new Promise((resolve,reject)=>{
  if(signal.aborted){reject(aborted());return;}
  const cancel=()=>{clearTimeout(timer);reject(aborted());};
  const timer=setTimeout(()=>{signal.removeEventListener('abort',cancel);resolve();},ms);
  signal.addEventListener('abort',cancel,{once:true});
});}
function loadImage(button,url,alt,signal){return new Promise((resolve,reject)=>{
  if(signal.aborted){reject(aborted());return;}
  const image=document.createElement('img');image.alt=alt;image.decoding='async';
  let timer,settled=false;
  const finish=error=>{if(settled)return;settled=true;clearTimeout(timer);signal.removeEventListener('abort',cancel);image.onload=null;image.onerror=null;
    if(error){image.removeAttribute('src');image.remove();reject(error);}else resolve(image);};
  const cancel=()=>finish(aborted());image.onload=()=>finish();image.onerror=()=>finish(new Error('Thumbnail delivery failed.'));
  signal.addEventListener('abort',cancel,{once:true});timer=setTimeout(()=>finish(new Error('Thumbnail delivery timed out.')),15000);
  button.prepend(image);image.src=url;
});}

// Only the first recorded minute is represented. A later camera frame would
// imply that the beginning of a clip contains footage which is actually absent.
export function cardThumbnailSource(event){
  const front=event.segments?.[0]?.files?.front;
  if(front&&!event.owned)return {path:front.path,alt:'Front camera near the start of this recording'};
  if(event.thumb)return {url:event.thumb,alt:'Recording thumbnail'};
  return null;
}

export function mountCardThumbnails(grid,events,{api,signal}={}){
  const controllers=new Set(),items=new Map();let stopped=false;
  for(const event of events){
    const button=grid.querySelector(`.clip-image[data-open="${CSS.escape(event.id)}"]`),source=cardThumbnailSource(event);
    const image=button?.querySelector('img');
    if(button&&source)items.set(button,{button,source,done:!!(image?.complete&&image.naturalWidth),controller:null});
  }
  const showFallback=item=>{item.button.querySelector('.clip-thumbnail-note').textContent='Still unavailable';};
  const start=async item=>{
    if(stopped||item.done||item.controller)return;
    const controller=new AbortController(),local=controller.signal;item.controller=controller;controllers.add(controller);
    const started=Date.now();let failures=0;
    try{
      // Avoid generating stills for cards passed briefly while scrolling.
      await wait(175,local);
      while(!local.aborted&&Date.now()-started<120000){
        try{
          const outcome=await queueThumbnailRequest(async()=>{
            let url=item.source.url;
            if(item.source.path){
              const route='/api/v1/recordings/thumbnail?'+new URLSearchParams({path:item.source.path});
              let result=await api(route,{signal:local});
              if(result.state==='not_requested')result=await api(route,{method:'POST',signal:local});
              if(result.state==='preparing'||result.reason==='preview_worker_busy')return 'pending';
              if(result.state!=='ready'||typeof result.thumbnail_url!=='string'||!result.thumbnail_url.startsWith('/api/v1/recordings/thumbnail/media?'))return 'unavailable';
              url=result.thumbnail_url;
            }
            const image=await loadImage(item.button,url,item.source.alt,local);
            if(local.aborted){image.removeAttribute('src');image.remove();throw aborted();}
            item.button.classList.add('has-thumbnail');item.button.querySelector('.clip-thumbnail-note').textContent=item.source.path?'Front camera':'Recording thumbnail';
            return 'ready';
          },{signal:local});
          if(outcome!=='pending'){item.done=true;if(outcome!=='ready')showFallback(item);return;}
        }catch(error){if(local.aborted)throw error;if(++failures>=3){item.done=true;showFallback(item);return;}}
        await wait(5000,local);
      }
      if(!local.aborted){item.done=true;showFallback(item);}
    }catch{/* Leaving a card, page, or tab cancels its pending work. */}
    finally{controllers.delete(controller);if(item.controller===controller)item.controller=null;}
  };
  const observer=new IntersectionObserver(entries=>{
    for(const entry of entries){const item=items.get(entry.target);if(!item)continue;
      if(entry.isIntersecting&&entry.intersectionRatio>0)void start(item);else{item.controller?.abort();item.controller=null;}}
  },{threshold:.05});
  const stop=()=>{if(stopped)return;stopped=true;observer.disconnect();for(const controller of controllers)controller.abort();controllers.clear();signal?.removeEventListener('abort',stop);};
  if(signal?.aborted)stop();else{signal?.addEventListener('abort',stop,{once:true});for(const button of items.keys())observer.observe(button);}
  return stop;
}
