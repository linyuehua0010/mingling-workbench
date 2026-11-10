import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'

test('feed refresh bypasses search cache and excludes both current batch and watched ledger', t => {
  const tempBase=fileURLToPath(new URL('../../../tmp/',import.meta.url))
  fs.mkdirSync(tempBase,{recursive:true})
  const root=fs.mkdtempSync(path.join(tempBase,'bili-feed-'))
  t.after(()=>fs.rmSync(root,{recursive:true,force:true}))
  const home=path.join(root,'home'), state=path.join(root,'state'), logs=path.join(root,'logs')
  for(const dir of [path.join(home,'.bili-ai'),state,logs])fs.mkdirSync(dir,{recursive:true})
  const write=(name,value)=>fs.writeFileSync(name,JSON.stringify(value))
  write(path.join(home,'.bili-ai/credentials.json'),{sessdata:'fixture',bili_jct:'fixture',buvid3:'fixture'})
  const config=path.join(state,'bili-whale.config.json')
  write(config,{preferences:{like:['猫咪']}})
  const candidate=n=>({bvid:`BV000000000${n}`,title:`猫咪${n}`,duration:'03:00',danmaku:100,play:10000,author:'fixture'})
  write(path.join(home,'.bili-ai/feed-search-cache.json'),{'猫咪|click':{at:Date.now(),data:{code:0,data:{result:[1,2,3,4].map(candidate)}}}})
  fs.writeFileSync(path.join(logs,'jobs.jsonl'),JSON.stringify({bv:'BV0000000002',status:'ok'})+'\n')
  const preload=path.join(root,'fetch.mjs')
  fs.writeFileSync(preload,`globalThis.fetch=async url=>{
    if(String(url).includes('/nav'))return Response.json({code:0,data:{wbi_img:{img_url:'https://fixture/abcdefghijklmnopqrstuvwxyz123456.png',sub_url:'https://fixture/123456abcdefghijklmnopqrstuvwxyz.png'}}});
    if(String(url).includes('/search/type')){console.error('fixture-network-search');return Response.json(${JSON.stringify({code:0,data:{result:[candidate(5)]}})});}
    throw new Error('unexpected network request: '+url);
  }`)
  const run=extra=>spawnSync(process.execPath,['--import',pathToFileURL(preload).href,fileURLToPath(new URL('../tools/commands/feed.mjs',import.meta.url)),
    '--source','search','--n','8','--per','8',...extra],{encoding:'utf8',timeout:20000,env:{...process.env,USERPROFILE:home,HOME:home,DSH_HOME:state,BILI_WHALE_CONFIG:config,BILI_LOGS_ROOT:logs}})
  const cached=run(['--exclude','BV0000000001'])
  assert.equal(cached.status,0,cached.stderr)
  assert.match(cached.stdout,/BV0000000003/);assert.match(cached.stdout,/BV0000000004/)
  assert.doesNotMatch(cached.stdout,/BV000000000[12]/);assert.doesNotMatch(cached.stderr,/fixture-network-search/)
  const fresh=run(['--refresh'])
  assert.equal(fresh.status,0,fresh.stderr);assert.match(fresh.stderr,/fixture-network-search/)
  assert.match(fresh.stdout,/BV0000000005/);assert.doesNotMatch(fresh.stdout,/BV000000000[1234]/)
})
