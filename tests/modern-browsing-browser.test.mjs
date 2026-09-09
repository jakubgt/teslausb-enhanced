/* Dense recording-library integration. Fixture changes stay in memory and the
 * real frontend handles every filter, page, selection, and deletion action. */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';
import {createPreviewServer, NEWEST_DAY, FIRST_EVENT} from '../tools/modern-preview-server.mjs';
import {CAMERAS} from '../teslausb-www/html/modern/model.mjs';
const require=createRequire(import.meta.url);
const {chromium}=require('playwright');
const CAMERA_NAMES=Object.keys(CAMERAS);

function fixtureEvent(event,stamps) {
  return {event,stamps,files:stamps.flatMap(stamp=>CAMERA_NAMES.map(camera=>({name:`${stamp}-${camera}.mp4`,camera})))};
}

async function run() {
  const fixture=await createPreviewServer();
  const browser=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL||'chrome',headless:true});
  const output=process.env.MODERN_SCREENSHOT_DIR||path.join(os.tmpdir(),'teslausb-modern-browser');fs.mkdirSync(output,{recursive:true});
  fixture.state.previewState='ready';
  fixture.state.events=fixture.state.events.filter(event=>!event.event.startsWith('RecentClips/'));
  fixture.state.events.push(fixtureEvent(`RecentClips/${NEWEST_DAY}`,[
    ...Array.from({length:60},(_,minute)=>`${NEWEST_DAY}_20-${String(minute).padStart(2,'0')}-00`),
    `${NEWEST_DAY}_19-05-00`,`${NEWEST_DAY}_19-41-00`
  ]));
  fixture.state.events.push(fixtureEvent('RecentClips/2026-09-06',['2026-09-06_14-10-00','2026-09-06_14-40-00']));
  for(let minute=0;minute<45;minute++) {
    const stamp=`${NEWEST_DAY}_17-${String(minute).padStart(2,'0')}-00`;
    fixture.state.events.push(fixtureEvent(`SavedClips/${stamp}`,[stamp]));
  }
  const page=await browser.newPage({viewport:{width:1440,height:1120},locale:'en-US',reducedMotion:'reduce'});
  const errors=[];page.on('pageerror',error=>errors.push(error.message));
  const category=name=>page.getByRole('group',{name:'Recording category'}).getByRole('button',{name,exact:true}).click();
  const videosRequests=()=>fixture.state.requests.filter(request=>request.path==='/api/v1/videos').length;
  const cards=()=>page.locator('#clip-grid .clip-card');
  const assertPage=async(current,total,count)=>{
    await page.locator('#page-status').filter({hasText:new RegExp(`Page ${current} of ${total}(?:\\D|$)`)}).waitFor({state:'attached'});
    assert.equal(await cards().count(),count,`Page ${current} should render ${count} recordings`);
    assert.ok(await cards().count()<=20,'Never render more than20 recording cards');
    assert.equal(await page.locator('#page-prev').isDisabled(),current===1);
    assert.equal(await page.locator('#page-next').isDisabled(),current===total);
  };
  const waitMedia=()=>page.waitForFunction(()=>{const video=document.querySelector('#player video');return video&&video.readyState>=2&&!video.error;});
  const noOverflow=async label=>assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),true,`${label} fits the viewport`);
  try {
    await page.goto(fixture.url);
    await page.locator('#library-state').filter({hasText:'recordings available'}).waitFor();
    await waitMedia();
    assert.equal(CAMERA_NAMES.length,6);
    assert.equal(await page.locator('#player [data-camera]').count(),6,'Dense Recent fixtures include all six cameras');
    assert.equal(await page.locator('#recording-day').inputValue(),'latest');
    assert.match(await page.locator('#recording-day option:checked').textContent(),new RegExp(NEWEST_DAY));
    assert.equal(await cards().count(),20,'Initial library uses a20-event page');
    assert.equal(await page.locator('#hour-filter').isVisible(),false,'Hour selector is only shown for Recent');
    const activeVideo=await page.locator('#player video').elementHandle();
    const initialSource=await activeVideo.getAttribute('src');
    await page.locator('#player [data-position]').evaluate(input=>{input.value='10';input.dispatchEvent(new Event('input',{bubbles:true}));});
    await page.waitForFunction(()=>Math.abs(document.querySelector('#player video').currentTime-10)<.5);
    const browsingRequests=videosRequests();

    await category('Recent');
    assert.equal(await page.locator('#hour-filter').isVisible(),true);
    assert.equal(await page.locator('#recording-hour').inputValue(),'20','Recent defaults to the latest hour containing recordings');
    assert.deepEqual((await page.locator('#recording-hour option').evaluateAll(options=>options.map(option=>option.value))).sort(),['19','20','all']);
    await assertPage(1,3,20);
    assert.ok((await cards().allTextContents()).every(text=>text.includes('20:')),'Latest-hour page contains only20:00 entries');
    await page.locator('#page-next').click();await assertPage(2,3,20);
    await page.locator('#page-next').click();await assertPage(3,3,20);
    await page.locator('#page-prev').click();await assertPage(2,3,20);
    await page.locator('#recording-hour').selectOption('19');await assertPage(1,1,2);
    assert.ok((await cards().allTextContents()).every(text=>text.includes('19:')));
    await page.locator('#recording-hour').selectOption('all');await assertPage(1,4,20);
    await page.locator('#page-next').click();await assertPage(2,4,20);
    await page.locator('#page-next').click();await assertPage(3,4,20);
    await page.locator('#page-next').click();await assertPage(4,4,2);

    await category('Saved');await assertPage(1,3,20);
    assert.equal(await page.locator('#hour-filter').isVisible(),false);
    await page.locator('#select-all').check();
    assert.equal(await page.locator('#clip-grid [data-select]:checked').count(),20);
    assert.match(await page.locator('#selection-count').textContent(),/^20 selected(?: on this page)?$/,'Select all applies to the visible page only');
    await page.locator('#page-next').click();await assertPage(2,3,20);
    assert.equal(await page.locator('#clip-grid [data-select]:checked').count(),0);
    assert.equal(await page.locator('#select-all').isChecked(),false);
    assert.equal(await page.locator('#bulk-trash').isVisible(),false,'Changing pages clears bulk selection');
    await page.locator('#recording-search').fill(`${NEWEST_DAY}_17-0`);await assertPage(1,1,10);
    await page.locator('#recording-search').fill('');await assertPage(1,3,20);
    await category('Sentry');await assertPage(1,1,2);
    assert.match(await page.locator(`#clip-grid .clip-card:has([data-open="${FIRST_EVENT}"])`).textContent(),/2 segments/,'Sentry event segmentation remains intact');
    assert.equal(videosRequests(),browsingRequests,'Hour/category/search/page changes use the existing day list');
    assert.equal(await activeVideo.evaluate(video=>video.isConnected),true,'Browsing retains the exact active video element');
    assert.equal(await activeVideo.getAttribute('src'),initialSource);
    assert.ok(Math.abs(await activeVideo.evaluate(video=>video.currentTime)-10)<.5,'Browsing keeps the current playback position');
    console.log('PASS: hourly Recent filters,20-card pages, event preservation, page-only selection, and unchanged media');

    await category('Recent');await page.locator('#recording-hour').selectOption('20');await page.locator('#page-next').click();await assertPage(2,3,20);
    const refreshRequestCount=videosRequests();
    await page.locator('#refresh-recordings').click();await page.waitForFunction(()=>!document.querySelector('#refresh-recordings').disabled);
    assert.ok(videosRequests()>refreshRequestCount);await assertPage(2,3,20);
    assert.equal(await page.locator('#recording-hour').inputValue(),'20','Refreshing the same day preserves the hour');
    await waitMedia();
    assert.ok(Math.abs(await page.locator('#player video').evaluate(video=>video.currentTime)-10)<.5,'Refresh preserves playback position');
    await page.locator('#recording-day').selectOption('2026-09-06');await page.locator('#library-state').filter({hasText:'2026-09-06'}).waitFor();await assertPage(1,1,2);
    assert.equal(await page.locator('#recording-hour').inputValue(),'14');
    assert.deepEqual((await page.locator('#recording-hour option').evaluateAll(options=>options.map(option=>option.value))).sort(),['14','all']);
    await page.locator('#recording-day').selectOption('latest');await page.locator('#library-state').filter({hasText:NEWEST_DAY}).waitFor();await assertPage(1,3,20);
    assert.equal(await page.locator('#recording-hour').inputValue(),'20');

    await category('Saved');await assertPage(1,3,20);await page.locator('#page-next').click();await page.locator('#page-next').click();await assertPage(3,3,6);
    await page.locator('#select-all').check();assert.match(await page.locator('#selection-count').textContent(),/^6 selected(?: on this page)?$/);await page.locator('#bulk-trash').click();await page.locator('#move-confirm').click();await page.getByText(/6 recordings moved to Trash/).waitFor();
    await assertPage(2,2,20);assert.equal(fixture.state.trash.size,6,'Only the six selected last-page events move to Trash');
    assert.equal(await page.locator('#clip-grid [data-select]:checked').count(),0);
    console.log('PASS: refresh retains hour/page, day changes reset, and deleting the last page clamps pagination');

    await category('Recent');await page.locator('#recording-hour').selectOption('20');await assertPage(1,3,20);
    await page.screenshot({path:path.join(output,'browsing-recent-desktop.png'),fullPage:true});await noOverflow('Desktop hourly controls');
    await page.setViewportSize({width:390,height:844});await noOverflow('Mobile hourly controls');
    await page.locator('#page-next').click();await assertPage(2,3,20);await page.screenshot({path:path.join(output,'browsing-recent-mobile.png'),fullPage:true});
    await category('Saved');await assertPage(1,2,20);await noOverflow('Mobile Saved pagination');
    assert.deepEqual(errors,[],'Dense browsing has no uncaught browser errors');
    console.log(`Modern dense-library browsing passed. Screenshots: ${output}`);
  }catch(error){await page.screenshot({path:path.join(output,'browsing-failure.png'),fullPage:true}).catch(()=>{});console.error('Browser errors:',errors);throw error;}
  finally{await browser.close();await fixture.close();}
}
run().catch(error=>{console.error(error);process.exitCode=1;});
