#!/usr/bin/env node
/* Local fixtures only. No route invokes CGI, shell commands, or a TeslaUSB Pi.
 * Run: NODE_PATH=<Playwright modules> node tools/modern-preview-server.mjs --port 8765
 * Fixture edits live in memory and reset when the server restarts. */
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';

const require = createRequire(import.meta.url);
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../teslausb-www/html');
const CAMERAS = ['front', 'back', 'left_repeater', 'right_repeater'];
export const NEWEST_DAY = '2026-09-08';
export const FIRST_EVENT = 'SentryClips/2026-09-08_18-40-00';

function stretchMp4(data, factor = 20) {
  // MediaRecorder writes all decode timestamps in track time units. Reducing
  // the movie and track timescales stretches fictional test footage to a full
  // segment without recording a minute of real time. No recording is edited.
  const out = Buffer.from(data);
  function boxes(start, end) {
    for (let offset = start; offset + 8 <= end;) {
      const size = out.readUInt32BE(offset), type = out.toString('ascii', offset + 4, offset + 8);
      if (size < 8 || offset + size > end) break;
      if (['moov', 'trak', 'mdia'].includes(type)) boxes(offset + 8, offset + size);
      if (type === 'mvhd' || type === 'mdhd') {
        const field = offset + (out[offset + 8] === 1 ? 28 : 20);
        if (field + 4 <= offset + size) out.writeUInt32BE(Math.max(1, Math.round(out.readUInt32BE(field) / factor)), field);
      }
      offset += size;
    }
  }
  boxes(0, out.length); return out;
}

export async function generateFixtureMedia() {
  const {chromium} = require('playwright');
  const browser = await chromium.launch({channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome', headless: true});
  try {
    const page = await browser.newPage();
    const result = await page.evaluate(async () => {
      const canvas = document.createElement('canvas'); canvas.width = 640; canvas.height = 360;
      const ctx = canvas.getContext('2d'); let frame = 0;
      function paint() {
        frame++;
        const sky = ctx.createLinearGradient(0, 0, 0, 240); sky.addColorStop(0, '#789ab4'); sky.addColorStop(1, '#d3d8d5');
        ctx.fillStyle = sky; ctx.fillRect(0, 0, 640, 360);
        ctx.fillStyle = '#678261'; ctx.fillRect(0, 176, 640, 190);
        ctx.fillStyle = '#4b5a5a'; ctx.beginPath(); ctx.moveTo(250, 178); ctx.lineTo(390, 178); ctx.lineTo(630, 360); ctx.lineTo(10, 360); ctx.closePath(); ctx.fill();
        ctx.strokeStyle = '#e7e1cf'; ctx.lineWidth = 4; ctx.setLineDash([18, 24]); ctx.lineDashOffset = -frame * 2; ctx.beginPath(); ctx.moveTo(320, 185); ctx.lineTo(320, 360); ctx.stroke(); ctx.setLineDash([]);
        for (const [x, y, width, height] of [[25,150,82,55],[122,132,69,60],[457,130,81,67],[555,150,81,60]]) {
          ctx.fillStyle = '#d8cabb'; ctx.fillRect(x,y,width,height); ctx.fillStyle = '#48586a';ctx.beginPath();ctx.moveTo(x-6,y);ctx.lineTo(x+width/2,y-30);ctx.lineTo(x+width+6,y);ctx.fill();ctx.fillStyle='#40576b';ctx.fillRect(x+13,y+13,18,20);
        }
        for (const x of [11,212,423,619]) {ctx.fillStyle='#614f3b';ctx.fillRect(x,128,8,82);ctx.fillStyle='#405f48';ctx.beginPath();ctx.arc(x+4,126,29,0,Math.PI*2);ctx.fill();}
        ctx.fillStyle='#20252e';ctx.fillRect(353,190,53,24);ctx.fillStyle='#abb4be';ctx.fillRect(361,183,33,15);ctx.fillStyle='#111820';ctx.fillRect(0,335,640,25);
        ctx.fillStyle='#e3edf5';ctx.font='12px sans-serif';ctx.fillText('FICTIONAL CAMERA DEMO  ·  no vehicle connection',16,352);ctx.fillStyle='#162332c9';ctx.fillRect(13,13,210,28);ctx.fillStyle='#e7eff7';ctx.fillText('2026-09-08  18:39:'+String(frame%60).padStart(2,'0'),23,31);
      }
      paint();
      const mime = ['video/mp4;codecs=avc1.42001E', 'video/mp4', 'video/webm;codecs=vp8'].find(type => MediaRecorder.isTypeSupported(type));
      const stream = canvas.captureStream(12), recorder = new MediaRecorder(stream, {mimeType: mime, videoBitsPerSecond: 280000}), chunks = [];
      recorder.ondataavailable = event => { if(event.data.size) chunks.push(event.data); };
      const done = new Promise(resolve => { recorder.onstop = resolve; });
      const timer = setInterval(paint, 1000 / 12); recorder.start();
      await new Promise(resolve => setTimeout(resolve, 3400)); recorder.stop(); await done; clearInterval(timer);stream.getTracks().forEach(track => track.stop());
      const blob = new Blob(chunks, {type: mime}), array = new Uint8Array(await blob.arrayBuffer());
      let binary = ''; for (const value of array) binary += String.fromCharCode(value);
      return {data: btoa(binary), type: mime.split(';')[0]};
    });
    const original = Buffer.from(result.data, 'base64');
    return {data: result.type === 'video/mp4' ? stretchMp4(original) : original, type: result.type};
  } finally { await browser.close(); }
}

function fixtureEvents() {
  return [
    {event: FIRST_EVENT, stamps: ['2026-09-08_18-39-00', '2026-09-08_18-40-00'], timestamp: '2026-09-08T18:39:15', city: 'Fictional neighborhood'},
    {event: 'SavedClips/2026-09-08_16-20-00', stamps: ['2026-09-08_16-19-00'], timestamp: '2026-09-08T16:19:20', city: 'Sample drive'},
    {event: 'SentryClips/2026-09-08_11-05-00', stamps: ['2026-09-08_11-04-00'], timestamp: '2026-09-08T11:04:10', city: 'Demo parking'},
    {event: 'RecentClips/2026-09-08', stamps: ['2026-09-08_10-40-00']},
    {event: 'SavedClips/2026-09-06_13-00-00', stamps: ['2026-09-06_12-59-00'], timestamp: '2026-09-06T12:59:30', city: 'Earlier demo drive'}
  ].map(item => ({...item, files: item.stamps.flatMap(stamp => CAMERAS.map(camera => ({name: `${stamp}-${camera}.mp4`, camera}))).concat(item.timestamp ? [{name: 'event.json'}] : [])}));
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function fixtureWave() {
  const samples=16000*2,buffer=Buffer.alloc(44+samples*2);buffer.write('RIFF');buffer.writeUInt32LE(buffer.length-8,4);buffer.write('WAVEfmt ',8);buffer.writeUInt32LE(16,16);buffer.writeUInt16LE(1,20);buffer.writeUInt16LE(1,22);buffer.writeUInt32LE(16000,24);buffer.writeUInt32LE(32000,28);buffer.writeUInt16LE(2,32);buffer.writeUInt16LE(16,34);buffer.write('data',36);buffer.writeUInt32LE(samples*2,40);return buffer;
}
function crc32(data) {let crc = 0xffffffff;for (const byte of data) {crc ^= byte;for(let i=0;i<8;i++) crc=(crc>>>1)^((crc&1)?0xedb88320:0);}return (crc^0xffffffff)>>>0;}
function makeZip(files) {
  const chunks = [], directory = []; let offset = 0;
  for(const file of files) {
    const name=Buffer.from(file.name), crc=crc32(file.data), local=Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50);local.writeUInt16LE(20,4);local.writeUInt16LE(0x800,6);local.writeUInt32LE(crc,14);local.writeUInt32LE(file.data.length,18);local.writeUInt32LE(file.data.length,22);local.writeUInt16LE(name.length,26);chunks.push(local,name,file.data);
    const central=Buffer.alloc(46);central.writeUInt32LE(0x02014b50);central.writeUInt16LE(20,4);central.writeUInt16LE(20,6);central.writeUInt16LE(0x800,8);central.writeUInt32LE(crc,16);central.writeUInt32LE(file.data.length,20);central.writeUInt32LE(file.data.length,24);central.writeUInt16LE(name.length,28);central.writeUInt32LE(offset,42);directory.push(central,name);offset+=local.length+name.length+file.data.length;
  }
  const bytes=Buffer.concat(directory),end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50);end.writeUInt16LE(files.length,8);end.writeUInt16LE(files.length,10);end.writeUInt32LE(bytes.length,12);end.writeUInt32LE(offset,16);return Buffer.concat([...chunks,bytes,end]);
}

export async function createPreviewServer({port = 0, media = null} = {}) {
  media ||= await generateFixtureMedia();
  const state = {events: fixtureEvents(), trash: new Map(), previewState: 'unavailable', failVideos: false, failTrash: false, failStatus: false, failDownload: false, downloadDelay: 0, mutations: [], requests: [], files: new Map([['fs/Music', new Map([['Road Trip', {directory: true}], ['Evening drive.wav', {data: fixtureWave()}]])], ['fs/LightShow',new Map([['lightshow.fseq',{data:Buffer.from('fixture lightshow')} ]])], ['fs/Boombox',new Map([['LockChime.wav',{data:fixtureWave()}]])]])};
  const json = (response, value, status = 200) => {response.writeHead(status, {'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store'});response.end(JSON.stringify(value));};
  const sendMedia = (request, response, data = media.data, type = media.type, disposition) => {
    const headers = {'Content-Type':type,'Accept-Ranges':'bytes','Cache-Control':'no-store'};if(disposition)headers['Content-Disposition']=`attachment; filename="${disposition}"`;
    const range = /^bytes=(\d+)-(\d*)$/.exec(request.headers.range||'');let start=0,end=data.length-1,status=200;
    if(range) {start=Number(range[1]);end=range[2]?Math.min(Number(range[2]),end):end;if(start>end){response.writeHead(416,{'Content-Range':`bytes */${data.length}`});response.end();return;}status=206;headers['Content-Range']=`bytes ${start}-${end}/${data.length}`;}
    headers['Content-Length']=end-start+1;response.writeHead(status,headers);response.end(request.method==='HEAD'?undefined:data.subarray(start,end+1));
  };
  const publicEntry = entry => ({id:entry.id,event:entry.event,category:entry.event.split('/')[0],event_time:entry.event.split('/')[1],deleted_at:entry.deleted_at,expires_at:entry.expires_at,bytes:entry.bytes,files:entry.files.map(file=>({...file,bytes:file.camera?media.data.length:120,media_url:`/api/v1/trash/media?${new URLSearchParams({id:entry.id,file:file.name})}`}))});
  const trashStatus = () => {const entries=[...state.trash.values()];return {ok:true,retention_days:30,clock:{trusted:true},items:entries.filter(entry=>entry.state==='trashed').map(publicEntry),restored:entries.filter(entry=>entry.state==='restored').map(publicEntry),tombstones:entries.map(entry=>entry.event),hidden_media:entries.flatMap(entry=>entry.files.filter(file=>file.camera).map(file=>file.name)),free_bytes:55000000000,reserve_bytes:1000000000,retained_bytes:entries.filter(entry=>entry.state!=='deleted').reduce((sum,entry)=>sum+entry.bytes,0)};};
  const server = http.createServer(async (request,response) => {
    try {
      const url=new URL(request.url,'http://localhost'),p=decodeURIComponent(url.pathname),query=url.searchParams;
      state.requests.push({path:p,query:url.search,method:request.method});
      if(state.requests.length>2000)state.requests.shift();
      if(request.method==='POST') {if(request.headers['x-teslausb-request']!=='1')return json(response,{ok:false,error:'Missing request marker'},403);const parts=[];let size=0;for await (const part of request){size+=part.length;if(size>8*1024*1024)return json(response,{ok:false,error:'Fixture request too large'},413);parts.push(part);}request.body=Buffer.concat(parts);state.mutations.push({path:p,method:request.method,headers:request.headers,body:request.body.toString()});}
      if(p==='/api/v1/config')return json(response,{has_cam:'yes',has_music:'yes',has_lightshow:'yes',has_boombox:'yes',fixture_mode:true});
      if(p==='/api/v1/videos') {if(state.failVideos)return json(response,{ok:false,error:'Fixture recording list temporarily unavailable'},503);const days=[...new Set(state.events.map(event=>event.event.split('/')[1].slice(0,10)))].sort().reverse(),day=query.get('day')==='latest'||!query.get('day')?days[0]:query.get('day');return json(response,{videos:state.events.filter(event=>event.event.split('/')[1].startsWith(day)).flatMap(event=>event.files.map(file=>event.event+'/'+file.name)),selected_day:day,available_days:days,newest_recording:state.events[0].stamps.at(-1),schema_version:1});}
      if(p==='/api/v1/status') {if(state.failStatus)return json(response,{ok:false,error:'Fixture device offline'},503);return json(response,{uptime:'86425',cpu_temp:'49000',fan_speed:'1200',external_5v:'5.106',throttled:'0x0',total_space:'128000000000',free_space:'55000000000',num_snapshots:'14',drives_active:'yes',camera_drive_state:'connected',wifi_ssid:'Garage Wi-Fi',wifi_ip:'192.0.2.42',ether_ip:'',archive_status:{schema_version:1,available:true,last_result:'idle',pending_files:8,pending_bytes:268435456,transferred_files:24,transferred_bytes:1320702444,last_started:'2026-09-08T18:00:00Z',last_finished:'2026-09-08T18:03:00Z',last_successful_at:'2026-09-08T18:03:00Z',message:'Waiting for the next archive connection.'},encrypted_clips:{available:true,detected:false}});}
      if(p==='/api/v1/maintenance')return json(response,{schema_version:1,ssh:{service_state:'active',enabled_state:'enabled'},logs:Object.fromEntries(['diagnostics','archiveloop','setup','maintenance'].map(id=>[id,{available:true,size_bytes:id==='archiveloop'?10000000:700,truncated:id==='archiveloop'}])),health:{schema_version:1,storage:{backing:{available:true,total_bytes:128000000000,free_bytes:55000000000,below_cleanup_reserve:false},mutable:{available:true,total_bytes:8000000000,free_bytes:6500000000}},read_only:{root:true,boot:true},snapshots:{available:true,scan_complete:true,completed_count:14,last_completed:{name:'snap-000014',completed_at_utc:'2026-09-08T18:42:00Z'}},cleanup:{available:true,evidence:'completed_release',last_released_at_utc:'2026-09-08T17:30:00Z'},clock:{available:true,state:'synchronized',last_verified_utc:new Date().toISOString()},recovery:{available:true,scan_complete:true,items:[],total_logical_bytes:0}}});
      if(p.startsWith('/api/v1/maintenance/logs/')) {const id=p.split('/').at(-1);response.writeHead(200,{'Content-Type':'text/plain; charset=utf-8','X-TeslaUSB-Truncated':id==='archiveloop'?'true':'false','X-TeslaUSB-Original-Size':id==='archiveloop'?'10000000':'400'});response.end(`TeslaUSB ${id} — FICTIONAL LOCAL PREVIEW\n2026-09-08T18:40:00Z Checking storage: 55 GB available\n2026-09-08T18:40:02Z Snapshot snap-000014 verified\n2026-09-08T18:40:04Z INFO Sample operation complete\n2026-09-08T18:40:05Z DEBUG This is fixture data; no device was contacted\n`);return;}
      if(p.startsWith('/api/v1/actions/'))return json(response,{ok:true,message:'Local fixture action accepted; no device was contacted.'});
      if(p==='/api/v1/speed-test'){response.writeHead(200,{'Content-Type':'application/octet-stream','Cache-Control':'no-store'});let count=0;const timer=setInterval(()=>{if(response.destroyed||++count>30){clearInterval(timer);response.end();}else response.write(Buffer.alloc(16384));},60);response.on('close',()=>clearInterval(timer));return;}
      if(p==='/api/v1/recordings/preview') {const mode=state.previewState;return json(response,{ok:true,state:mode,reason:mode==='unavailable'?'No smaller preview exists in this local sample.':undefined,preview_url:mode==='ready'?'/api/v1/recordings/preview/media?'+new URLSearchParams({path:query.get('path')}):undefined});}
      if(p==='/api/v1/recordings/preview/media'){sendMedia(request,response);return;}
      if(p==='/api/v1/trash')return state.failTrash?json(response,{ok:false,error:'Fixture trash status unavailable'},503):json(response,trashStatus());
      if(p==='/api/v1/trash/move') {const body=JSON.parse(request.body||'{}'),event=state.events.find(item=>item.event===body.event);if(!event||event.event.startsWith('RecentClips/'))return json(response,{ok:false,error:'Fixture event is not eligible'},400);const id=createHash('sha256').update(event.event).digest('hex'),entry={...event,id,state:'trashed',deleted_at:new Date().toISOString(),expires_at:new Date(Date.now()+30*86400000).toISOString(),bytes:event.files.filter(file=>file.camera).length*media.data.length};state.trash.set(id,entry);return json(response,{...trashStatus(),item:publicEntry(entry)});}
      if(p==='/api/v1/trash/restore'||p==='/api/v1/trash/delete') {const body=JSON.parse(request.body||'{}');for(const id of body.ids||[]){const entry=state.trash.get(id);if(entry)entry.state=p.endsWith('restore')?'restored':'deleted';}return json(response,trashStatus());}
      if(p==='/api/v1/trash/media'){const entry=state.trash.get(query.get('id'));if(!entry||entry.state==='deleted')return json(response,{ok:false,error:'Fixture media missing'},404);if(query.get('file')==='event.json')return json(response,{timestamp:entry.timestamp,city:entry.city,est_lat:41.88,est_lon:-87.63});sendMedia(request,response);return;}
      if(p==='/api/v1/recordings/download'||p==='/api/v1/trash/download') {
        if(state.downloadDelay)await sleep(state.downloadDelay);if(response.destroyed)return;
        if(state.failDownload)return json(response,{ok:false,error:'Fixture download preparation failed. Retry the sample.'},503);
        const event=state.events.find(item=>item.event===query.get('event'))||state.trash.get(query.get('id'))||state.events[0],camera=query.get('camera')||'all',files=event.files.filter(file=>file.camera&&(camera==='all'||camera===file.camera)&&(!query.get('segment')||file.name.startsWith(query.get('segment')))),format=files.length===1?'mp4':'zip',filename=format==='mp4'?files[0].name:`${event.event.split('/')[1]}-${camera}.zip`;
        const params=new URLSearchParams(query);params.delete('info');if(query.get('info')==='1')return json(response,{ok:true,format,filename,total_bytes:files.length*media.data.length,file_count:files.length,size_kind:'original_files',files:files.map(file=>({...file,size_bytes:media.data.length})),download_url:p+'?'+params});
        sendMedia(request,response,format==='zip'?makeZip(files.map(file=>({name:file.name,data:media.data}))):media.data,format==='zip'?'application/zip':media.type,filename);return;
      }
      if(p.startsWith('/api/v1/files/')) {
        const args=url.search.slice(1).split('&').map(decodeURIComponent),root=args[0],folder=args[1]||'.';let drive=state.files.get(root),base=root;
        if(!drive){for(const [candidate,value] of state.files)if(root.startsWith(candidate+'/')){drive=value;base=candidate;break;}}
        if(!drive)return json(response,{ok:false,error:'Fixture drive is not configured'},404);
        const prefix=root.slice(base.length).replace(/^\/+|\/+$/g,'').replace(/^\.$/,'');
        const key=name=>[prefix,name==='.'?'':name].filter(Boolean).join('/').replace(/^\.\//,'');
        const selectedFolder=key(folder),relative=selectedFolder?selectedFolder.replace(/\/$/,'')+'/':'';
        if(p.endsWith('/list')){response.writeHead(200,{'Content-Type':'text/plain'});const lines=[...drive].filter(([name])=>name.startsWith(relative)&&!name.slice(relative.length).includes('/')).map(([name,file])=>file.directory?'d:'+name:`f:${name}:${file.data.length}`);response.end(lines.concat('s:5000000000:10000000000').join('\n')+'\n');return;}
        if(p.endsWith('/mkdir'))drive.set(key(args[1]),{directory:true});
        else if(p.endsWith('/upload'))drive.set(key(args[1]),{data:request.body});
        else if(p.endsWith('/move')){const old=key(args[1]),item=drive.get(old);drive.delete(old);drive.set(key(args[2]),item);}
        else if(p.endsWith('/delete'))for(const name of args.slice(1))drive.delete(key(name));
        else if(p.endsWith('/copy'))drive.set(key(args[2]),drive.get(key(args[1])));
        else if(p.endsWith('/download')||p.endsWith('/download-zip')){sendMedia(request,response,Buffer.from('Local fixture file download'),'application/octet-stream','fixture-file.txt');return;}
        return json(response,{ok:true});
      }
      if(p.startsWith('/TeslaCam/')) {if(p.endsWith('/event.json')){const event=state.events.find(item=>'/TeslaCam/'+item.event+'/event.json'===p);return json(response,{timestamp:event?.timestamp,city:event?.city,est_lat:41.88,est_lon:-87.63});}if(p.endsWith('.mp4')){sendMedia(request,response);return;}}
      if(p.startsWith('/fs/')){for(const [drive,entries]of state.files)if(p.startsWith('/'+drive+'/')){const entry=entries.get(p.slice(drive.length+2));if(entry?.data){sendMedia(request,response,entry.data,p.endsWith('.wav')?'audio/wav':'application/octet-stream');return;}}return json(response,{ok:false,error:'Fixture file missing'},404);}
      if(p==='/'||p==='/modern'){response.writeHead(302,{Location:'/modern/'});response.end();return;}
      const file=path.resolve(ROOT,'.'+(p.endsWith('/')?p+'index.html':p));
      if(!file.startsWith(ROOT+path.sep)||!fs.existsSync(file)||!fs.statSync(file).isFile())return json(response,{ok:false,error:'Local fixture resource not found'},404);
      const types={'.mjs':'text/javascript','.js':'text/javascript','.html':'text/html','.css':'text/css','.svg':'image/svg+xml','.png':'image/png','.jpg':'image/jpeg'};response.writeHead(200,{'Content-Type':types[path.extname(file)]||'application/octet-stream','Cache-Control':'no-store'});fs.createReadStream(file).pipe(response);
    }catch(error){if(!response.headersSent)json(response,{ok:false,error:'Fixture server: '+error.message},500);else response.end();}
  });
  await new Promise(resolve=>server.listen(port,'127.0.0.1',resolve));
  return {server,state,media,url:`http://127.0.0.1:${server.address().port}/modern/`,close:()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve);})};
}

if(process.argv[1]&&fileURLToPath(import.meta.url)===path.resolve(process.argv[1])) {
  const index=process.argv.indexOf('--port'),port=index<0?8765:Number(process.argv[index+1]);
  if(!Number.isInteger(port)||port<0||port>65535)throw new Error('Use --port with a port number from 0 to 65535.');
  const fixture=await createPreviewServer({port});
  // An immediately playable first screen is useful when reviewing the sample.
  // Integration tests retain the createPreviewServer() unavailable default.
  fixture.state.previewState='ready';
  console.log(`FICTIONAL LOCAL PREVIEW ONLY — no Pi connection or real recording changes.\n${fixture.url}\nTrash and file actions affect in-memory fixtures. Stop the process to reset.`);
  process.on('SIGINT',async()=>{await fixture.close();process.exit(0);});
}
