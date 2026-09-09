import test from 'node:test';
import assert from 'node:assert/strict';
import {buildEvents,parseVideoPath,eventMarker,validLocation,resolveLibrary,validTrash,downloadQuery,recordingPage,recordingNeighbors} from '../teslausb-www/html/modern/model.mjs';

const emptyTrash=()=>({items:[],restored:[],tombstones:[],hidden_media:[]});
test('recording search accepts displayed times and original filename timestamps',()=>{
  const events=[{id:'match',category:'Recent',group:'RecentClips',start:'2026-09-08_09-15-37'},
    {id:'other',category:'Recent',group:'RecentClips',start:'2026-09-08_09-16-37'}];
  for(const query of ['09:15','09:15:37','09-15','2026-09-08_09-15']){
    assert.deepEqual(recordingPage(events,{category:'RecentClips',hour:'09',query}).items.map(event=>event.id),['match']);
  }
  assert.equal(recordingPage(events,{category:'RecentClips',hour:'09',query:'10:15'}).total,0);
});
test('viewer neighbors follow time across grid pages without crossing filters or wrapping',()=>{
  const events=Array.from({length:60},(_,n)=>({id:String(n),start:`2026-09-08_12-${String(n).padStart(2,'0')}-00`,group:'RecentClips'})).reverse();
  events.push({id:'outside',start:'2026-09-08_11-59-00',group:'RecentClips'});
  const view=recordingPage(events,{category:'RecentClips',hour:'12',page:2});
  const neighbors=recordingNeighbors(view.events,'39');assert.equal(neighbors.previous.id,'38');assert.equal(neighbors.next.id,'40');assert.equal(neighbors.index,40);assert.equal(neighbors.total,60);
  assert.equal(recordingNeighbors(view.events,'0').previous,null);assert.equal(recordingNeighbors(view.events,'59').next,null);
  assert.deepEqual(recordingNeighbors(view.events,'outside'),{previous:null,next:null,index:0,total:60});
  assert.equal(view.events[0].id,'59','Navigation does not mutate the newest-first grid');
});
const path=(day='2026-09-08',camera='front',group='SavedClips',minute='00')=>`${group}/${day}${group==='RecentClips'?'':'_12-00-00'}/${day}_12-${minute}-00-${camera}.mp4`;
test('groups event segments and available cameras while keeping Recent minutes separate',()=>{
  const events=buildEvents([path(),path(undefined,'back'),path(undefined,'front',undefined,'01'),path(undefined,'front','RecentClips'),path(undefined,'front','RecentClips','01')]);
  assert.equal(events.length,3);
  const saved=events.find(e=>e.group==='SavedClips');assert.deepEqual(saved.cameras,['front','back']);assert.equal(saved.duration,120);assert.equal(saved.segments.length,2);
  assert.equal(downloadQuery(saved,'all').get('segment'),null);
  const recent=events.find(e=>e.group==='RecentClips');assert.equal(downloadQuery(recent,'front').get('segment'),recent.start);
});
test('recognizes all six exterior camera files and preserves missing segment availability',()=>{
  const cameras=['front','back','left_repeater','right_repeater','left_pillar','right_pillar'];
  const files=cameras.map(camera=>path(undefined,camera));
  files.push(path(undefined,'front',undefined,'01'),path(undefined,'right_pillar',undefined,'01'));
  const [event]=buildEvents(files);
  assert.deepEqual(event.cameras,cameras);assert.equal(event.segments.length,2);
  assert.match(event.segments[0].files.left_pillar.url,/-left_pillar\.mp4$/);
  assert.equal(event.segments[1].files.left_pillar,undefined);
  assert.match(event.segments[1].files.right_pillar.url,/-right_pillar\.mp4$/);
  assert.deepEqual(buildEvents(files.filter(file=>!file.includes('_pillar')))[0].cameras,cameras.slice(0,4));
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

test('Recent hourly browsing counts synchronized minutes once and paginates a full hour into three pages',()=>{
  const paths=[];for(let minute=0;minute<60;minute++)for(const camera of ['front','back'])paths.push(path(undefined,camera,'RecentClips',String(minute).padStart(2,'0')));
  paths.push(path(undefined,'front','RecentClips').replace('_12-','_11-'));
  const events=buildEvents(paths),view=recordingPage(events,{category:'RecentClips'});
  assert.deepEqual(view.hours,[{value:'12',count:60},{value:'11',count:1}]);assert.equal(view.hour,'12');assert.equal(view.total,60);assert.equal(view.pages,3);assert.equal(view.items.length,20);
  const last=recordingPage(events,{category:'RecentClips',page:3});assert.equal(last.start,41);assert.equal(last.end,60);assert.equal(last.items.length,20);
  const ids=[1,2,3].flatMap(page=>recordingPage(events,{category:'RecentClips',page}).items.map(e=>e.id));assert.equal(new Set(ids).size,60);
  const sparse=recordingPage(events,{category:'RecentClips',hour:'11',page:3});assert.equal(sparse.pages,1);assert.equal(sparse.page,1);assert.equal(sparse.items.length,1);
  assert.equal(recordingPage(events,{category:'RecentClips',hour:'all'}).pages,4);
});
test('hour filtering is confined to Recent, search stays within the hour, and paging handles disappearing results',()=>{
  const events=buildEvents([path(),path(undefined,'front',undefined,'01'),path(undefined,'front','RecentClips'),path(undefined,'front','RecentClips').replace('_12-','_11-')]);
  const saved=recordingPage(events,{category:'SavedClips',hour:'11'});assert.equal(saved.items.length,1);assert.equal(saved.items[0].segments.length,2);
  assert.equal(recordingPage(events,{category:'RecentClips',hour:'12',query:'11-00'}).total,0);
  assert.equal(recordingPage(events,{category:'RecentClips',hour:'all',query:'11-00'}).total,1);
  assert.equal(recordingPage(events,{category:'RecentClips',hour:'23'}).hour,'12');
  assert.equal(recordingPage(events,{page:999}).page,1);assert.equal(recordingPage(events,{page:NaN}).page,1);
  const empty=recordingPage([],{category:'RecentClips',page:3});assert.deepEqual(empty.items,[]);assert.equal(empty.start,0);assert.equal(empty.end,0);assert.equal(empty.hour,null);assert.equal(empty.page,1);
});
