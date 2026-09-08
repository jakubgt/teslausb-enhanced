// Production app against localhost fixtures only; no device actions or real recordings.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';
import {createPreviewServer,NEWEST_DAY,FIRST_EVENT} from '../tools/modern-preview-server.mjs';
import {CAMERAS} from '../teslausb-www/html/modern/model.mjs';
const {chromium}=createRequire(import.meta.url)('playwright');

async function run(){
  const fixture=await createPreviewServer();fixture.state.previewState='ready';
  const stamps=[...Array.from({length:60},(_,n)=>`${NEWEST_DAY}_20-${String(n).padStart(2,'0')}-00`),`${NEWEST_DAY}_19-05-00`,`${NEWEST_DAY}_19-41-00`];
  fixture.state.events.push({event:`RecentClips/${NEWEST_DAY}`,stamps,files:stamps.flatMap(stamp=>Object.keys(CAMERAS).map(camera=>({name:`${stamp}-${camera}.mp4`,camera})))});
  const browser=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL||'chrome',headless:true});
  const context=await browser.newContext({viewport:{width:1440,height:1120},locale:'en-US',reducedMotion:'reduce'}),page=await context.newPage(),errors=[];
  const output=process.env.MODERN_SCREENSHOT_DIR||path.join(os.tmpdir(),'teslausb-modern-browser');fs.mkdirSync(output,{recursive:true});
  page.on('pageerror',error=>errors.push(error.message));
  const nav=name=>page.getByRole('navigation',{name:'Main navigation'}).getByRole('button',{name:new RegExp('^'+name+'(?: \\d+)?$')}).click();
  const capture=()=>page.locator('#player [data-capture]');
  const waitClip=stamp=>capture().filter({hasText:stamp}).waitFor();
  const waitMedia=()=>page.waitForFunction(()=>{const video=document.querySelector('#player video');return video?.readyState>=2&&!video.error;});
  const next=()=>page.getByRole('button',{name:'Next clip',exact:true});
  const previous=()=>page.getByRole('button',{name:'Previous clip',exact:true});
  const openClip=async stamp=>{await page.locator(`#clip-grid [data-open*="${stamp}"]`).first().click();await waitMedia();};
  const finish=async()=>{await page.locator('#player video').first().evaluate(video=>{video.currentTime=video.duration-.12;});};
  try{
    await page.goto(fixture.url);await page.locator('#library-state').filter({hasText:'recordings available'}).waitFor();await waitMedia();
    await page.getByRole('group',{name:'Recording category'}).getByRole('button',{name:'Recent',exact:true}).click();
    assert.equal(await page.locator('[data-autoplay-next]').isChecked(),false);
    assert.equal(await next().isDisabled(),true,'Latest minute has no later neighbor');
    const requests=fixture.state.requests.filter(item=>item.path==='/api/v1/videos').length;
    await page.locator('#page-jump').selectOption('2');await openClip(`${NEWEST_DAY}_20-39-00`);
    await page.locator('#player [data-camera="right_pillar"]').click();await page.locator('#player [data-quality]').selectOption('high');await page.locator('#player [data-rate]').selectOption('2');await waitMedia();
    await next().click();await waitClip('20:40:00');await waitMedia();
    assert.equal(await page.locator('#page-jump').inputValue(),'1','Next clip crosses the page boundary');
    assert.equal(await page.locator('#player [data-camera="right_pillar"]').getAttribute('aria-pressed'),'true');
    assert.equal(await page.locator('#player [data-quality]').inputValue(),'high');assert.equal(await page.locator('#player [data-rate]').inputValue(),'2');
    assert.ok(Number(await page.locator('#player [data-position]').inputValue())<1);
    await previous().click();await waitClip('20:39:00');await waitMedia();assert.equal(await page.locator('#page-jump').inputValue(),'2');
    await page.getByRole('button',{name:'Play recording',exact:true}).click();await finish();
    await page.getByRole('button',{name:'Play recording',exact:true}).waitFor();assert.match(await capture().textContent(),/20:39:00/,'Autoplay is off by default');
    await page.locator('[data-autoplay-next]').check();await previous().click();await waitClip('20:38:00');await waitMedia();
    await page.getByRole('button',{name:'Play recording',exact:true}).click();await finish();await waitClip('20:39:00');await waitMedia();await page.getByRole('button',{name:'Pause recording',exact:true}).click();
    await page.locator('#recording-hour').selectOption('19');assert.equal(await next().isDisabled(),true);assert.equal(await previous().isDisabled(),true,'Changing filters does not navigate away from the playing clip');
    await openClip(`${NEWEST_DAY}_19-05-00`);assert.equal(await previous().isDisabled(),true);await next().click();await waitClip('19:41:00');await waitMedia();assert.equal(await next().isDisabled(),true,'Sparse hour stops at its own boundary');
    assert.equal(fixture.state.requests.filter(item=>item.path==='/api/v1/videos').length,requests,'Clip navigation never reloads the day');
    await page.screenshot({path:path.join(output,'clip-navigation-desktop.png'),fullPage:true});
    console.log('PASS: chronological neighbors, page crossing, preferences, default-off autoplay, sparse hours and filter boundaries');

    await nav('Device');await page.getByText(/Status refreshed/).waitFor();
    await page.route('**/api/v1/**',route=>route.abort('connectionreset'));
    await page.getByRole('button',{name:'Refresh status',exact:true}).click();await page.locator('#connection-banner').filter({hasText:/Connection lost/}).waitFor();
    assert.match(await page.locator('#connection-banner').textContent(),/Last (?:successful )?contact/i);
    assert.match(await page.locator('#connection-status').textContent(),/^USB:/);
    await page.setViewportSize({width:390,height:844});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
    await page.screenshot({path:path.join(output,'connection-lost-mobile.png'),fullPage:true});
    const mutations=fixture.state.mutations.length;await page.unroute('**/api/v1/**');
    await page.locator('#connection-banner button').click();await page.locator('#connection-banner').filter({hasText:/Connected/}).waitFor();assert.equal(fixture.state.mutations.length,mutations,'Connection Retry never repeats a mutation');
    console.log('PASS: transport failure banner, preserved contact time, USB separation and read-only Retry');

    const stalled=await context.newPage();await stalled.clock.install();
    await stalled.goto(fixture.url);await stalled.locator('#library-state').filter({hasText:'recordings available'}).waitFor();
    await stalled.getByRole('navigation',{name:'Main navigation'}).getByRole('button',{name:'Device',exact:true}).click();await stalled.getByText(/Status refreshed/).waitFor();
    await stalled.route('**/api/v1/**',()=>{});await stalled.getByRole('button',{name:'Refresh status',exact:true}).click();
    await stalled.clock.fastForward(30001);await stalled.locator('#connection-banner').filter({hasText:'Connection lost'}).waitFor();
    assert.match(await stalled.locator('[data-device="status"]').textContent(),/timed out/i,'Device timeout must be a connection failure, not an intentional abort');
    await stalled.close();console.log('PASS: a non-responsive Device request times out into Connection lost');

    await context.request.post(new URL('/api/v1/trash/move',fixture.url).href,{headers:{'X-TeslaUSB-Request':'1'},data:{event:FIRST_EVENT}});
    await nav('Trash');await page.locator('.trash-item').waitFor();
    await page.getByRole('button',{name:'Restore',exact:true}).click();await page.getByText(/restored to the library/).first().waitFor();
    assert.equal(await page.locator('.trash-item').count(),0);assert.match(await page.locator('.trash-storage').textContent(),/Restored copies/i);
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);await page.screenshot({path:path.join(output,'restored-storage-mobile.png'),fullPage:true});
    assert.deepEqual(errors,[]);console.log('PASS: empty Trash retains visible restored-copy storage; all three additions fit mobile');
  }catch(error){await page.screenshot({path:path.join(output,'polish-failure.png'),fullPage:true}).catch(()=>{});console.error(errors);throw error;}
  finally{await browser.close();await fixture.close();}
}
run().catch(error=>{console.error(error);process.exitCode=1;});
