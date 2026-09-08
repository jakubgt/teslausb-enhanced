'use strict';
// Exercise the production player against deterministic browser media events.
// Media timing/API responses are controlled here; no Pi or real footage is read.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const {chromium} = require('playwright');

const root = path.resolve(__dirname, '../teslausb-www/html/modern');
const harness = `<!doctype html><html><body><div id="player"></div><script type="module">
import {ClipPlayer} from '/player.mjs';
window.testHidden=false;Object.defineProperty(document,'hidden',{configurable:true,get:()=>window.testHidden});
const states=new WeakMap();window.videoState=video=>{if(!states.has(video))states.set(video,{paused:true,currentTime:0,readyState:0,src:'',playCalls:0});return states.get(video);};
const originalRemove=HTMLMediaElement.prototype.removeAttribute;
HTMLMediaElement.prototype.removeAttribute=function(name){if(name==='src')videoState(this).src='';return originalRemove.call(this,name);};
Object.defineProperties(HTMLMediaElement.prototype,{
  src:{configurable:true,get(){return videoState(this).src;},set(value){videoState(this).src=value;}},
  paused:{configurable:true,get(){return videoState(this).paused;}},
  currentTime:{configurable:true,get(){return videoState(this).currentTime;},set(value){videoState(this).currentTime=value;}},
  readyState:{configurable:true,get(){return videoState(this).readyState;}},
  duration:{configurable:true,get(){return 60;}},
  play:{configurable:true,value(){const s=videoState(this);s.playCalls++;s.paused=false;if(s.fail)return Promise.reject(new Error('Fixture playback failure'));if(s.defer)return new Promise((resolve,reject)=>{s.resolve=resolve;s.reject=reject;});return Promise.resolve();}},
  pause:{configurable:true,value(){videoState(this).paused=true;}},
  load:{configurable:true,value(){videoState(this).readyState=0;}}
});
const nativeTimeout=window.setTimeout.bind(window),nativeClear=window.clearTimeout.bind(window);let timerId=-1;window.polls=new Map();
window.setTimeout=(fn,delay,...args)=>{if(delay===5000){const id=timerId--;polls.set(id,()=>fn(...args));return id;}return nativeTimeout(fn,delay,...args);};
window.clearTimeout=id=>{if(polls.has(id))polls.delete(id);else nativeClear(id);};
window.firePoll=async()=>{const entry=polls.entries().next().value;if(!entry)throw new Error('Expected a preview poll');polls.delete(entry[0]);await entry[1]();};
window.fixture={id:'SentryClips/2026-09-07_14-30-00',event:'SentryClips/2026-09-07_14-30-00',group:'SentryClips',category:'Sentry',start:'2026-09-07_14-29-00',duration:120,cameras:['front','back'],metadata:null,segments:['2026-09-07_14-29-00','2026-09-07_14-30-00'].map(stamp=>({stamp,files:Object.fromEntries(['front','back'].map(camera=>[camera,{path:'SentryClips/2026-09-07_14-30-00/'+stamp+'-'+camera+'.mp4',url:'/TeslaCam/'+stamp+'-'+camera+'.mp4'}]))}))};
window.ready=path=>({state:'ready',reason:'preview_ready',preview_url:'/api/v1/recordings/preview/media?'+new URLSearchParams({path})});
window.reset=()=>{window.player?.destroy?.();testHidden=false;polls.clear();window.calls=[];window.notices=[];window.reply=(path)=>ready(path);window.player=new ClipPlayer(document.querySelector('#player'),{api:async(url,options={})=>{const p=new URL(url,location.href).searchParams.get('path');calls.push({path:p,method:options.method||'GET',signal:options.signal});return reply(p,options);},onDownload(){},onTrash(){},onNotice:message=>notices.push(message)});return player;};
window.metadata=()=>{for(const video of player.videos){videoState(video).readyState=2;video.dispatchEvent(new Event('loadedmetadata'));}};
reset();window.harnessReady=true;
</script></body></html>`;

async function run() {
  const server = http.createServer((request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    if (pathname === '/') { response.setHeader('Content-Type', 'text/html'); response.end(harness); return; }
    if (!['/player.mjs', '/model.mjs'].includes(pathname)) { response.writeHead(404); response.end(); return; }
    response.setHeader('Content-Type', 'text/javascript');
    fs.createReadStream(path.join(root, pathname.slice(1))).pipe(response);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome', headless: true});
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto(`http://127.0.0.1:${server.address().port}`);
    await page.waitForFunction(() => window.harnessReady);

    await page.evaluate(async () => {
      reset();window.secondReady=false;
      reply=path=>path.includes('_14-30-00-front')&&!secondReady?{state:'preparing',reason:'preview_preparing'}:ready(path);
      await player.setEvent(structuredClone(fixture),{quality:'low',playing:true});
    });
    await page.waitForFunction(() => player.videos.length===1);
    await page.evaluate(() => {metadata();player.master.currentTime=60;player.master.dispatchEvent(new Event('ended'));});
    await page.waitForFunction(() => player.segmentIndex===1&&polls.size===1&&!player.master);
    assert.equal(await page.evaluate(() => player.playing), true, 'Desired playback survives a preparing next segment');
    assert.equal(await page.locator('[data-play]').isDisabled(), false, 'Pending playback can still be paused');
    await page.evaluate(async () => {secondReady=true;await firePoll();});
    await page.waitForFunction(() => player.segmentIndex===1&&player.videos.length===1);
    await page.evaluate(() => metadata());
    assert.equal(await page.evaluate(() => player.playing&&!player.master.paused), true, 'Ready next segment resumes playback automatically');

    await page.evaluate(async () => {
      reset();window.busy=true;reply=(path,options)=>busy?(options.method==='POST'?{state:'unavailable',reason:'preview_worker_busy'}:{state:'not_requested',reason:'preview_not_requested'}):ready(path);
      await player.setEvent(structuredClone(fixture),{quality:'low',playing:true});
    });
    await page.waitForFunction(() => polls.size===1);
    await page.evaluate(async () => {busy=false;await firePoll();});
    await page.waitForFunction(() => player.videos.length===1);
    assert.equal(await page.evaluate(() => player.playing), true, 'A busy worker is checked again without losing desired playback');

    await page.evaluate(async () => {
      reset();window.job='failed';reply=(_path,options)=>options.method==='POST'?(job='preparing',{state:job,reason:'preview_preparing'}):{state:job,reason:'preview_'+job};
      await player.setEvent(structuredClone(fixture),{quality:'low'});
    });
    await page.waitForFunction(() => calls.length===1);
    assert.equal(await page.evaluate(() => calls.filter(c=>c.method==='POST').length), 0, 'Failed encoding must not automatically loop');
    await page.locator('[data-preview-retry]').click();
    await page.waitForFunction(() => polls.size===1);
    assert.equal(await page.evaluate(() => calls.filter(c=>c.method==='POST').length), 1, 'Explicit Retry restarts a failed job');
    await page.evaluate(async () => {job='failed';await firePoll();});
    await page.waitForFunction(() => polls.size===0);
    assert.equal(await page.evaluate(() => calls.filter(c=>c.method==='POST').length), 1, 'A second encoding failure waits for another explicit retry');

    await page.evaluate(async () => {
      reset();window.backReady=false;reply=path=>path.endsWith('-back.mp4')&&!backReady?{state:'preparing',reason:'preview_preparing'}:ready(path);
      await player.setEvent(structuredClone(fixture),{quality:'low',mode:'all',playing:true});
    });
    await page.waitForFunction(() => player.videos.length===1&&polls.size===1);
    await page.evaluate(async () => {metadata();player.master.currentTime=27;window.originalMaster=player.master;await firePoll();});
    assert.equal(await page.evaluate(() => player.master===originalMaster), true, 'Unchanged preparation does not reload an already playing camera');
    await page.evaluate(async () => {backReady=true;await firePoll();});
    await page.waitForFunction(() => player.videos.length===2);
    await page.evaluate(() => metadata());
    assert.deepEqual(await page.evaluate(() => player.videos.map(video=>video.currentTime)), [27,27], 'New ready camera joins at the preserved playback position');

    await page.evaluate(async () => {reset();await player.setEvent(structuredClone(fixture),{quality:'high',mode:'all',playing:true});metadata();});
    await page.evaluate(() => {player.master.currentTime=19;player.master.dispatchEvent(new Event('waiting'));});
    assert.equal(await page.evaluate(() => player.videos.filter(video=>video!==player.master).every(video=>video.paused)), true, 'Followers pause when the master buffers');
    await page.evaluate(() => player.master.dispatchEvent(new Event('playing')));
    assert.equal(await page.evaluate(() => player.videos.every(video=>!video.paused&&video.currentTime===19)), true, 'Followers resume aligned with the master');
    await page.evaluate(() => player.master.dispatchEvent(new Event('error')));
    assert.equal(await page.evaluate(() => !player.playing&&player.videos.every(video=>video.paused)), true, 'Master failure stops all streams');

    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'high',mode:'all'});metadata();
      const follower=player.videos[1];videoState(follower).defer=true;const pending=player.toggle();
      const rejectOld=videoState(follower).reject;player.master.dispatchEvent(new Event('waiting'));
      videoState(follower).defer=false;player.master.dispatchEvent(new Event('playing'));
      rejectOld(new DOMException('Interrupted by the synchronization pause','AbortError'));await pending;
    });
    assert.equal(await page.evaluate(() => player.playing&&player.videos.every(video=>!video.paused)), true, 'Intentional buffering pause rejection cannot stop resumed playback');

    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'high',mode:'all'});metadata();
      videoState(player.videos[1]).fail=true;await player.toggle();
    });
    assert.equal(await page.evaluate(() => !player.playing&&player.videos.every(video=>video.paused)), true, 'Any play rejection stops all camera streams');

    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'high'});metadata();
      const old=player.master;videoState(old).defer=true;const pending=player.toggle();
      await player.setEvent({...structuredClone(fixture),id:'new-event'},{quality:'high',playing:true});metadata();
      videoState(old).reject(new Error('Late rejection from previous recording'));await pending;
    });
    assert.equal(await page.evaluate(() => player.event.id==='new-event'&&player.playing&&player.videos.every(video=>!video.paused)), true, 'A stale play promise cannot stop the newly selected recording');

    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'high'});player.marker=15;player.renderMarker();
      await player.setEvent({...structuredClone(fixture),id:'without-marker'},{quality:'high'});
    });
    assert.equal(await page.locator('.event-tick').isHidden(), true, 'A new recording clears the previous Sentry marker');

    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'low',playing:true,suspended:true});
    });
    assert.equal(await page.evaluate(() => calls.length===0&&player.videos.length===0&&player.suspended), true, 'Suspended restoration never starts API or media traffic');
    await page.evaluate(async () => {
      reset();reply=path=>new Promise(resolve=>{window.latePreview=()=>resolve(ready(path));});
      await player.setEvent(structuredClone(fixture),{quality:'low',playing:true});
      testHidden=true;document.dispatchEvent(new Event('visibilitychange'));latePreview();
    });
    await page.waitForFunction(() => calls.length===1&&calls[0].signal.aborted);
    assert.equal(await page.evaluate(() => player.suspended&&player.videos.length===0&&polls.size===0), true, 'Hidden tabs abort pending checks and cannot attach a late video');

    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'high',playing:true});metadata();
      window.releasedVideos=[...player.videos];testHidden=true;document.dispatchEvent(new Event('visibilitychange'));
    });
    assert.equal(await page.evaluate(() => releasedVideos.every(video=>video.paused&&!video.src)&&player.videos.length===0), true, 'Hidden tabs pause and release every original source');
    await page.evaluate(() => player.destroy());
    assert.deepEqual(errors, []);
    console.log('Modern player browser regressions passed.');
  } finally {
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
  }
}
run().catch(error => {console.error(error);process.exitCode=1;});
