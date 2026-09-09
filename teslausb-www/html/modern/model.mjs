export const CAMERAS = {
  front: 'Front', back: 'Rear', left_repeater: 'Left repeater',
  right_repeater: 'Right repeater', left_pillar: 'Left pillar', right_pillar: 'Right pillar',
};
export const GROUPS = { SentryClips: 'Sentry', SavedClips: 'Saved', RecentClips: 'Recent' };
const stampPattern = '\\d{4}-\\d{2}-\\d{2}_\\d{2}-\\d{2}-\\d{2}';
const videoPattern = new RegExp(`^(RecentClips|SavedClips|SentryClips)/(\\d{4}-\\d{2}-\\d{2}(?:_\\d{2}-\\d{2}-\\d{2})?)/(${stampPattern})-(front|back|left_repeater|right_repeater|left_pillar|right_pillar)\\.mp4$`);
export function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
export function mediaURL(path) { return '/TeslaCam/' + path.split('/').map(encodeURIComponent).join('/'); }
export function parseVideoPath(path) {
  if (typeof path !== 'string' || path.length > 240) return null;
  const m = videoPattern.exec(path);
  if (!m || !Number.isFinite(stampMillis(m[3])) || !Number.isFinite(stampMillis(m[2].length===10?m[2]+'_00-00-00':m[2])) || (m[1]==='RecentClips'?m[2].length!==10:m[2].length!==19)) return null;
  return { group:m[1], sequence:m[2], stamp:m[3], camera:m[4], path };
}
export function stampMillis(stamp) {
  const m = /^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})$/.exec(stamp || '');
  if (!m) return NaN;
  const parts=m.slice(1).map(Number), d=new Date(Date.UTC(parts[0],parts[1]-1,parts[2],parts[3],parts[4],parts[5]));
  if (d.getUTCFullYear()!==parts[0] || d.getUTCMonth()!==parts[1]-1 || d.getUTCDate()!==parts[2] || d.getUTCHours()!==parts[3] || d.getUTCMinutes()!==parts[4] || d.getUTCSeconds()!==parts[5]) return NaN;
  return d.getTime();
}
export function stampLabel(stamp) {
  if (!stamp) return 'Not reported';
  const m = /^(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})/.exec(stamp);
  return m ? `${m[1]} · ${m[2]}:${m[3]}:${m[4]}` : String(stamp);
}
export function timeLabel(seconds) {
  seconds = Math.max(0, Math.floor(Number(seconds) || 0));
  const h=Math.floor(seconds/3600), m=Math.floor(seconds%3600/60), s=String(seconds%60).padStart(2,'0');
  return h ? `${h}:${String(m).padStart(2,'0')}:${s}` : `${m}:${s}`;
}
export function bytesLabel(bytes) {
  if (!Number.isFinite(Number(bytes)) || bytes === null) return 'Size unknown';
  const n=Number(bytes); if(n<1024)return `${n} B`; if(n<1024**2)return `${(n/1024).toFixed(1)} KiB`;
  if(n<1024**3)return `${(n/1024**2).toFixed(1)} MiB`; return `${(n/1024**3).toFixed(2)} GiB`;
}
export function buildEvents(paths, trash = {}) {
  const hidden = new Set(Array.isArray(trash.hidden_media) ? trash.hidden_media : []);
  const tombstones=new Set(Array.isArray(trash.tombstones)?trash.tombstones:[]), events=new Map();
  function add(parsed, url, owned=null) {
    const key=parsed.group+'/'+parsed.sequence+(parsed.group==='RecentClips'?'#'+parsed.stamp:'');
    if(!events.has(key))events.set(key,{id:key, event:parsed.group+'/'+parsed.sequence, group:parsed.group, category:GROUPS[parsed.group], sequence:parsed.sequence, segments:[], metadata:null, thumb:null, owned});
    const event=events.get(key); let segment=event.segments.find(s=>s.stamp===parsed.stamp);
    if(!segment){segment={stamp:parsed.stamp,files:{}};event.segments.push(segment);}
    segment.files[parsed.camera]={path:parsed.path,url};
  }
  for(const path of paths){
    const p=parseVideoPath(path); if(!p || tombstones.has(p.group+'/'+p.sequence) || hidden.has(path.split('/').pop()))continue;
    add(p,mediaURL(path));
  }
  for(const overlay of Array.isArray(trash.restored)?trash.restored:[]){
    if(!overlay || !Array.isArray(overlay.files) || !/^(SavedClips|SentryClips)\/\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$/.test(overlay.event||''))continue;
    for(const file of overlay.files){if(!file)continue;const p=parseVideoPath(overlay.event+'/'+file.name);if(p && typeof file.media_url==='string' && file.media_url.startsWith('/api/v1/trash/media?'))add(p,file.media_url,overlay.id);}
    const e=events.get(overlay.event);
    if(e){const safeFiles=overlay.files.filter(f=>typeof f?.media_url==='string'&&f.media_url.startsWith('/api/v1/trash/media?'));const meta=safeFiles.find(f=>f.name==='event.json');if(meta)e.metadata=meta.media_url;const thumb=safeFiles.find(f=>/^thumb[^/]*\.(jpg|jpeg|png)$/.test(f.name));if(thumb)e.thumb=thumb.media_url;}
  }
  for(const path of paths){
    if(typeof path!=='string')continue;
    const m=/^(SavedClips|SentryClips)\/(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})\/(event\.json|thumb[^/]*\.(?:jpg|jpeg|png))$/.exec(path);
    if(!m)continue;const e=events.get(m[1]+'/'+m[2]);if(!e || e.owned)continue;
    if(m[3]==='event.json')e.metadata=mediaURL(path);else e.thumb=mediaURL(path);
  }
  return [...events.values()].map(e=>{
    e.segments.sort((a,b)=>a.stamp.localeCompare(b.stamp));e.newest=e.segments.at(-1).stamp;e.start=e.segments[0].stamp;
    e.date=e.sequence.slice(0,10);e.cameras=Object.keys(CAMERAS).filter(c=>e.segments.some(s=>s.files[c]));e.duration=e.segments.length*60;
    return e;
  }).sort((a,b)=>b.newest.localeCompare(a.newest)||a.id.localeCompare(b.id));
}
export function eventMarker(event, metadata) {
  if(!metadata || typeof metadata.timestamp!=='string')return null;
  // Match the reported camera-clock timestamp to an actual segment. Do not
  // invent a timezone conversion when the filename carries no timezone.
  const m=/^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})/.exec(metadata.timestamp);
  if(!m)return null; const target=stampMillis(`${m[1]}_${m[2]}-${m[3]}-${m[4]}`);
  for(let i=0;i<event.segments.length;i++){const diff=(target-stampMillis(event.segments[i].stamp))/1000;if(diff>=0 && diff<60)return i*60+diff;}
  return null;
}
export function validLocation(metadata) {
  const lat=Number(metadata?.est_lat),lon=Number(metadata?.est_lon);
  return metadata?.est_lat!=null && metadata?.est_lon!=null && Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat)<=90 && Math.abs(lon)<=180 ? {lat,lon} : null;
}
export function validLibrary(data) {
  if(!data || !Array.isArray(data.videos) || data.videos.some(p=>typeof p!=='string') || data.videos.length>500000)throw new Error('The recording list is invalid or exceeds the safe display limit.');
  return data;
}
export function validTrash(data) {
  if(!data || !['items','restored','tombstones','hidden_media'].every(k=>Array.isArray(data[k])) || ['tombstones','hidden_media'].some(k=>data[k].some(v=>typeof v!=='string')))throw new Error('Trash status could not be verified. Refresh to try again.');
  return data;
}
// The index chooses the latest raw day. Deleted aliases can make that day empty,
// so resolve the latest visible day before committing a new library to the UI.
export async function resolveLibrary(initial,trash,day,fetchDay,onScan=()=>{}) {
  validLibrary(initial);validTrash(trash);
  if(day!=='latest')return {data:initial,events:buildEvents(initial.videos,trash).filter(e=>e.date===day),selectedDay:day};
  const overlays=buildEvents([],trash),firstDay=initial.selected_day;
  const days=[...new Set([firstDay,...(initial.available_days||[]).filter(d=>!firstDay||d<firstDay),...overlays.map(e=>e.date)])].filter(d=>/^\d{4}-\d{2}-\d{2}$/.test(d||'')).sort().reverse();
  for(const candidate of days){
    onScan(candidate);
    const data=candidate===firstDay?initial:(!firstDay||candidate>firstDay)?{...initial,videos:[]}:validLibrary(await fetchDay(candidate));
    const events=buildEvents(data.videos,trash).filter(e=>e.date===candidate);
    if(events.length)return {data:{...data,available_days:initial.available_days,selected_day:candidate},events,selectedDay:candidate};
  }
  return {data:{...initial,videos:[],selected_day:null},events:[],selectedDay:null};
}
export function downloadQuery(event,camera) {
  const params=new URLSearchParams({event:event.event,camera});if(event.group==='RecentClips')params.set('segment',event.start);return params;
}

export const RECORDINGS_PER_PAGE=20;
// The grid stays newest-first; viewer navigation follows recorded time.
export function recordingNeighbors(events,currentId) {
  const ordered=[...events].sort((a,b)=>a.start.localeCompare(b.start)||a.id.localeCompare(b.id));
  const index=ordered.findIndex(event=>event.id===currentId);
  return {previous:index>0?ordered[index-1]:null,next:index>=0?ordered[index+1]||null:null,index:index+1,total:ordered.length};
}
export function recordingPage(events,{category='all',query='',hour='latest',page=1}={}) {
  const counts=new Map();
  for(const event of events)if(event.group==='RecentClips'){
    const value=event.start.slice(11,13);counts.set(value,(counts.get(value)||0)+1);
  }
  const hours=[...counts].sort(([a],[b])=>b.localeCompare(a)).map(([value,count])=>({value,count}));
  const selectedHour=hour==='all'?'all':counts.has(hour)?hour:hours[0]?.value??null;
  const search=query.toLowerCase().trim();
  const matches=events.filter(event=>(category==='all'||event.group===category)
    &&(category!=='RecentClips'||selectedHour==='all'||event.start.slice(11,13)===selectedHour)
    &&(!search||`${event.category} ${event.sequence} ${event.start} ${stampLabel(event.start)}`.toLowerCase().includes(search)));
  const pages=Math.max(1,Math.ceil(matches.length/RECORDINGS_PER_PAGE));
  const selectedPage=Math.max(1,Math.min(pages,Number.isFinite(page)?Math.floor(page):1));
  const offset=(selectedPage-1)*RECORDINGS_PER_PAGE;
  return {hours,hour:selectedHour,events:matches,total:matches.length,pages,page:selectedPage,
    items:matches.slice(offset,offset+RECORDINGS_PER_PAGE),start:matches.length?offset+1:0,end:Math.min(offset+RECORDINGS_PER_PAGE,matches.length)};
}
