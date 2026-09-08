import test from 'node:test';
import assert from 'node:assert/strict';
import {buildEvents,parseVideoPath,eventMarker,validLocation,resolveLibrary,validTrash,downloadQuery} from '../teslausb-www/html/modern/model.mjs';

const emptyTrash=()=>({items:[],restored:[],tombstones:[],hidden_media:[]});
const path=(day='2026-09-08',camera='front',group='SavedClips',minute='00')=>`${group}/${day}${group==='RecentClips'?'':'_12-00-00'}/${day}_12-${minute}-00-${camera}.mp4`;
test('groups event segments and available cameras while keeping Recent minutes separate',()=>{
  const events=buildEvents([path(),path(undefined,'back'),path(undefined,'front',undefined,'01'),path(undefined,'front','RecentClips'),path(undefined,'front','RecentClips','01')]);
  assert.equal(events.length,3);
  const saved=events.find(e=>e.group==='SavedClips');assert.deepEqual(saved.cameras,['front','back']);assert.equal(saved.duration,120);assert.equal(saved.segments.length,2);
  assert.equal(downloadQuery(saved,'all').get('segment'),null);
  const recent=events.find(e=>e.group==='RecentClips');assert.equal(downloadQuery(recent,'front').get('segment'),recent.start);
});
test('rejects traversal, unknown cameras, and invalid calendar paths',()=>{
  for(const value of ['../'+path(),path().replace('front','cabin'),path().replaceAll('2026-09-08','2026-02-31'),path().replace('_12-00-00/','/'),null])assert.equal(parseVideoPath(value),null);
});
test('a tombstone suppresses duplicate Recent aliases and restored copies use owned media',()=>{
  const trash=emptyTrash();trash.tombstones=['SavedClips/2026-09-08_12-00-00'];trash.hidden_media=['2026-09-08_12-00-00-front.mp4'];
  const paths=[path(),path(undefined,'front','RecentClips')];assert.equal(buildEvents(paths,trash).length,0);
  trash.restored=[{id:'abc',event:trash.tombstones[0],files:[{name:trash.hidden_media[0],media_url:'/api/v1/trash/media?id=abc&file=front.mp4'},{name:'event.json',media_url:'https://untrusted.invalid/event.json'}]}];
  const events=buildEvents(paths,trash);assert.equal(events.length,1);assert.equal(events[0].owned,'abc');assert.equal(events[0].metadata,null);assert.match(events[0].segments[0].files.front.url,/^\/api\/v1\/trash\/media\?/);
});
test('event jump only targets a segment with matching camera-clock metadata',()=>{
  const event=buildEvents([path(),path(undefined,'front',undefined,'02')])[0];
  assert.equal(eventMarker(event,{timestamp:'2026-09-08T12:02:15-05:00'}),75);
  assert.equal(eventMarker(event,{timestamp:'2026-09-08T12:01:15Z'}),null);
  assert.equal(eventMarker(event,{timestamp:'2026-02-31T12:00:15Z'}),null);
  assert.deepEqual(validLocation({est_lat:'0',est_lon:0}),{lat:0,lon:0});assert.equal(validLocation({est_lat:999,est_lon:0}),null);
});
test('latest skips fully hidden days and preserves the complete date menu',async()=>{
  const trash=emptyTrash();trash.hidden_media=[path().split('/').at(-1)];trash.tombstones=['SavedClips/2026-09-08_12-00-00'];const calls=[];
  const initial={videos:[path()],selected_day:'2026-09-08',available_days:['2026-09-08','2026-09-07','2026-09-06']};
  const result=await resolveLibrary(initial,trash,'latest',async day=>{calls.push(day);return {videos:day==='2026-09-07'?[]:[path(day)],selected_day:day};});
  assert.deepEqual(calls,['2026-09-07','2026-09-06']);assert.equal(result.selectedDay,'2026-09-06');assert.equal(result.events.length,1);assert.deepEqual(result.data.available_days,initial.available_days);
});
test('restored newer day wins and older restored day does not mask an intermediate indexed day',async()=>{
  const trash=emptyTrash();const owned=day=>({id:day,event:`SavedClips/${day}_12-00-00`,files:[{name:`${day}_12-00-00-front.mp4`,media_url:'/api/v1/trash/media?id=fixture'}]});
  trash.restored=[owned('2026-09-09')];const initial={videos:[path()],selected_day:'2026-09-08',available_days:['2026-09-08','2026-09-07']};
  let result=await resolveLibrary(initial,trash,'latest',()=>{throw new Error('Unnecessary fetch');});assert.equal(result.selectedDay,'2026-09-09');
  trash.restored=[owned('2026-09-06')];trash.tombstones=['SavedClips/2026-09-08_12-00-00'];
  result=await resolveLibrary(initial,trash,'latest',async day=>({videos:[path(day)],selected_day:day}));assert.equal(result.selectedDay,'2026-09-07');
});
test('explicit date stays selected even when empty and unknown Trash is rejected',async()=>{
  const result=await resolveLibrary({videos:[],available_days:[]},emptyTrash(),'2026-09-01',()=>{throw new Error('Unnecessary fetch');});assert.equal(result.selectedDay,'2026-09-01');assert.deepEqual(result.events,[]);
  assert.throws(()=>validTrash({items:[]}),/could not be verified/);
  await assert.rejects(resolveLibrary({videos:[path()]},null,'latest',()=>{}),/could not be verified/);
});
