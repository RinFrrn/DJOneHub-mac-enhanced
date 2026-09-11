const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

function fixture() {
  const handlers = {}, notifications = [], opened = [];
  const self = {
    location: {href: 'https://example.com/module-push/sw.js', origin: 'https://example.com'},
    addEventListener: (name, handler) => { handlers[name] = handler; },
    registration: {showNotification: async (title, options) => notifications.push({title, options})},
    clients: {matchAll: async () => [], openWindow: async url => opened.push(url)}
  };
  vm.runInNewContext(fs.readFileSync(__dirname + '/sw.js', 'utf8'), {self, URL, Date, Number});
  const push = async data => {
    let pending;
    handlers.push({data: {json: () => data}, waitUntil: promise => { pending = promise; }});
    await pending;
  };
  return {handlers, notifications, opened, push};
}

test('fresh notification and expired call have distinct visible text', async () => {
  const f = fixture();
  await f.push({kind:'call', title:'DJOneHub 来电', body:'现在呼入', expires:Date.now()+60000, tag:'call-1'});
  await f.push({kind:'call', title:'DJOneHub 来电', body:'现在呼入', expires:Date.now()-60000, tag:'call-2'});
  assert.equal(f.notifications[0].title,'DJOneHub 来电');
  assert.equal(f.notifications[1].title,'DJOneHub 来电记录');
  assert.match(f.notifications[1].options.body,/此前/);
});
test('missing payload still produces a visible notification', async () => {
  const f = fixture();
  await f.push(null);
  assert.equal(f.notifications.length,1);
  assert.equal(f.notifications[0].title,'DJOneHub 提醒');
});
test('notification click cannot navigate to an injected destination', async () => {
  const f = fixture();
  let pending;
  f.handlers.notificationclick({notification:{close(){},data:{url:'https://attacker.invalid'}}, waitUntil:p => {pending=p;}});
  await pending;
  assert.equal(f.opened[0],'https://example.com/module-push/');
});
