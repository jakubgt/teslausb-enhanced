// Exercise the production viewer against generated, fictional localhost media.
// These checks never reach a Pi or send a real device action.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import {createPreviewServer,FIRST_EVENT} from '../tools/modern-preview-server.mjs';
const {chromium}=createRequire(import.meta.url)('playwright');

async function until(check,message,timeout=5000){
  const end=Date.now()+timeout;
  while(Date.now()<end){if(await check())return;await new Promise(resolve=>setTimeout(resolve,20));}
  assert.fail(message);
}

async function thumbnailTransport(media=null){
  const fixture=await createPreviewServer({media}),browser=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL||'chrome',headless:true});
  const page=await browser.newPage({viewport:{width:1440,height:1120}}),errors=[];
  page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(error.message));
  if(process.env.MODERN_PLAYER_BASELINE)await page.route('**/modern/player.mjs',route=>route.fulfill({contentType:'text/javascript',body:fs.readFileSync(process.env.MODERN_PLAYER_BASELINE,'utf8')}));
  const selected='SavedClips/2026-09-08_16-20-00',front=`${selected}/2026-09-08_16-19-00-front.mp4`;
  const mode=value=>page.locator(`#player [data-mode="${value}"]`).click();
  const rendered=()=>page.locator('#player .overview-tile img').evaluateAll(images=>images.filter(image=>image.complete&&image.naturalWidth>0).length);
  const allSix=()=>until(async()=>(await rendered())===6,'All six JPEGs must render despite the recording-store read lock',8000);
  try{
    fixture.state.thumbnailReadLock=true;fixture.state.thumbnailImageDelay=30;
    await page.goto(fixture.url);await page.locator('#library-state').filter({hasText:'recordings available'}).waitFor();
    await page.locator(`#clip-grid [data-open="${selected}"]`).first().click();
    await mode('overview');await allSix();
    assert.equal(fixture.state.thumbnailReadConflicts,0,'A camera image finishes before the next thumbnail status request starts');
    assert.equal(fixture.state.maxActiveThumbnailReads,1);
    console.log('PASS: serialized thumbnail status/image HTTP requests render all six under an exclusive read lock');

    await mode('single');fixture.state.thumbnailImageFailures.set(front,1);fixture.state.thumbnailImageAttempts.clear();
    const beforeRetry=fixture.state.mutations.length;await mode('overview');await allSix();
    assert.equal(fixture.state.thumbnailImageAttempts.get(front),2,'An image transfer failure is retried once without a manual Check');
    assert.equal(fixture.state.mutations.length,beforeRetry,'Retrying an existing JPEG does not start another encoder job');
    await mode('single');fixture.state.thumbnailImageFailures.set(front,-1);fixture.state.thumbnailImageAttempts.clear();
    await mode('overview');await page.locator('#player [data-overview-retry]').waitFor({state:'visible'});
    await until(async()=>(await rendered())===5,'Other cameras still display when one image transfer keeps failing');
    const attempts=fixture.state.thumbnailImageAttempts.get(front);
    assert.ok(attempts>=1&&attempts<=3,`Permanent image failures use at most three attempts, observed ${attempts}`);
    await page.clock.install();await page.clock.fastForward(15000);
    assert.equal(fixture.state.thumbnailImageAttempts.get(front),attempts,'Exhausted image retries stop until an explicit Check');
    assert.equal(fixture.state.mutations.length,beforeRetry,'Permanent image failure does not trigger encoding');
    await page.clock.resume();
    fixture.state.thumbnailImageFailures.clear();await page.locator('#player [data-overview-retry]').click();await allSix();

    await mode('single');fixture.state.thumbnailImageDelay=500;
    const beforeAbort=fixture.state.thumbnailAbortedImages,imageAttemptsBefore=fixture.state.thumbnailImageAttempts.get(front)||0;await mode('overview');
    await until(()=>fixture.state.activeThumbnailReads>0&&fixture.state.thumbnailImageAttempts.get(front)>imageAttemptsBefore,'An overview image transfer has started');
    await mode('single');
    await until(()=>fixture.state.activeThumbnailReads===0,'Leaving the overview closes the pending JPEG response');
    assert.ok(fixture.state.thumbnailAbortedImages>beforeAbort,'Leaving Camera overview aborts the pending image request');
    await new Promise(resolve=>setTimeout(resolve,550));
    assert.equal(await page.locator('#player .overview-tile').count(),0,'A late image completion cannot restore the overview');
    assert.equal(await page.locator('#player video').count(),1);
    assert.deepEqual(errors,[]);
    console.log('PASS: transient JPEG recovery, bounded permanent failures, explicit Check and image-request cancellation');
  }catch(error){console.error('Thumbnail fixture state:',{rendered:await rendered(),conflicts:fixture.state.thumbnailReadConflicts,activeReads:fixture.state.activeThumbnailReads,imageAttempts:Object.fromEntries(fixture.state.thumbnailImageAttempts)});throw error;}
  finally{await browser.close();await fixture.close();}
}

async function run(){
  const fixture=await createPreviewServer();
  const browser=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL||'chrome',headless:true});
  const context=await browser.newContext({viewport:{width:1440,height:1120},locale:'en-US',reducedMotion:'reduce'});
  await context.addInitScript(()=>{
    const create=URL.createObjectURL.bind(URL),revoke=URL.revokeObjectURL.bind(URL);
    window.bufferURLs={created:[],revoked:[]};
    URL.createObjectURL=blob=>{const url=create(blob),item={url,size:blob.size,type:blob.type};window.bufferURLs.created.push(item);blob.arrayBuffer().then(bytes=>crypto.subtle.digest('SHA-256',bytes)).then(hash=>{item.sha256=[...new Uint8Array(hash)].map(byte=>byte.toString(16).padStart(2,'0')).join('');});return url;};
    URL.revokeObjectURL=url=>{window.bufferURLs.revoked.push(url);revoke(url);};
  });
  const page=await context.newPage(),errors=[];
  page.setDefaultTimeout(15000);
  page.on('pageerror',error=>errors.push(error.message));
  const player=page.locator('#player'),load=player.locator('[data-buffer]'),cancel=player.locator('[data-buffer-cancel]');
  const output=process.env.MODERN_SCREENSHOT_DIR||path.join(os.tmpdir(),'teslausb-modern-browser');fs.mkdirSync(output,{recursive:true});
  const captureLayouts=async name=>{
    for(const [size,width,height] of [['desktop',1440,1120],['compact-desktop',1440,675],['mobile',390,844]]){
      await page.setViewportSize({width,height});
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,`${name} fits a ${width}px viewport without horizontal scrolling`);
      if(name==='buffer'){
        const bounds=await player.evaluate(root=>Object.fromEntries(['.video-grid','.video-cell','video'].map(selector=>{const r=root.querySelector(selector).getBoundingClientRect();return[selector,{left:r.left,top:r.top,right:r.right,bottom:r.bottom,width:r.width,height:r.height}];})));
        const grid=bounds['.video-grid'],cell=bounds['.video-cell'],video=bounds.video;
        assert.ok(Math.abs(cell.width-grid.width)<1,`Single camera fills the grid at ${width}×${height}; cell ${cell.width}, grid ${grid.width}`);
        assert.ok(Math.abs(video.width-cell.width)<1&&Math.abs(video.height-cell.height)<1,`Video fits the height-limited cell at ${width}×${height} without clipping`);
        assert.ok(video.left>=cell.left-.5&&video.top>=cell.top-.5&&video.right<=cell.right+.5&&video.bottom<=cell.bottom+.5,'The complete video element stays inside its camera cell');
      }
      await page.screenshot({path:path.join(output,`efficient-${name}-${size}.png`),fullPage:true});
    }
    await page.setViewportSize({width:1440,height:1120});
  };
  const mode=value=>player.locator(`[data-mode="${value}"]`).click();
  const camera=value=>player.locator(`[data-camera="${value}"]`).click();
  const nav=name=>page.getByRole('navigation',{name:'Main navigation'}).getByRole('button',{name,exact:true}).click();
  const open=id=>page.locator(`#clip-grid [data-open="${id}"]`).first().click();
  const waitMedia=(count=1)=>page.waitForFunction(count=>{
    const videos=[...document.querySelectorAll('#player video')];
    return videos.length===count&&videos.every(video=>video.readyState>=2&&!video.error);
  },count);
  const waitBuffered=(count=1)=>page.waitForFunction(count=>{
    const videos=[...document.querySelectorAll('#player video')];
    return videos.length===count&&videos.every(video=>video.src.startsWith('blob:')&&video.readyState>=2&&!video.error);
  },count);
  const liveURLs=()=>page.evaluate(()=>window.bufferURLs.created.filter(item=>!window.bufferURLs.revoked.includes(item.url)));
  const bufferRequests=from=>fixture.state.requests.slice(from).filter(request=>request.path.startsWith('/TeslaCam/')&&request.path.endsWith('.mp4')&&!request.range);
  const hide=()=>page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});document.dispatchEvent(new Event('visibilitychange'));});
  const show=()=>page.evaluate(()=>{delete document.hidden;document.dispatchEvent(new Event('visibilitychange'));});
  const noBuffer=async()=>{await until(async()=>!(await liveURLs()).length,'Every buffered object URL is revoked');};
  const noActiveLoad=()=>until(()=>fixture.state.activePlayableLoads===0,'The playable response is closed after cancellation');
  try{
    await page.goto(fixture.url);await page.locator('#library-state').filter({hasText:'recordings available'}).waitFor();await waitMedia();
    assert.equal(await player.locator('[data-mode="single"]').getAttribute('aria-pressed'),'true');
    assert.equal(await player.locator('[data-quality]').textContent(),'Original quality');
    assert.equal(fixture.state.requests.some(request=>request.path==='/api/v1/recordings/preview'),false,'First load never probes or starts an expensive Low job');
    const start=fixture.state.requests.length;
    await load.click();await waitBuffered();
    assert.equal(await load.isDisabled(),true);
    assert.equal((await liveURLs()).length,1);
    assert.equal((await liveURLs())[0].size,fixture.media.data.length);
    await until(async()=>(await liveURLs())[0]?.sha256,'The buffered fixture hash is ready');
    assert.equal((await liveURLs())[0].sha256,createHash('sha256').update(fixture.media.data).digest('hex'),'The playable response is buffered byte-for-byte');
    assert.deepEqual(bufferRequests(start).map(request=>request.path),[`/TeslaCam/${FIRST_EVENT}/2026-09-08_18-39-00-front.mp4`],'Buffer only the selected minute, using the playable URL');
    assert.equal(fixture.state.requests.slice(start).some(request=>request.path.includes('/recordings/download')),false,'Buffering never substitutes the raw-original download endpoint');
    assert.equal(await player.locator('video').evaluate(video=>video.paused),true,'A completed preload waits for Play');
    await captureLayouts('buffer');
    await player.getByRole('button',{name:'Play recording',exact:true}).click();
    await page.waitForFunction(()=>document.querySelector('#player video').currentTime>.3);
    await player.locator('video').evaluate(video=>video.dispatchEvent(new Event('waiting')));
    assert.equal(await player.locator('.player-error').isVisible(),true,'A decoder wait displays playback feedback');
    await player.getByRole('button',{name:'Pause recording',exact:true}).click();
    assert.equal(await player.locator('.player-error').isHidden(),true,'Pausing clears the old buffering/decoder-wait notice');
    const bufferedURL=(await liveURLs())[0].url;
    await player.getByRole('button',{name:'Skip forward 10 seconds',exact:true}).click();
    await player.getByRole('button',{name:'Skip back 10 seconds',exact:true}).click();
    assert.equal((await liveURLs())[0].url,bufferedURL,'Seeking within the buffered minute keeps its object URL');
    await camera('back');await waitMedia();await noBuffer();
    assert.equal(await player.locator('video').evaluate(video=>video.src.startsWith('blob:')),false);
    console.log('PASS: Single/High defaults, byte-exact selected-minute preload, local playback and seek reuse');

    fixture.state.playableChunkDelay=60;fixture.state.playableChunkBytes=512;
    const abortedBefore=fixture.state.abortedPlayableLoads;
    await load.click();await cancel.waitFor({state:'visible'});
    await page.waitForFunction(()=>document.querySelector('progress[aria-label="Clip loading progress"]')?.value>0);
    assert.equal(await player.getByRole('button',{name:'Play recording',exact:true}).isDisabled(),true);
    await cancel.click();await noActiveLoad();await noBuffer();
    assert.ok(fixture.state.abortedPlayableLoads>abortedBefore,'Cancel aborts the response stream');
    await load.click();await cancel.waitFor({state:'visible'});await camera('front');await waitMedia();await noActiveLoad();await noBuffer();
    await load.click();await cancel.waitFor({state:'visible'});await open('SavedClips/2026-09-08_16-20-00');await waitMedia();await noActiveLoad();await noBuffer();
    await load.click();await cancel.waitFor({state:'visible'});await hide();await noActiveLoad();await noBuffer();
    assert.equal(await player.locator('video[src]').count(),0,'Hidden pages release playback as well as in-progress loading');
    await show();await waitMedia();fixture.state.playableChunkDelay=0;
    await load.click();await waitBuffered();await nav('Device');await noBuffer();
    assert.equal(await player.locator('video[src]').count(),0,'Leaving Recordings releases all media');
    await nav('Recordings');await waitMedia();
    console.log('PASS: progress/cancel and camera, recording, visibility, and page-leave cleanup');

    fixture.state.omitPlayableLength=true;
    await load.click();await waitBuffered();
    assert.equal((await liveURLs())[0].size,fixture.media.data.length,'A readable response without Content-Length uses received bytes safely');
    fixture.state.omitPlayableLength=false;
    await mode('all');await waitMedia(6);await noBuffer();
    fixture.state.maxActivePlayableLoads=0;const allStart=fixture.state.requests.length;
    await load.click();await waitBuffered(6);await noActiveLoad();
    assert.equal(bufferRequests(allStart).length,6);
    assert.equal(new Set(bufferRequests(allStart).map(request=>request.path.split('/').at(-1).slice(0,19))).size,1,'All-camera preload stays within one minute');
    assert.equal(fixture.state.maxActivePlayableLoads,1,'All-camera files load sequentially');
    assert.equal((await liveURLs()).length,6);
    await mode('single');await waitMedia();await noBuffer();
    await mode('all');await waitMedia(6);fixture.state.playableChunkDelay=100;fixture.state.playableChunkBytes=Math.max(1,Math.ceil(fixture.media.data.length/4));
    await load.click();await until(async()=>(await liveURLs()).length===1,'The first camera completes while later cameras are still loading');
    await cancel.click();await noActiveLoad();await noBuffer();
    fixture.state.playableChunkDelay=0;await mode('single');await waitMedia();
    console.log('PASS: unknown response length, sequential all-camera loading, partial-load cancellation and layout cleanup');

    await page.route('**/TeslaCam/**/*.mp4',route=>route.request().resourceType()==='fetch'
      ?route.fulfill({status:200,headers:{'Content-Type':'video/mp4','Content-Length':String(65*1024*1024)},body:Buffer.from('oversized fixture')})
      :route.continue());
    await load.click();await page.waitForFunction(()=>!document.querySelector('#player [data-buffer]').disabled&&!document.querySelector('#player [data-buffer-cancel]').offsetParent);
    assert.match(await player.locator('[data-buffer-status]').textContent(),/large|limit|64|size/i);
    await noBuffer();await page.unroute('**/TeslaCam/**/*.mp4');
    await page.route('**/TeslaCam/**/*.mp4',route=>route.request().resourceType()==='fetch'
      ?route.fulfill({status:200,contentType:'text/html',body:'<html>Wrong response</html>'})
      :route.continue());
    await load.click();await page.waitForFunction(()=>!document.querySelector('#player [data-buffer]').disabled&&!document.querySelector('#player [data-buffer-cancel]').offsetParent);
    assert.match(await player.locator('[data-buffer-status]').textContent(),/type|video|response|format/i);
    await noBuffer();await page.unroute('**/TeslaCam/**/*.mp4');
    console.log('PASS: oversized files and non-video responses fail without keeping object URLs');

    const overviewStart=fixture.state.requests.length;
    await mode('overview');
    await page.waitForFunction(()=>{const images=[...document.querySelectorAll('#player .overview-tile img')];return images.length===6&&images.every(image=>image.complete&&image.naturalWidth>0);});
    assert.equal(await player.locator('.overview-tile').count(),6);
    assert.equal(await player.locator('video').count(),0,'Camera overview renders only images');
    await captureLayouts('overview');
    assert.equal(fixture.state.requests.slice(overviewStart).some(request=>request.path.endsWith('.mp4')||request.path.startsWith('/api/v1/recordings/preview')),false,'Overview never requests full video or Low transcodes');
    for(const label of ['Play recording','Skip back 10 seconds','Skip forward 10 seconds'])assert.equal(await player.getByRole('button',{name:label,exact:true}).isDisabled(),true);
    await player.locator('[data-overview-camera="right_pillar"]').click();await waitMedia();
    assert.equal(await player.locator('[data-mode="single"]').getAttribute('aria-pressed'),'true');
    assert.equal(await player.locator('[data-quality]').textContent(),'Original quality');
    assert.equal(await player.locator('[data-camera="right_pillar"]').getAttribute('aria-pressed'),'true');

    const currentEvent=fixture.state.events.find(event=>event.event==='SavedClips/2026-09-08_16-20-00');
    const unavailable=`${currentEvent.event}/${currentEvent.stamps[0]}-front.mp4`;
    fixture.state.thumbnailOverrides.set(unavailable,{state:'unavailable'});
    await mode('overview');await player.locator('[data-overview-camera="front"]').filter({hasText:/unavailable/i}).waitFor();
    assert.equal(await player.locator('.overview-tile').count(),6,'Unavailable previews retain their named camera tile');
    fixture.state.thumbnailOverrides.delete(unavailable);await player.locator('[data-overview-retry]').click();
    await page.waitForFunction(()=>{const image=document.querySelector('#player [data-overview-camera="front"] img');return image?.complete&&image.naturalWidth>0;});
    await mode('single');await waitMedia();fixture.state.thumbnailDelay=500;
    await mode('overview');await mode('single');await waitMedia();
    await new Promise(resolve=>setTimeout(resolve,650));
    assert.equal(await player.locator('.overview-tile').count(),0,'Late overview responses cannot restore the old mode');
    fixture.state.thumbnailDelay=0;
    const first=fixture.state.events.find(event=>event.event===FIRST_EVENT);
    const missing=`${first.stamps[0]}-left_pillar.mp4`;
    first.files=first.files.filter(file=>file.name!==missing);
    await page.locator('#refresh-recordings').click();await page.locator('#library-state').filter({hasText:'recordings available'}).waitFor();await waitMedia();
    await open(FIRST_EVENT);await waitMedia();
    fixture.state.thumbnailState='not_requested';fixture.state.thumbnailOverrides.clear();
    const missingStart=fixture.state.requests.length;
    await mode('overview');await player.locator('[data-overview-camera="left_pillar"]').filter({hasText:/missing|not recorded|unavailable/i}).waitFor();
    await page.waitForFunction(()=>{const images=[...document.querySelectorAll('#player .overview-tile img')];return images.length===5&&images.every(image=>image.complete&&image.naturalWidth>0);});
    assert.equal(await player.locator('.overview-tile').count(),6,'A missing segment camera remains identifiable in the overview');
    const prepared=fixture.state.requests.slice(missingStart).filter(request=>request.path==='/api/v1/recordings/thumbnail'&&request.method==='POST');
    assert.equal(prepared.length,5,'Not-yet-generated previews request only the five available camera frames');
    assert.equal(prepared.some(request=>new URLSearchParams(request.query).get('path')?.endsWith(missing)),false);
    await mode('single');await waitMedia();fixture.state.thumbnailState='ready';fixture.state.thumbnailDelay=500;fixture.state.thumbnailOverrides.clear();
    await mode('overview');await open('SavedClips/2026-09-08_16-20-00');
    await page.waitForFunction(()=>{const images=[...document.querySelectorAll('#player .overview-tile img')];return images.length===6&&images.every(image=>image.complete&&image.naturalWidth>0);});
    assert.equal(await player.locator('.overview-tile img').evaluateAll(images=>images.every(image=>new URL(image.src).searchParams.get('path')?.startsWith('SavedClips/2026-09-08_16-20-00/'))),true,'Late replies for the previous recording cannot replace the selected overview');
    fixture.state.thumbnailDelay=0;
    console.log('PASS: image-only six-camera overview, missing-camera/preparation behavior, selection/retry, and late-response cleanup');
    const stalled=await context.newPage();stalled.on('pageerror',error=>errors.push(error.message));await stalled.clock.install();
    try{
      await stalled.goto(fixture.url);await stalled.locator('#library-state').filter({hasText:'recordings available'}).waitFor();
      await stalled.route('**/TeslaCam/**/*.mp4',route=>route.request().resourceType()==='fetch'?undefined:route.continue());
      await stalled.locator('#player [data-buffer]').click();await stalled.locator('#player [data-buffer-cancel]').waitFor({state:'visible'});
      await stalled.clock.fastForward(30001);
      await stalled.locator('#player [data-buffer-status]').filter({hasText:/stopped responding/i}).waitFor();
      assert.equal(await stalled.locator('#player [data-buffer]').isEnabled(),true,'A stalled load can be retried');
      assert.equal(await stalled.evaluate(()=>window.bufferURLs.created.filter(item=>!window.bufferURLs.revoked.includes(item.url)).length),0);
    }finally{await stalled.close();}
    const pending=await context.newPage();pending.on('pageerror',error=>errors.push(error.message));await pending.clock.install();
    const busyPath=`${FIRST_EVENT}/${first.stamps[0]}-front.mp4`;
    fixture.state.thumbnailOverrides.set(busyPath,{state:'unavailable',reason:'preview_worker_busy'});
    try{
      await pending.goto(fixture.url);await pending.locator('#library-state').filter({hasText:'recordings available'}).waitFor();
      const busyStart=fixture.state.requests.length;
      await pending.locator('#player [data-mode="overview"]').click();
      await pending.locator('[data-overview-camera="front"]').filter({hasText:'Small still is preparing'}).waitFor();
      await pending.waitForFunction(()=>{const images=[...document.querySelectorAll('#player .overview-tile img')];return images.length===4&&images.every(image=>image.complete&&image.naturalWidth>0);});
      fixture.state.thumbnailOverrides.set(busyPath,{state:'ready'});
      await pending.clock.fastForward(5001);
      await pending.waitForFunction(()=>{const image=document.querySelector('[data-overview-camera="front"] img');return image?.complete&&image.naturalWidth>0;});
      assert.equal(fixture.state.requests.slice(busyStart).some(request=>request.path==='/api/v1/recordings/thumbnail'&&request.method==='POST'&&new URLSearchParams(request.query).get('path')===busyPath),false,'Busy worker polling does not enqueue duplicate jobs');
    }finally{await pending.close();fixture.state.thumbnailOverrides.clear();}
    console.log('PASS: stalled transfers release safely and busy thumbnail workers recover without duplicate jobs');
    await thumbnailTransport(fixture.media);
    assert.deepEqual(errors,[]);
    assert.equal(fixture.state.mutations.some(request=>!request.path.startsWith('/api/v1/recordings/thumbnail')),false,'Only bounded thumbnail preparation may mutate fixture state');
  }catch(error){await page.screenshot({path:path.join(output,'efficient-playback-failure.png'),fullPage:true}).catch(()=>{});console.error('Browser errors:',errors);throw error;}
  finally{await context.close();await browser.close();await fixture.close();}
}
(process.env.MODERN_EFFICIENT_FOCUS==='thumbnail-transport'?thumbnailTransport():run()).catch(error=>{console.error(error);process.exitCode=1;});
