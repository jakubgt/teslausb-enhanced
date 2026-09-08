/* End-to-end checks against the actual modern shell and a localhost-only fixture
 * server. Requires Playwright in NODE_PATH and installed Chrome (or set
 * PLAYWRIGHT_CHANNEL). No production frontend is mocked or modified. */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';
import {createPreviewServer, NEWEST_DAY, FIRST_EVENT} from '../tools/modern-preview-server.mjs';
const require = createRequire(import.meta.url);
const {chromium} = require('playwright');

async function run() {
  const fixture = await createPreviewServer();
  const browser = await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL||'chrome',headless:true});
  const output = process.env.MODERN_SCREENSHOT_DIR || path.join(os.tmpdir(),'teslausb-modern-browser');
  fs.mkdirSync(output,{recursive:true});
  const errors=[];
  const context=await browser.newContext({viewport:{width:1440,height:1150},locale:'en-US',reducedMotion:'reduce',acceptDownloads:true});
  const page=await context.newPage();page.on('pageerror',error=>errors.push(error.message));
  const waitMedia=async(count=1)=>page.waitForFunction(count=>{const videos=[...document.querySelectorAll('#player video')];return videos.length===count&&videos.every(v=>v.readyState>=2&&!v.error);},count);
  const position=()=>page.locator('#player [data-position]').inputValue().then(Number);
  const seek=async value=>{await page.locator('#player [data-position]').evaluate((input,value)=>{input.value=String(value);input.dispatchEvent(new Event('input',{bubbles:true}));},value);await page.waitForFunction(value=>Math.abs(Number(document.querySelector('#player [data-position]').value)-value)<.5,value);};
  const screenshot=async name=>page.screenshot({path:path.join(output,name+'.png'),fullPage:true});
  const nav=async name=>page.getByRole('navigation',{name:'Main navigation'}).getByRole('button',{name:new RegExp('^'+name+'(?: \\d+)?$')}).click();
  const noOverflow=async label=>assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),true,label+' must not overflow horizontally');
  const hideDocument=()=>page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});document.dispatchEvent(new Event('visibilitychange'));});
  const showDocument=()=>page.evaluate(()=>{delete document.hidden;document.dispatchEvent(new Event('visibilitychange'));});
  const pageHide=()=>page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true})));
  const pageShow=()=>page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})));
  const assertCameraGrid=async(columns,rows)=>{
    const grid=await page.locator('#player .video-cell').evaluateAll(cells=>({columns:new Set(cells.map(cell=>Math.round(cell.getBoundingClientRect().left))).size,rows:new Set(cells.map(cell=>Math.round(cell.getBoundingClientRect().top))).size}));
    assert.deepEqual(grid,{columns,rows});
  };
  const zipNames=buffer=>{
    const names=[];let offset=0;
    while(offset+30<=buffer.length&&buffer.readUInt32LE(offset)===0x04034b50){const length=buffer.readUInt16LE(offset+26),extra=buffer.readUInt16LE(offset+28),size=buffer.readUInt32LE(offset+18);names.push(buffer.toString('utf8',offset+30,offset+30+length));offset+=30+length+extra+size;}
    return names;
  };
  try {
    await page.goto(fixture.url);
    await page.locator('#library-state').filter({hasText:'4 recordings available'}).waitFor();
    assert.equal(await page.locator('#recording-day').inputValue(),'latest');
    assert.match(await page.locator('#recording-day option:checked').textContent(),new RegExp(NEWEST_DAY));
    assert.equal(await page.locator('#clip-grid .clip-card').count(),4);
    assert.equal(await page.locator('#clip-grid').textContent().then(text=>text.includes('2026-09-06')),false);
    await page.getByText(/Local test fixtures/).waitFor();
    await page.locator('[data-quality-status]').filter({hasText:'Low preview is unavailable'}).waitFor();
    assert.equal(await page.locator('#player video').count(),0);
    await page.getByRole('button',{name:'Play original',exact:true}).click();await waitMedia();
    await page.waitForFunction(()=>document.querySelector('#player video')?.currentTime>0);
    const duration=await page.locator('#player video').evaluate(video=>video.duration);
    assert.ok(duration>=60,'Synthetic recording must cover a full 60-second segment; actual duration '+duration);
    await page.getByRole('button',{name:'Pause recording',exact:true}).click();
    await seek(15);await page.getByRole('button',{name:'Skip forward 10 seconds'}).click();assert.ok(Math.abs(await position()-25)<1);
    await page.getByRole('button',{name:'Skip back 10 seconds'}).click();assert.ok(Math.abs(await position()-15)<1);
    await page.getByRole('button',{name:'Jump to event',exact:true}).click();assert.ok(Math.abs(await position()-15)<1);
    assert.equal(await page.locator('.event-tick').isVisible(),true);
    assert.equal(await page.locator('#player [data-camera]').count(),6,'All six recorded camera angles are offered');
    for(const [camera,label]of [['left_pillar','Left pillar'],['right_pillar','Right pillar']]){
      await page.getByRole('group',{name:'Focused camera'}).getByRole('button',{name:label,exact:true}).click();await waitMedia();
      assert.equal(await page.locator('#player video').getAttribute('aria-label'),`${label} recording`);assert.ok(Math.abs(await position()-15)<1);
      await page.getByRole('button',{name:`Download ${label}`,exact:true}).click();const row=page.locator('.download-row').last();await row.getByRole('link',{name:'Save ZIP'}).waitFor();assert.match(await row.textContent(),/2 original file/);
      const request=fixture.state.requests.filter(request=>request.path==='/api/v1/recordings/download').at(-1);assert.equal(new URLSearchParams(request.query).get('camera'),camera);
      const event=page.waitForEvent('download');await row.getByRole('link',{name:'Save ZIP'}).click();const result=await event;const names=zipNames(fs.readFileSync(await result.path()));assert.equal(names.length,2);assert.ok(names.every(name=>name.endsWith(`-${camera}.mp4`)),'Pillar download contains only the selected camera');await row.getByRole('button',{name:'Dismiss',exact:true}).click();await waitMedia();
    }
    await page.getByRole('group',{name:'Focused camera'}).getByRole('button',{name:'Rear',exact:true}).click();await waitMedia();assert.ok(Math.abs(await position()-15)<1);
    assert.equal(await page.locator('#player video').getAttribute('aria-label'),'Rear recording');
    await page.getByRole('button',{name:'All cameras',exact:true}).click();await waitMedia(6);await assertCameraGrid(3,2);
    await page.getByRole('button',{name:'Play recording',exact:true}).click();await page.waitForFunction(()=>[...document.querySelectorAll('#player video')].every(video=>!video.paused&&video.currentTime>15));
    await page.getByRole('button',{name:'Pause recording',exact:true}).click();
    const times=await page.locator('#player video').evaluateAll(videos=>videos.map(video=>video.currentTime));assert.ok(Math.max(...times)-Math.min(...times)<.6,'All camera playback stays synchronized');
    await page.getByRole('combobox',{name:'Playback speed'}).selectOption('2');assert.ok((await page.locator('#player video').evaluateAll(videos=>videos.map(video=>video.playbackRate))).every(value=>value===2));
    await seek(21);
    await page.locator('#refresh-recordings').click();await page.locator('#library-state').filter({hasText:'4 recordings available'}).waitFor();await waitMedia(6);
    await pageHide();assert.equal(await page.locator('#player video[src]').count(),0);await pageShow();await waitMedia(6);assert.ok(Math.abs(await position()-21)<1,'Restoring a cached page retains the player position');
    assert.ok(Math.abs(await position()-21)<1,'Refresh preserves position');assert.equal(await page.locator('[data-camera="back"]').getAttribute('aria-pressed'),'true');assert.equal(await page.locator('[data-quality]').inputValue(),'high');
    fixture.state.failVideos=true;await page.locator('#refresh-recordings').click();await page.locator('#library-state').filter({hasText:'Showing the previous list'}).waitFor();assert.equal(await page.locator('#clip-grid .clip-card').count(),4);await waitMedia(6);fixture.state.failVideos=false;
    fixture.state.previewState='ready';await page.locator('[data-quality]').selectOption('low');await waitMedia(6);await page.locator('[data-quality-status]').filter({hasText:'Low preview ·'}).waitFor();
    assert.ok((await page.locator('#player video').evaluateAll(videos=>videos.map(video=>video.getAttribute('src')))).every(src=>src.startsWith('/api/v1/recordings/preview/media?')));
    await page.locator('#refresh-recordings').click();await page.locator('#library-state').filter({hasText:'4 recordings available'}).waitFor();await waitMedia(6);
    await page.locator('#theme-toggle').click();await screenshot('recordings-desktop-dark');await noOverflow('Desktop recordings');
    console.log('PASS: latest day, low/high playback, all cameras, event navigation, and refresh continuity');

    await page.getByRole('button',{name:'Download Rear',exact:true}).click();await page.locator('.download-row').last().getByRole('link',{name:'Save ZIP'}).waitFor();
    assert.match(await page.locator('.download-row').last().textContent(),/2 original file/);
    const downloadEvent=page.waitForEvent('download');await page.locator('.download-row').last().getByRole('link',{name:'Save ZIP'}).click();const download=await downloadEvent;const content=fs.readFileSync(await download.path());assert.equal(content.readUInt32LE(0),0x04034b50);await page.locator('.download-row').last().getByRole('button',{name:'Dismiss',exact:true}).click();
    await page.getByRole('button',{name:'Download all cameras',exact:true}).click();await page.locator('.download-row').last().getByRole('link',{name:'Save ZIP'}).waitFor();assert.match(await page.locator('.download-row').last().textContent(),/12 original file/);await page.locator('.download-row').last().getByRole('button',{name:'Cancel',exact:true}).click();
    fixture.state.downloadDelay=1200;await page.getByRole('button',{name:'Download all cameras',exact:true}).click();await page.locator('.download-row').getByRole('button',{name:'Cancel',exact:true}).click();assert.equal(await page.locator('.download-row').count(),0);fixture.state.downloadDelay=0;
    fixture.state.failDownload=true;await page.getByRole('button',{name:'Download all cameras',exact:true}).click();await page.getByRole('button',{name:'Retry',exact:true}).waitFor();fixture.state.failDownload=false;await page.getByRole('button',{name:'Retry',exact:true}).click();await page.locator('.download-row').getByRole('link',{name:'Save ZIP'}).waitFor();await page.locator('.download-row').getByRole('button',{name:'Cancel',exact:true}).click();
    console.log('PASS: original downloads, ZIP handoff, cancel, and error/retry');

    const first=fixture.state.events.find(event=>event.event===FIRST_EVENT),completeFiles=[...first.files];
    first.files=completeFiles.filter(file=>!['left_pillar','right_pillar'].includes(file.camera));
    await page.locator('#refresh-recordings').click();await page.locator('#library-state').filter({hasText:'4 recordings available'}).waitFor();await waitMedia(4);assert.equal(await page.locator('#player [data-camera]').count(),4);await assertCameraGrid(2,2);
    first.files=completeFiles.filter(file=>file.name!==`${first.stamps[1]}-right_pillar.mp4`);
    await page.locator('#refresh-recordings').click();await page.locator('#library-state').filter({hasText:'4 recordings available'}).waitFor();await waitMedia(6);
    await page.locator('[data-quality]').selectOption('high');await waitMedia(6);await seek(75);await waitMedia(5);
    assert.equal(await page.locator('#player .video-cell').count(),6);assert.equal(await page.locator('#player .video-error').filter({hasText:'This camera is missing for this segment.'}).count(),1);assert.equal(await page.locator('#player [data-camera="right_pillar"]').count(),1,'A camera present in another segment remains selectable');
    first.files=completeFiles;await page.locator('#refresh-recordings').click();await page.locator('#library-state').filter({hasText:'4 recordings available'}).waitFor();await waitMedia(6);await seek(21);await waitMedia(6);
    console.log('PASS: left/right pillar selection and downloads, older four-camera events, and a missing segment camera');

    await nav('Device');assert.equal(await page.locator('#player video[src]').count(),0,'Leaving recordings releases all video sources');await page.getByText(/Status refreshed/).waitFor();
    await page.getByRole('tab',{name:'Archive',exact:true}).click();await page.getByRole('button',{name:'Sync now',exact:true}).click();await page.getByText(/Archive sync requested/).first().waitFor();
    await page.getByRole('tab',{name:'Diagnostics & logs'}).click();await page.getByText(/Complete saved file captured/).waitFor();await page.locator('[data-device="search"]').fill('DEBUG');assert.match(await page.locator('[data-device="log-text"]').textContent(),/^.*DEBUG.*$/);
    await page.getByRole('button',{name:'View full capture',exact:true}).click();assert.match(await page.locator('dialog.device-log-dialog pre').textContent(),/Checking storage/);await page.locator('dialog.device-log-dialog').getByRole('button',{name:'Close',exact:true}).click();
    await page.getByRole('button',{name:'Generate fresh diagnostics',exact:true}).click();await page.locator('[data-device="log-status"]').filter({hasText:'Complete saved file captured'}).waitFor();
    await page.locator('[data-log="archiveloop"]').click();await page.getByText(/Only the latest 8 MiB/).waitFor();
    await page.getByRole('tab',{name:'Tools',exact:true}).click();await page.getByRole('button',{name:'Run 15-second test',exact:true}).click();await page.getByRole('button',{name:'Cancel speed test',exact:true}).click();await page.getByText('Speed test cancelled.',{exact:true}).waitFor();
    page.once('dialog',dialog=>dialog.dismiss());await page.getByRole('button',{name:'Repair USB',exact:true}).click();assert.equal(fixture.state.mutations.filter(item=>item.path==='/api/v1/actions/drives/repair').length,0);
    page.once('dialog',dialog=>dialog.accept());await page.getByRole('button',{name:'Repair USB',exact:true}).click();await page.getByText('USB gadget rebuilt and verified.',{exact:true}).first().waitFor();
    await screenshot('device-tools-desktop-dark');await noOverflow('Desktop Device');
    await page.waitForFunction(()=>!document.querySelector('[data-device="refresh"]').disabled);
    page.once('dialog',dialog=>dialog.accept());await page.getByRole('button',{name:'Shut down TeslaUSB',exact:true}).click();await page.locator('[data-device="power-status"]').filter({hasText:'Shutdown queued'}).waitFor();
    const pendingStart=fixture.state.requests.length;
    await nav('Recordings');assert.equal(await page.locator('#device-page').isVisible(),true,'Pending power action keeps the status controls available');assert.equal(await page.locator('#player video[src]').count(),0,'Pending shutdown cannot resume recording streams through navigation');
    await pageHide();await pageShow();await page.getByRole('tab',{name:'Tools',exact:true}).click();
    assert.equal(await page.getByRole('button',{name:'Shut down TeslaUSB',exact:true}).isDisabled(),true,'Browser cache restoration preserves the pending power state');assert.equal(fixture.state.requests.slice(pendingStart).some(item=>item.path==='/api/v1/status'),false,'Remount does not perform an automatic power recovery check');
    await page.getByRole('button',{name:'Refresh status',exact:true}).click();await page.getByText(/Status refreshed/).waitFor();assert.equal(await page.getByRole('button',{name:'Shut down TeslaUSB',exact:true}).isEnabled(),true);
    assert.ok(fixture.state.mutations.filter(item=>item.path.startsWith('/api/v1/actions/')).every(item=>item.method==='POST'&&item.headers['x-teslausb-request']==='1'));
    await nav('Files');await page.getByText(/Available drives:/).waitFor();await page.getByRole('option',{name:'Evening drive.wav',exact:true}).waitFor();await page.getByRole('option',{name:'Evening drive.wav',exact:true}).click();assert.equal(await page.getByRole('button',{name:'Rename selected item',exact:true}).isVisible(),true);
    await page.getByRole('option',{name:'Evening drive.wav',exact:true}).dblclick();await page.locator('.files-audio-dialog audio[src]').waitFor();await hideDocument();assert.equal(await page.locator('.files-audio-dialog audio[src]').count(),0,'Hidden browser tabs release Files audio');await showDocument();
    await page.getByRole('option',{name:'Evening drive.wav',exact:true}).dblclick();await page.locator('.files-audio-dialog audio[src]').waitFor();await pageHide();assert.equal(await page.locator('.files-audio-dialog audio[src]').count(),0);await pageShow();await page.getByRole('option',{name:'Evening drive.wav',exact:true}).waitFor();assert.equal(await page.locator('.files-root').count(),1,'Cached page restoration remounts Files once');
    await page.getByRole('combobox',{name:'Storage area'}).selectOption({label:'LightShow'});await page.getByRole('option',{name:'lightshow.fseq',exact:true}).waitFor();await screenshot('files-desktop-dark');await noOverflow('Desktop Files');
    console.log('PASS: device logs, actions, speed cancellation, and configured files');

    await nav('Recordings');await waitMedia(6);await page.locator('#player [data-trash]').click();await page.locator('#move-confirm').click();await page.getByText(/1 recordings moved to Trash/).waitFor();assert.equal(fixture.state.trash.size,1);assert.equal(await page.locator('#clip-grid .clip-card').count(),3);
    await page.getByRole('button',{name:'Undo',exact:true}).click();await page.getByText('Recordings restored.',{exact:true}).waitFor();assert.equal(await page.locator('#clip-grid .clip-card').count(),4,'Undo restores the moved recording using status.items');assert.equal([...fixture.state.trash.values()][0].state,'restored');
    await page.locator(`#clip-grid [data-open="${FIRST_EVENT}"]`).first().click();await page.locator('#player [data-trash]').click();await page.locator('#move-confirm').click();await page.getByText(/1 recordings moved to Trash/).waitFor();assert.equal(await page.locator('#clip-grid .clip-card').count(),3);
    await nav('Trash');await page.locator('.trash-item').waitFor();assert.match(await page.locator('.trash-item').textContent(),/2026-09-08/);await page.getByRole('button',{name:'View clip',exact:true}).click();await page.locator('.trash-preview video').waitFor();await page.waitForFunction(()=>document.querySelector('.trash-preview video')?.readyState>=2);await screenshot('trash-desktop-dark');
    await hideDocument();assert.equal(await page.locator('.trash-preview video[src]').count(),0,'Hidden browser tabs release Trash preview');await showDocument();await page.getByRole('button',{name:'View clip',exact:true}).click();await page.locator('.trash-preview video[src]').waitFor();await nav('Device');assert.equal(await page.locator('.trash-preview video[src]').count(),0,'Leaving Trash releases preview');await nav('Trash');await page.getByRole('button',{name:'View clip',exact:true}).click();await page.waitForFunction(()=>document.querySelector('.trash-preview video')?.readyState>=2);
    await page.getByRole('button',{name:'Restore',exact:true}).click();await page.getByText(/restored to the library/).first().waitFor();assert.equal([...fixture.state.trash.values()][0].state,'restored');await nav('Recordings');await page.locator('#clip-grid .clip-card').filter({hasText:'Restored'}).waitFor();assert.equal(await page.locator('#clip-grid .clip-card').count(),4);
    await page.locator(`#clip-grid [data-open="${FIRST_EVENT}"]`).first().click();await page.locator('[data-quality-status]').filter({hasText:'Low preview is unavailable'}).waitFor();await page.getByRole('button',{name:'Play original',exact:true}).click();await waitMedia(6);await page.getByRole('button',{name:'Pause recording',exact:true}).click();
    await page.reload();await page.locator('#library-state').filter({hasText:'4 recordings available'}).waitFor();assert.equal(await page.locator('#clip-grid .clip-card').filter({hasText:'Restored'}).count(),1,'Restored fixture survives page reload');
    console.log('PASS: trash move, original preview, restore, and reload persistence');

    await page.locator('#theme-toggle').click();await page.getByRole('button',{name:'Play original',exact:true}).click();await waitMedia();await page.getByRole('button',{name:'Pause recording',exact:true}).click();await page.getByRole('button',{name:'All cameras',exact:true}).click();await waitMedia(6);await assertCameraGrid(3,2);await screenshot('recordings-desktop-light');
    await page.setViewportSize({width:390,height:844});await assertCameraGrid(2,3);await screenshot('recordings-mobile-light');await noOverflow('Mobile recordings');
    await nav('Device');await page.getByText(/Status refreshed/).waitFor();await page.getByRole('tab',{name:'Tools',exact:true}).click();await noOverflow('Mobile Device');await screenshot('device-tools-mobile-light');
    await nav('Files');await page.getByText(/Available drives:/).waitFor();await page.getByRole('option',{name:'Evening drive.wav',exact:true}).waitFor();await noOverflow('Mobile Files');await screenshot('files-mobile-light');
    await nav('Trash');await page.getByText(/Trash is empty/).waitFor();await noOverflow('Mobile Trash');
    fixture.state.events=fixture.state.events.filter(event=>!event.event.startsWith('RecentClips/'));
    for(const event of fixture.state.events.filter(event=>event.event.includes(NEWEST_DAY)))await context.request.post(new URL('/api/v1/trash/move',fixture.url).href,{headers:{'X-TeslaUSB-Request':'1'},data:{event:event.event}});
    const fallbackPage=await context.newPage();fallbackPage.on('pageerror',error=>errors.push(error.message));await fallbackPage.goto(fixture.url);await fallbackPage.locator('#library-state').filter({hasText:'1 recordings available · 2026-09-06'}).waitFor();assert.match(await fallbackPage.locator('#recording-day option:checked').textContent(),/2026-09-06/);assert.equal(await fallbackPage.locator('#clip-grid .clip-card').count(),1);await fallbackPage.close();
    fixture.state.failTrash=true;
    const closedPage=await context.newPage();closedPage.on('pageerror',error=>errors.push(error.message));const beforeRequests=fixture.state.requests.length;await closedPage.goto(fixture.url);await closedPage.locator('#library-state').filter({hasText:'Trash status is unavailable'}).waitFor();assert.equal(await closedPage.locator('#clip-grid .clip-card').count(),0);assert.equal(await closedPage.locator('#player video[src]').count(),0);assert.equal(fixture.state.requests.slice(beforeRequests).some(request=>request.path.startsWith('/TeslaCam/')),false,'First-load Trash failure cannot request hidden original media');await closedPage.close();fixture.state.failTrash=false;
    console.log('PASS: media visibility cleanup, cached-page restore, hidden newest day, and fail-closed first load');
    assert.deepEqual(errors,[],'No uncaught browser errors');
    console.log(`Modern app integration passed. Fictional fixture screenshots: ${output}`);
  }catch(error){await screenshot('failure').catch(()=>{});console.error('Last fixture requests:',fixture.state.requests.slice(-12));console.error('Browser errors:',errors);throw error;}
  finally {await browser.close();await fixture.close();}
}
run().catch(error=>{console.error(error);process.exitCode=1;});
