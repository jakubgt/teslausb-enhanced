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
window.reset=()=>{window.player?.destroy?.();testHidden=false;polls.clear();window.calls=[];window.notices=[];window.navigationCalls=[];window.mediaErrors=[];window.navigateHandler=async()=>{};window.reply=(path)=>ready(path);window.player=new ClipPlayer(document.querySelector('#player'),{api:async(url,options={})=>{const p=new URL(url,location.href).searchParams.get('path');calls.push({path:p,method:options.method||'GET',signal:options.signal});return reply(p,options);},onDownload(){},onTrash(){},onNotice:message=>notices.push(message),onNavigate:(direction,options)=>{navigationCalls.push({direction,...options});return navigateHandler(direction,options);},onMediaError:()=>mediaErrors.push(player.event.id)});return player;};
window.metadata=()=>{for(const video of player.videos){videoState(video).readyState=2;video.dispatchEvent(new Event('loadedmetadata'));}};
reset();window.harnessReady=true;
</script></body></html>`;

async function run() {
  const server = http.createServer((request, response) => {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    if (pathname === '/') { response.setHeader('Content-Type', 'text/html'); response.end(harness); return; }
    if (!['/player.mjs', '/model.mjs', '/thumbnail-loader.mjs'].includes(pathname)) { response.writeHead(404); response.end(); return; }
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
      reset();await player.setEvent(structuredClone(fixture),{quality:'low',playing:true});metadata();
    });
    assert.equal(await page.evaluate(() => player.quality), 'high', 'Old Low preferences migrate to original playback');
    assert.equal(await page.locator('[data-quality]').textContent(), 'Original quality');
    assert.equal(await page.locator('select[data-quality], [data-preview-retry], [data-use-original]').count(), 0);
    assert.equal(await page.evaluate(() => player.master.src.startsWith('/TeslaCam/')&&!player.master.paused), true);
    await page.evaluate(() => {player.master.currentTime=60;player.master.dispatchEvent(new Event('ended'));metadata();});
    assert.equal(await page.evaluate(() => player.segmentIndex===1&&player.playing&&!player.master.paused), true, 'Next minute uses original footage without a preparation wait');
    assert.equal(await page.evaluate(() => calls.length+polls.size), 0, 'Original playback never probes or starts smaller video jobs');
    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'low',mode:'all',playing:true,position:27});metadata();
    });
    assert.deepEqual(await page.evaluate(() => player.videos.map(video=>video.currentTime)), [27,27]);
    assert.equal(await page.evaluate(() => player.videos.every(video=>video.src.startsWith('/TeslaCam/')&&!video.paused)&&calls.length===0&&polls.size===0), true, 'All cameras restore aligned originals, with no encoding requests');

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
      reset();await player.setEvent(structuredClone(fixture),{quality:'low',playing:true});
      window.lateVideo=player.master;testHidden=true;document.dispatchEvent(new Event('visibilitychange'));
      videoState(lateVideo).readyState=2;lateVideo.dispatchEvent(new Event('loadedmetadata'));
    });
    assert.equal(await page.evaluate(() => player.suspended&&player.videos.length===0&&lateVideo.paused&&!lateVideo.src&&calls.length===0), true, 'Hidden tabs release the source and stale metadata cannot resume playback');

    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'high',playing:true});metadata();
      window.releasedVideos=[...player.videos];testHidden=true;document.dispatchEvent(new Event('visibilitychange'));
    });
    assert.equal(await page.evaluate(() => releasedVideos.every(video=>video.paused&&!video.src)&&player.videos.length===0), true, 'Hidden tabs pause and release every original source');

    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'high',playing:true});metadata();
      player.setNavigation({previous:true,next:true,index:2,total:3,scope:'14:00–14:59'});
    });
    assert.equal(await page.getByRole('checkbox',{name:'Play next automatically'}).isChecked(), false, 'Automatic clip advance is off by default');
    assert.equal(await page.locator('[data-clip-context]').textContent(), 'Clip 2 of 3 · 14:00–14:59');
    await page.getByRole('button',{name:'Previous clip',exact:true}).click();
    await page.getByRole('button',{name:'Next clip',exact:true}).click();
    assert.deepEqual(await page.evaluate(() => navigationCalls), [{direction:-1,autoplay:false},{direction:1,autoplay:false}], 'Manual controls request earlier/later clips explicitly');
    assert.equal(await page.evaluate(() => player.playing&&!player.master.paused), true, 'A declined manual navigation preserves active playback');
    await page.evaluate(() => player.setNavigation({previous:true,next:true,index:1,total:3,scope:'Selected recordings'}));
    assert.equal(await page.getByRole('button',{name:'Previous clip',exact:true}).isDisabled(), true, 'Previous cannot wrap from the earliest clip');
    await page.evaluate(() => player.setNavigation({previous:true,next:true,index:3,total:3}));
    assert.equal(await page.getByRole('button',{name:'Next clip',exact:true}).isDisabled(), true, 'Next cannot wrap from the latest clip');
    assert.equal(await page.getByRole('checkbox',{name:'Play next automatically'}).isDisabled(), false, 'Autoplay preference remains editable at the final clip');
    await page.getByRole('checkbox',{name:'Play next automatically'}).check();
    await page.getByRole('checkbox',{name:'Play next automatically'}).uncheck();
    await page.evaluate(() => player.setNavigation({previous:true,next:true,index:0,total:3,scope:'this hour'}));
    assert.equal(await page.locator('[data-clip-context]').textContent(), 'Current clip is outside this hour · 3 clips');
    assert.equal(await page.getByRole('button',{name:'Next clip',exact:true}).isDisabled(), true, 'A clip outside the filter cannot navigate into an unrelated queue');
    await page.evaluate(() => player.setNavigation({previous:true,next:true,index:2,total:3,scope:'Saved',blocked:true}));
    assert.equal(await page.getByRole('button',{name:'Previous clip',exact:true}).isDisabled(), true, 'Busy or blocked library state disables navigation');
    assert.equal(await page.getByRole('checkbox',{name:'Play next automatically'}).isDisabled(), true);
    await page.evaluate(() => {player.setNavigation({...player.navigation,blocked:false});player.q('[data-autoplay-next]').checked=true;player.suspend();});
    assert.equal(await page.getByRole('button',{name:'Next clip',exact:true}).isDisabled(), true, 'Suspended views disable navigation');
    await page.evaluate(() => player.resume());
    assert.equal(await page.getByRole('button',{name:'Next clip',exact:true}).isDisabled(), false, 'Resuming restores the existing queue');
    assert.equal(await page.getByRole('checkbox',{name:'Play next automatically'}).isChecked(), true, 'Suspend/resume preserves the autoplay preference');

    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'high',playing:true});metadata();
      player.setNavigation({previous:false,next:true,index:1,total:2,scope:'Selected recordings'});player.q('[data-autoplay-next]').checked=true;
      navigateHandler=()=>new Promise(resolve=>window.finishNavigation=resolve);
      player.master.currentTime=60;player.master.dispatchEvent(new Event('ended'));metadata();
    });
    assert.equal(await page.evaluate(() => player.segmentIndex), 1, 'Within-event segment chaining is preserved');
    assert.deepEqual(await page.evaluate(() => navigationCalls), [], 'First segment completion does not skip the rest of the clip');
    await page.evaluate(() => {player.master.currentTime=60;player.master.dispatchEvent(new Event('ended'));player.master.dispatchEvent(new Event('ended'));});
    assert.deepEqual(await page.evaluate(() => navigationCalls), [{direction:1,autoplay:true}], 'Final segment requests automatic next once even if ended repeats');
    assert.equal(await page.evaluate(() => player.videos.every(video=>video.paused)), true, 'Outgoing cameras stop while navigation is pending');
    await page.evaluate(async () => {finishNavigation();await Promise.resolve();});
    assert.equal(await page.evaluate(() => player.playing), false, 'A refused automatic transition stops cleanly at the end');

    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'high',playing:true,camera:'back',mode:'all',rate:2,position:60});metadata();
      player.setNavigation({previous:false,next:true,index:1,total:2});player.q('[data-autoplay-next]').checked=true;
      navigateHandler=async(_direction,{autoplay})=>{const saved=player.snapshot();await player.setEvent({...structuredClone(fixture),id:'next-clip'},{...saved,position:0,playing:autoplay||saved.playing});player.setNavigation({previous:true,next:false,index:2,total:2});metadata();};
      player.master.currentTime=60;player.master.dispatchEvent(new Event('ended'));
    });
    await page.waitForFunction(() => !player.navigating);
    assert.deepEqual(await page.evaluate(() => ({id:player.event.id,position:player.position,camera:player.camera,mode:player.mode,quality:player.quality,rate:player.rate,playing:player.playing})), {id:'next-clip',position:0,camera:'back',mode:'all',quality:'high',rate:2,playing:true}, 'Navigation callback can preserve the viewer preferences and playback intent at the next clip start');
    assert.equal(await page.getByRole('checkbox',{name:'Play next automatically'}).isChecked(), true, 'A new clip keeps the autoplay preference');

    for(const stopReason of ['unchecked','paused','master-error','follower-error','play-rejected','hidden','suspended','blocked','queue-end']){
      await page.evaluate(async reason => {
        reset();await player.setEvent(structuredClone(fixture),{quality:'high',playing:true,mode:'all',position:60});metadata();
        player.setNavigation({previous:false,next:true,index:1,total:2});player.q('[data-autoplay-next]').checked=reason!=='unchecked';
        const outgoingMaster=player.master;
        if(reason==='paused')await player.toggle();
        if(reason==='master-error')outgoingMaster.dispatchEvent(new Event('error'));
        if(reason==='follower-error')player.videos.find(video=>video!==outgoingMaster).dispatchEvent(new Event('error'));
        if(reason==='play-rejected'){player.stopPlayback();videoState(outgoingMaster).fail=true;await player.toggle();}
        if(reason==='hidden'){testHidden=true;document.dispatchEvent(new Event('visibilitychange'));}
        if(reason==='suspended')player.suspend();
        if(reason==='blocked')player.setNavigation({...player.navigation,blocked:true});
        if(reason==='queue-end')player.setNavigation({previous:true,next:true,index:2,total:2});
        outgoingMaster.dispatchEvent(new Event('ended'));await Promise.resolve();
      },stopReason);
      assert.deepEqual(await page.evaluate(() => navigationCalls), [], `No automatic next after ${stopReason}`);
    }

    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'high',playing:true});metadata();
      player.setNavigation({previous:false,next:true,index:1,total:2});navigateHandler=()=>new Promise((_resolve,reject)=>window.rejectNavigation=reject);
      window.pendingNavigation=player.navigateClip(1);
      await player.setEvent({...structuredClone(fixture),id:'independent-selection'},{quality:'high',playing:true});metadata();
      rejectNavigation(new Error('Late navigation failure'));await pendingNavigation;
    });
    assert.equal(await page.evaluate(() => player.event.id==='independent-selection'&&player.playing&&!player.master.paused&&notices.length===0), true, 'A stale navigation failure cannot stop a newer independent selection');
    await page.evaluate(async () => {
      reset();await player.setEvent(structuredClone(fixture),{quality:'high'});window.oldVideo=player.master;
      await player.setEvent({...structuredClone(fixture),id:'current-media'},{quality:'high'});
      oldVideo.dispatchEvent(new Event('error'));player.master.dispatchEvent(new Event('error'));
    });
    assert.deepEqual(await page.evaluate(() => mediaErrors), ['current-media'], 'Only current-generation media errors notify the caller for a separate connection probe');
    await page.evaluate(() => player.destroy());
    assert.deepEqual(errors, []);
    console.log('Modern player browser regressions passed.');
  } finally {
    await browser?.close();
    await new Promise(resolve => server.close(resolve));
  }
}
run().catch(error => {console.error(error);process.exitCode=1;});
