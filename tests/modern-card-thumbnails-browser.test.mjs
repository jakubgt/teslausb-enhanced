// Real HTTP JPEG delivery with fictional recordings; no Pi or user media.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';
import {cardThumbnailSource,queueThumbnailRequest} from '../teslausb-www/html/modern/thumbnail-loader.mjs';
import {CAMERAS} from '../teslausb-www/html/modern/model.mjs';
import {createPreviewServer,NEWEST_DAY} from '../tools/modern-preview-server.mjs';
const {chromium}=createRequire(import.meta.url)('playwright');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(check,message,timeout=10000){const end=Date.now()+timeout;while(Date.now()<end){if(await check())return;await sleep(20);}assert.fail(message);}

async function sourceAndQueue(){
  const first={path:'first-front.mp4'},later={path:'later-front.mp4'};
  assert.equal(cardThumbnailSource({segments:[{files:{front:first}},{files:{front:later}}],thumb:'/TeslaCam/thumb.png'}).path,first.path);
  assert.equal(cardThumbnailSource({segments:[{files:{back:{}}},{files:{front:later}}]}),null,'A later front frame must not be labeled as the beginning');
  assert.equal(cardThumbnailSource({segments:[{files:{front:first}}],owned:'restored'}),null,'Restored originals do not go through the snapshot thumbnail API');
  assert.equal(cardThumbnailSource({segments:[],owned:'restored',thumb:'/api/v1/trash/media?asset=thumb'}).alt,'Recording thumbnail');
  const calls=[],cancel=new AbortController();let release;
  const active=queueThumbnailRequest(()=>new Promise(resolve=>{calls.push('active');release=resolve;}));
  await until(()=>release,'Queue starts the first request');
  const low=queueThumbnailRequest(()=>calls.push('grid'));
  const high=queueThumbnailRequest(()=>calls.push('viewer'),{priority:10});
  const removed=queueThumbnailRequest(()=>calls.push('cancelled'),{signal:cancel.signal});
  const rejected=assert.rejects(removed,{name:'AbortError'});cancel.abort();release();
  await Promise.all([active,low,high,rejected]);assert.deepEqual(calls,['active','viewer','grid']);

  // Browser abort settles its promise before the remote response has closed.
  // A subsequent viewer request must leave time for that transport to drain.
  const transfer=new AbortController();let transferStarted=false,transportClosed=false;
  const abortedRequest=queueThumbnailRequest(()=>new Promise((resolve,reject)=>{
    transferStarted=true;transfer.signal.addEventListener('abort',()=>{setTimeout(()=>{transportClosed=true;},25);reject(new DOMException('Cancelled','AbortError'));},{once:true});
  }),{signal:transfer.signal});
  await until(()=>transferStarted,'Active transport starts');
  const cancellation=assert.rejects(abortedRequest,{name:'AbortError'});
  const afterAbort=queueThumbnailRequest(()=>assert.equal(transportClosed,true,'Do not hand the recording lock to another request before the aborted transport drains'),{priority:10});
  transfer.abort();await Promise.all([cancellation,afterAbort]);
}

async function run(){
  await sourceAndQueue();
  const fixture=await createPreviewServer(),browser=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL||'chrome',headless:true});
  const stamps=Array.from({length:60},(_,n)=>`${NEWEST_DAY}_20-${String(n).padStart(2,'0')}-00`),event=`RecentClips/${NEWEST_DAY}`;
  fixture.state.events=[{event,stamps,files:stamps.flatMap(stamp=>Object.keys(CAMERAS).map(camera=>({name:`${stamp}-${camera}.mp4`,camera})))}];
  fixture.state.thumbnailState='not_requested';fixture.state.thumbnailReadLock=true;fixture.state.thumbnailImageDelay=35;
  const page=await browser.newPage({viewport:{width:1440,height:675},reducedMotion:'reduce'}),errors=[];page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(error.message));
  const requests=()=>fixture.state.requests.filter(r=>r.path.startsWith('/api/v1/recordings/thumbnail'));
  const source=r=>new URLSearchParams(r.query).get('path');
  const card=stamp=>page.locator(`#clip-grid .clip-image[data-open="${event}#${stamp}"]`);
  const loaded=locator=>locator.locator('img').evaluateAll(images=>images.some(image=>image.complete&&image.naturalWidth>0));
  const search=query=>page.locator('#recording-search').fill(query);
  const nav=name=>page.getByRole('navigation',{name:'Main navigation'}).getByRole('button',{name,exact:true}).click();
  try{
    await page.goto(fixture.url);await page.locator('#library-state').filter({hasText:'recordings available'}).waitFor();await sleep(300);
    assert.equal(requests().length,0,'Cards below the viewport do not request or generate stills');
    await card(stamps[59]).scrollIntoViewIfNeeded();
    await until(()=>loaded(card(stamps[59])),'First visible card loads the front-camera JPEG');
    const image=card(stamps[59]).locator('img');assert.match(await image.getAttribute('src'),/thumbnail\/media\?/);
    assert.equal(new URLSearchParams((await image.getAttribute('src')).split('?')[1]).get('path'),`${event}/${stamps[59]}-front.mp4`);
    assert.equal(await image.getAttribute('alt'),'Front camera near the start of this recording');
    assert.equal(await card(stamps[59]).locator('.duration').innerText(),'1:00');
    assert.equal(await card(stamps[59]).locator('.camera-placeholder').isVisible(),true,'Play affordance stays visible over the real image');
    assert.ok(requests().every(r=>source(r).endsWith('-front.mp4')),'Grid requests no side camera or video preview');
    const allowed=new Set(stamps.slice(40).map(stamp=>`${event}/${stamp}-front.mp4`));
    assert.ok(requests().every(r=>allowed.has(source(r))),'Only the current 20-card page is eligible');
    assert.ok(new Set(requests().map(source)).size<20,'Offscreen cards on the page remain lazy');
    assert.equal(fixture.state.thumbnailReadConflicts,0);

    // Switch while a real JPEG is in flight, forcing an abort and queue handoff.
    for(const minute of [39,38,37,36]){
      const switchingSource=`${event}/${stamps[minute]}-front.mp4`;
      assert.equal(fixture.state.thumbnailImageAttempts.has(switchingSource),false,'Use an unseen image so decoded-image reuse cannot skip the transfer');
      fixture.state.thumbnailImageDelay=650;
      await search(`20:${minute}:00`);await card(stamps[minute]).scrollIntoViewIfNeeded();
      await until(()=>fixture.state.thumbnailImageAttempts.has(switchingSource),'Grid JPEG starts before switching to the viewer');
      fixture.state.thumbnailImageDelay=35;
      const abortedBeforeSwitch=fixture.state.thumbnailAbortedImages;
      await page.locator('#player [data-mode="overview"]').click();
      await until(()=>page.locator('#player .overview-tile img').evaluateAll(images=>images.filter(i=>i.complete&&i.naturalWidth).length===6),'Overview completes while grid work is pending');
      assert.ok(fixture.state.thumbnailAbortedImages>abortedBeforeSwitch,'Switching to the viewer aborts the old grid transfer');
      assert.equal(fixture.state.thumbnailReadConflicts,0,'Overview and grid never overlap status/JPEG reads');
      assert.equal(fixture.state.maxActiveThumbnailReads,1);
      await page.locator('#player [data-mode="single"]').click();
    }
    await search('');

    // Changing page cannot complete an old image into a different card.
    fixture.state.thumbnailImageDelay=350;
    await page.locator('#page-jump').selectOption('2');
    await until(()=>fixture.state.activeThumbnailReads>0,'Second page begins a still request');
    await search('20:12:00');await card(stamps[12]).scrollIntoViewIfNeeded();
    await until(()=>loaded(card(stamps[12])),'A search renders its own source after cancelling the old page');
    assert.equal(await page.locator('#clip-grid .clip-card').count(),1);
    assert.equal(new URLSearchParams((await card(stamps[12]).locator('img').getAttribute('src')).split('?')[1]).get('path'),`${event}/${stamps[12]}-front.mp4`);

    // A single failed delivery recovers; a broken encoder is never restarted.
    fixture.state.thumbnailImageDelay=0;
    const front11=`${event}/${stamps[11]}-front.mp4`;fixture.state.thumbnailImageFailures.set(front11,1);
    await search('20:11:00');await card(stamps[11]).scrollIntoViewIfNeeded();
    await until(()=>loaded(card(stamps[11])),'Transient image delivery recovers automatically',12000);
    assert.equal(fixture.state.thumbnailImageAttempts.get(front11),2);
    const failed=`${event}/${stamps[10]}-front.mp4`;fixture.state.thumbnailOverrides.set(failed,{state:'failed'});
    const mutations=fixture.state.mutations.length;await search('20:10:00');await card(stamps[10]).scrollIntoViewIfNeeded();
    await until(async()=>(await card(stamps[10]).locator('.clip-thumbnail-note').textContent())==='Still unavailable','Failed worker becomes an honest fallback');
    await sleep(300);assert.equal(fixture.state.mutations.length,mutations,'A failed thumbnail worker is not retried automatically');
    assert.equal(await card(stamps[10]).locator('img').count(),0);

    const broken=`${event}/${stamps[9]}-front.mp4`;fixture.state.thumbnailImageFailures.set(broken,-1);
    await search('20:09:00');await card(stamps[9]).scrollIntoViewIfNeeded();
    await until(async()=>(await card(stamps[9]).locator('.clip-thumbnail-note').textContent())==='Still unavailable','Permanent delivery failure exhausts bounded retries',15000);
    assert.equal(fixture.state.thumbnailImageAttempts.get(broken),3);
    const count=requests().length;await sleep(600);assert.equal(requests().length,count);

    // Leaving Recordings aborts both the active JPEG and queued/polling work.
    fixture.state.thumbnailImageDelay=600;
    const away=`${event}/${stamps[8]}-front.mp4`;
    await search('20:08:00');await card(stamps[8]).scrollIntoViewIfNeeded();
    await until(()=>fixture.state.thumbnailImageAttempts.has(away),'A JPEG is in flight before leaving Recordings');
    await nav('Device');await until(()=>fixture.state.activeThumbnailReads===0,'Leaving Recordings aborts its current JPEG');
    const afterLeave=requests().length;await sleep(800);assert.equal(requests().length,afterLeave,'No hidden grid polls continue on Device');
    assert.equal(await card(stamps[8]).locator('img').count(),0,'The cancelled response does not restore a stale image');
    assert.ok(fixture.state.thumbnailAbortedImages>0);
    assert.equal(fixture.state.requests.some(r=>r.path.startsWith('/api/v1/recordings/preview')),false,'Card stills never start Low-quality video work');

    await nav('Recordings');fixture.state.thumbnailImageDelay=0;await search('20:59:00');await card(stamps[59]).scrollIntoViewIfNeeded();await until(()=>loaded(card(stamps[59])),'Visible card reloads on return');
    const output=process.env.MODERN_SCREENSHOT_DIR||path.join(os.tmpdir(),'teslausb-modern-browser');fs.mkdirSync(output,{recursive:true});
    for(const [label,width,height] of [['desktop',1440,900],['mobile',390,844]]){
      await page.setViewportSize({width,height});await card(stamps[59]).scrollIntoViewIfNeeded();
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,'Cards fit the viewport');
      await page.screenshot({path:path.join(output,`front-card-${label}.png`),fullPage:true});
    }
    await card(stamps[59]).click();await until(()=>page.locator('#player video').evaluateAll(videos=>videos.length===1&&videos[0].readyState>=2),'The thumbnail still opens a playable original');
    assert.match(await page.locator('#player video').getAttribute('src'),/front\.mp4/);
    assert.deepEqual(errors,[]);console.log('PASS: front-card source, queue priority, lazy paging, overview serialization, cancellation, bounded retries, original playback and responsive layout');
  }catch(error){
    console.error('Card thumbnail diagnostics:',{errors,requests:requests().slice(-15),active:fixture.state.activeThumbnailReads,conflicts:fixture.state.thumbnailReadConflicts,
      cards:await page.locator('#clip-grid .clip-image').evaluateAll(buttons=>buttons.slice(0,4).map(button=>({id:button.dataset.open,rect:{top:button.getBoundingClientRect().top,bottom:button.getBoundingClientRect().bottom},note:button.textContent,images:[...button.querySelectorAll('img')].map(image=>({src:image.getAttribute('src'),complete:image.complete,width:image.naturalWidth}))})))});
    throw error;
  }finally{await browser.close();await fixture.close();}
}
await run();
