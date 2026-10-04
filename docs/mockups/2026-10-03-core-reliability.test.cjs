const {test, expect} = require('@playwright/test');
const path = require('path');
const fs = require('fs');
const file = `file://${path.resolve(__dirname, '2026-10-03-core-reliability.html')}`;
const evidence = process.env.WILTED_PROTOTYPE_EVIDENCE || path.resolve('.logs/ship-2026-10-02/batch1-plan-20261003/prototype');
fs.mkdirSync(evidence, {recursive:true});
const scenarios = ['PLAY-IDLE','PLAY-DELAY','PLAY-FAIL','PLAY-RETRY','PLAY-RETRY-FAIL','PLAY-MISSING','PLAY-NOTREADY','SPEED-FAIL','DELETE-ARTICLE','DELETE-FEED','DELETE-FAIL','ACCOUNT-UNBOUND','ACCOUNT-SWITCH','QUIT-SAVE','QUIT-FAIL','SYNC-WORKING','SYNC-FAIL','SYNC-THROTTLE','PHONE-FETCH','STATS','STATS-EMPTY','STATS-LOAD','STATS-FAIL','CARPLAY'];
async function tick(page, ms=650){await page.clock.fastForward(ms);}
async function shot(page, id, width, state){
 await page.screenshot({path:path.join(evidence,`${id}-${width}-${state}.png`),fullPage:true});
 const primary=await page.locator('[data-action="primary"], [data-action="resolve-media"]').first().boundingBox();expect(primary.x).toBeGreaterThanOrEqual(0);expect(primary.x+primary.width).toBeLessThanOrEqual(width);expect(primary.y+primary.height).toBeLessThanOrEqual(900);
 const view=page.locator('#view');if(await view.evaluate(el=>el.scrollHeight>el.clientHeight)){await view.evaluate(el=>el.scrollTop=el.scrollHeight);await page.screenshot({path:path.join(evidence,`${id}-${width}-${state}-lower.png`),fullPage:true});await view.evaluate(el=>el.scrollTop=0);}
}
async function systemPause(page){await page.locator('.fixture').evaluate(el=>el.open=true);await page.locator('[data-action="pause"]').click();await page.locator('.fixture').evaluate(el=>el.open=false);}
async function choose(page,selector,value){await page.locator('.fixture').evaluate(el=>el.open=true);await page.locator(selector).selectOption(value);await page.locator('.fixture').evaluate(el=>el.open=false);}
async function setup(page, id, width){
 await page.setViewportSize({width,height:900});await page.clock.install({time:new Date('2026-10-03T14:15:00Z')});await page.clock.pauseAt(new Date('2026-10-03T14:15:00Z'));await page.goto(file);
 await page.locator('.fixture').evaluate(el=>el.open=true);
 await page.locator('#scenario').selectOption(id);
 await page.locator('.fixture').evaluate(el=>el.open=false);
 await expect(page.locator('[data-player]')).toHaveAttribute('data-fixture','elm-001');
}
for(const width of [390,1280]) for(const id of scenarios){
 test(`${id} ${width} pending and settled`,async({page,browser})=>{
  await setup(page,id,width);
  if(id==='PHONE-FETCH')await choose(page,'#surface','phone');
  if(id.startsWith('PLAY')){
   await page.locator('[data-action="primary"]').click();
   await expect(page.locator('[data-play-status]')).toHaveText('Starting playback…');
   await shot(page,id,width,'pending');await tick(page,649);
   await expect(page.locator('[data-player]')).toHaveAttribute('data-phase','starting');await tick(page,1);
   if(id.includes('RETRY')){
    await expect(page.locator('[data-play-status]')).toContainText('Retrying once');
    await shot(page,id,width,'retrying');await tick(page);
    expect(await page.evaluate(()=>prototype.state.attempts)).toBe(2);
   }
   if(['PLAY-FAIL','PLAY-MISSING','PLAY-NOTREADY','PLAY-RETRY-FAIL'].includes(id)){
    await expect(page.locator('[data-player]')).toHaveAttribute('data-phase','paused');
    const typed={'PLAY-FAIL':'backendRefusal','PLAY-MISSING':'missingMedia','PLAY-NOTREADY':'notReady','PLAY-RETRY-FAIL':'routeFault'};
    expect(await page.evaluate(()=>prototype.state.errorType)).toBe(typed[id]);
    await shot(page,id,width,'error');if(id==='PLAY-MISSING'||id==='PLAY-NOTREADY'){await expect(page.locator('[data-action="primary"]')).toHaveCount(0);await page.locator('[data-action="resolve-media"]').click();await shot(page,id,width,'repairing');await tick(page);await expect(page.locator('[data-play-status]')).toContainText('Audio ready');await page.locator('[data-action="primary"]').click();}else await page.locator('[data-action="retry"]').click();await tick(page);
   }
   await expect(page.locator('[data-play-status]')).toHaveText('Playing');
   await page.locator('[data-action="primary"]').click();await expect(page.locator('[data-play-status]')).toHaveText('Pausing…');
   await shot(page,id,width,'pausing');await tick(page);await expect(page.locator('[data-play-status]')).toHaveText('Paused');
  }else if(id==='SPEED-FAIL'){
   await page.locator('[data-speed]').selectOption('1.5');await expect(page.locator('[data-speed-status]')).toHaveText('Saving speed…');
   await shot(page,id,width,'pending');await tick(page);await expect(page.locator('[data-speed]')).toHaveValue('1.5');
   await expect(page.locator('[data-speed-status]')).toContainText('restart uses 1×');await shot(page,id,width,'error');
   await page.locator('[data-action="retry-speed"]').click();await tick(page);await expect(page.locator('[data-speed-status]')).toHaveText('Speed saved');
  }else if(id.startsWith('DELETE')){
   const kind=id==='DELETE-FEED'?'feed':'article';await page.locator(`[data-delete="${kind}"]`).click();
   await expect(page.locator('dialog')).toBeVisible();await shot(page,id,width,'confirm');
   await page.locator('[data-action="cancel-dialog"]').click();expect(await page.evaluate(()=>prototype.state.deleteAttempts)).toBe(0);
   await expect(page.locator(`[data-${kind}="${kind}-001"]`)).toBeVisible();
   await page.locator(`[data-delete="${kind}"]`).click();await page.locator('[data-confirm-delete]').click();
   await expect(page.locator('[data-delete-status]')).toHaveText('Saving removal…');await shot(page,id,width,'pending');await tick(page);
   if(id==='DELETE-FAIL'){
    await expect(page.locator('[data-article="article-001"]')).toBeVisible();await expect(page.locator('[data-delete-status]')).toContainText('Nothing was removed');await shot(page,id,width,'error');
    await page.locator('[data-delete="article"]').click();await page.locator('[data-confirm-delete]').click();await tick(page);
   }
   await expect(page.locator(`[data-${kind}="${kind}-001"]`)).toHaveCount(0);await expect(page.locator('[data-delete-status]')).toHaveText('Removal saved');
  }else if(id.startsWith('ACCOUNT')){
   await expect(page.locator('[data-action="sync"]')).toBeDisabled();await page.locator('[data-action="review"]').click();
   await expect(page.locator('[data-review-context]')).toContainText(id==='ACCOUNT-UNBOUND'?'no account binding':'previous account');await shot(page,id,width,'review');
   await page.locator('[data-action="cancel-dialog"]').click();await expect(page.locator('[data-action="sync"]')).toBeDisabled();
   await page.locator('[data-action="review"]').click();await page.locator('[data-action="approve-review"]').click();await expect(page.locator('[data-action="sync"]')).toBeEnabled();
  }else if(id.startsWith('QUIT')){
   await page.locator('[data-action="primary"]').click();await tick(page);await expect(page.locator('[data-player]')).toHaveAttribute('data-phase','playing');
   await page.locator('[data-action="quit"]').click();await expect(page.locator('[data-quit-status]')).toContainText('Saving local position');await expect(page.locator('[data-player]')).toHaveAttribute('data-phase','paused');await shot(page,id,width,'pending');await tick(page);
   if(id==='QUIT-FAIL'){
    await expect(page.locator('[data-quit-status]')).toContainText('Quit cancelled');expect(await page.evaluate(()=>prototype.state.quitComplete)).toBe(false);await shot(page,id,width,'error');
    await page.locator('[data-action="quit"]').click();await tick(page);
   }
   await expect(page.locator('[data-quit-status]')).toContainText('quit completed');
  }else if(id.startsWith('SYNC')){
   if(id==='SYNC-THROTTLE'){await expect(page.locator('[data-action="sync"]')).toBeDisabled();await expect(page.locator('[data-sync-status]')).toContainText('2 min');}
   else{await page.locator('[data-action="sync"]').click();await expect(page.locator('[data-sync-status]')).toContainText('Sending 2');await expect(page.locator('[data-action="sync"]')).toBeDisabled();await shot(page,id,width,'pending');await tick(page);await expect(page.locator('[data-sync-status]')).toContainText(id==='SYNC-FAIL'?'Send failed':'Local changes sent');}
   await expect(page.locator('[data-sync-status]')).not.toContainText('Synced');
  }else if(id==='PHONE-FETCH'){
   await expect(page.locator('[data-sync-status]')).toHaveText('Last successful fetch: Never');await page.locator('[data-action="fetch"]').click();await expect(page.locator('[data-action="fetch"]')).toBeDisabled();
   await expect(page.locator('[data-sync-status]')).toHaveText('Last successful fetch: Never');await shot(page,id,width,'pending');await tick(page);await expect(page.locator('[data-sync-status]')).toContainText('Oct 3, 2026');await expect(page.locator('[data-phone-stats]')).toBeVisible();await expect(page.locator('[data-stat]')).toHaveCount(0);
  }else if(id.startsWith('STATS')){
   if(id==='STATS-LOAD'||id==='STATS-FAIL'){await expect(page.locator('[data-stats-state]')).toContainText('Larder remains available');await shot(page,id,width,'initial');await page.locator('[data-action="load-stats"]').click();await expect(page.locator('[data-stats-state]')).toContainText('Loading');await tick(page);}
   await expect(page.locator('[data-stat]')).toHaveCount(7);await expect(page.locator('[data-tracking]')).toContainText('since Oct 3, 2026');
   await expect(page.locator('[data-stat="0"]')).toContainText('320 min');await expect(page.locator('[data-stat="5"]')).toContainText(id==='STATS-EMPTY'?'0 GB':'1.24 GB');
  }else if(id==='CARPLAY'){
   await page.locator('[data-action="car-row"]').click();await expect(page.locator('[data-play-status]')).toHaveText('Starting playback…');await shot(page,id,width,'pending');await tick(page);
   await expect(page.locator('[data-car-outcome]')).toHaveAttribute('data-car-result','resumed');await expect(page.locator('[data-now-playing]')).toBeVisible();await page.locator('[data-action="car-row"]').click();await expect(page.locator('[data-car-outcome]')).toHaveAttribute('data-car-result','alreadyPlaying');await expect(page.locator('[data-player]')).toHaveAttribute('data-phase','playing');expect(await page.evaluate(()=>prototype.state.carCallbacks)).toBe(2);
  }
  await shot(page,id,width,'settled');
  expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);
  fs.writeFileSync(path.join(evidence,'runtime.json'),JSON.stringify({node:process.version,nodeExecutable:process.execPath,playwright:require('@playwright/test/package.json').version,browser:browser.version(),engine:browser.browserType().name(),headless:true,distributionExecutable:require('@playwright/test').chromium.executablePath(),scope:'headless prototype only'},null,2));
 });
}
for(const surface of ['rail','side','full','phone','carplay'])for(const width of [390,1280]){
 test(`RACE ${surface} ${width} duplicate Pause seek selection ownership`,async({page})=>{
  await setup(page,'PLAY-DELAY',width);await choose(page,'#surface',surface);
  await page.locator('[data-action="primary"]').click();await page.locator('[data-action="primary"]').click();await page.keyboard.press('Space');
  expect(await page.evaluate(()=>prototype.state.attempts)).toBe(1);await shot(page,`RACE-${surface}`,width,'coalesced');
  await systemPause(page);await expect(page.locator('[data-play-status]')).toHaveText('Pausing…');await tick(page);await expect(page.locator('[data-player]')).toHaveAttribute('data-phase','paused');
  await page.locator('[data-action="primary"]').click();await page.locator('[data-seek]').press('End');await tick(page);await expect(page.locator('[data-position]')).toHaveText('28:00');await expect(page.locator('[data-player]')).toHaveAttribute('data-phase','paused');
  await page.locator('[data-action="primary"]').click();await page.locator('[data-select="fern-006"]').click();await tick(page);await expect(page.locator('[data-player]')).toHaveAttribute('data-fixture','fern-006');await expect(page.locator('[data-title]')).toHaveText('Fern Line');await expect(page.locator('[data-position]')).toHaveText('2:00');await expect(page.locator('[data-player]')).toHaveAttribute('data-phase','playing');
  await shot(page,`RACE-${surface}`,width,'settled');
  await page.locator('[data-page="settings"]').click();await expect(page.locator('[data-player]')).toHaveAttribute('data-fixture','fern-006');await page.reload();await expect(page.locator('[data-player]')).toHaveAttribute('data-fixture','fern-006');await expect(page.locator('h1')).toHaveText('Settings');
 });
}
for(const surface of ['rail','side','full','phone','carplay'])for(const width of [390,1280])test(`FAIL ${surface} ${width} first item feedback is canonical`,async({page})=>{
 await setup(page,'PLAY-FAIL',width);await choose(page,'#surface',surface);await page.locator('[data-action="primary"]').click();await expect(page.locator('[data-play-status]')).toHaveText('Starting playback…');await tick(page);await expect(page.locator('[data-play-status]')).toContainText('Playback refused');await shot(page,`FAIL-${surface}`,width,'error');
 await page.locator('[data-page="settings"]').click();await expect(page.locator('[data-play-status]')).toContainText('Playback refused');
});
test('CARPLAY failed and superseded callbacks do not open Now Playing',async({page})=>{
 await setup(page,'PLAY-FAIL',390);await choose(page,'#surface','carplay');await page.locator('[data-action="car-row"]').click();await tick(page);await expect(page.locator('[data-car-outcome]')).toHaveAttribute('data-car-result','failed');await expect(page.locator('[data-now-playing]')).toHaveCount(0);
 await choose(page,'#scenario','CARPLAY');await page.locator('[data-action="car-row"]').click();await systemPause(page);await tick(page);await expect(page.locator('[data-car-outcome]')).toHaveAttribute('data-car-result','superseded');await expect(page.locator('[data-now-playing]')).toHaveCount(0);expect(await page.evaluate(()=>prototype.state.carCallbacks)).toBe(1);
});

test('NAV-SCROLL Settings scroll and saved speed survive navigate and reload',async({page})=>{
 await setup(page,'STATS',390);await page.locator('[data-speed]').selectOption('1.5');await tick(page);
 await page.locator('#view').evaluate(el=>el.scrollTop=350);await page.locator('[data-page="larder"]').click();await page.locator('[data-page="settings"]').click();expect(await page.locator('#view').evaluate(el=>el.scrollTop)).toBe(350);await page.reload();expect(await page.locator('#view').evaluate(el=>el.scrollTop)).toBe(350);await expect(page.locator('[data-speed]')).toHaveValue('1.5');
 const tokens=await page.evaluate(()=>['--bg','--panel','--soft','--line','--ink','--muted','--leaf','--warn','--bad'].map(x=>getComputedStyle(document.documentElement).getPropertyValue(x).trim()));expect(tokens).toEqual(['#101512','#18201b','#223027','#344238','#edf1ed','#a8b5aa','#83bd8d','#d9b76a','#df8c82']);
});
