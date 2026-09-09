// A real browser HTTP-cache migration test. Intercepting requests through
// Playwright disables that cache, so a localhost proxy serves the old assets.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import {createRequire} from 'node:module';
import {createPreviewServer} from '../tools/modern-preview-server.mjs';
const {chromium}=createRequire(import.meta.url)('playwright');
const index=fs.readFileSync(new URL('../teslausb-www/html/modern/index.html',import.meta.url),'utf8');
const legacyHTML='<!doctype html><html><head><link rel="stylesheet" href="/modern/style.css"></head><body><h1 id="legacy-cache-banner">Loading cached interface</h1><script type="module" src="/modern/app.mjs"></script></body></html>';
const legacyAssets=new Map([
  ['/modern/app.mjs',`import {legacyPlayer} from './player.mjs';import {legacyQueue} from './thumbnail-loader.mjs';document.querySelector('#legacy-cache-banner').textContent=legacyPlayer+' / '+legacyQueue;`],
  ['/modern/player.mjs',`import {legacyQueue} from './thumbnail-loader.mjs';export const legacyPlayer='Cached legacy player';export class ClipPlayer {}`],
  ['/modern/thumbnail-loader.mjs',`export const legacyQueue='Cached legacy queue';`],
  ['/modern/style.css',':root{--legacy-cache-style:cached}body{background:rgb(32,40,50);color:white}'],
]);
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(check,message,timeout=15000){const end=Date.now()+timeout;while(Date.now()<end){if(await check())return;await sleep(20);}assert.fail(message);}

const fixture=await createPreviewServer(),requests=[];
let published=false;
const server=http.createServer((request,response)=>{
  const url=new URL(request.url,'http://localhost');requests.push({path:url.pathname,query:url.search,published});
  if(url.pathname==='/modern/'||url.pathname==='/cache-probe'){
    response.writeHead(200,{'Content-Type':'text/html','Cache-Control':'no-store'});
    response.end(url.pathname==='/cache-probe'||!published?legacyHTML:index);return;
  }
  if(!published&&!url.search&&legacyAssets.has(url.pathname)){
    response.writeHead(200,{'Content-Type':url.pathname.endsWith('.css')?'text/css':'text/javascript','Cache-Control':'public, max-age=3600, immutable'});
    response.end(legacyAssets.get(url.pathname));return;
  }
  const target=new URL(request.url,fixture.url);
  const upstream=http.request(target,{method:request.method,headers:{...request.headers,host:target.host}},result=>{
    response.writeHead(result.statusCode,result.headers);result.pipe(response);
  });
  upstream.on('error',()=>{if(!response.destroyed&&!response.headersSent){response.writeHead(502);response.end('Fixture proxy failure');}});
  response.on('close',()=>upstream.destroy());request.pipe(upstream);
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const origin=`http://127.0.0.1:${server.address().port}`;
const browser=await chromium.launch({channel:process.env.PLAYWRIGHT_CHANNEL||'chrome',headless:true});
const page=await browser.newPage({viewport:{width:1440,height:900},reducedMotion:'reduce'}),errors=[];
page.on('pageerror',error=>errors.push(error.message));page.setDefaultTimeout(15000);
const legacyCount=()=>requests.filter(item=>!item.query&&legacyAssets.has(item.path)).length;
async function cachedInterface(){
  await page.locator('#legacy-cache-banner').filter({hasText:'Cached legacy player / Cached legacy queue'}).waitFor();
  assert.equal(await page.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue('--legacy-cache-style')),'cached');
}
try{
  await page.goto(origin+'/modern/');await cachedInterface();
  assert.equal(legacyCount(),4,'Warm each unversioned legacy asset, with one shared queue module');
  await page.goto(origin+'/cache-probe');await cachedInterface();
  assert.equal(legacyCount(),4,'A second navigation really reuses the HTTP cache');
  await page.goto(origin+'/modern/');await cachedInterface();
  published=true;
  await page.reload();
  await page.locator('#library-state').filter({hasText:'recordings available'}).waitFor();
  assert.equal(await page.locator('#player [data-quality]').textContent(),'Original quality');
  assert.equal(await page.locator('#player select[data-quality]').count(),0,'The old Low selector is gone after an ordinary reload');
  assert.equal(await page.locator('#legacy-cache-banner').count(),0,'Cached app code cannot overwrite the updated page');
  assert.equal(await page.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue('--legacy-cache-style')),'','The updated stylesheet replaces the legacy style');
  const first=page.locator('#clip-grid .clip-image').first();await first.scrollIntoViewIfNeeded();
  await until(()=>first.locator('img').evaluateAll(images=>images.some(image=>image.complete&&image.naturalWidth>0)),'Updated app loads a front-camera recording card');
  assert.equal(await first.locator('.clip-thumbnail-note').textContent(),'Front camera');
  for(const asset of legacyAssets.keys())assert.ok(requests.some(item=>item.path===asset&&item.query==='?v=2.0.0'&&item.published),`The new ${asset} has its own cache identity`);
  assert.equal(requests.filter(item=>item.path==='/modern/thumbnail-loader.mjs'&&item.published).length,1,'App and player import one identical versioned queue');
  assert.equal(legacyCount(),4,'Updated imports never request stale unversioned dependencies');
  assert.deepEqual(errors,[]);

  // The old cache still exists. Success came from migration, not disabling it.
  await page.goto(origin+'/cache-probe');await cachedInterface();
  assert.equal(legacyCount(),4,'Legacy URLs remain cached even after the current interface loaded correctly');
  console.log('PASS: warm legacy HTTP cache, normal reload into current UI, front-card rendering, current stylesheet and single versioned queue');
}finally{
  await browser.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));await fixture.close();
}
