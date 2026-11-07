const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../web/index.html'),'utf8');
const script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
function fixture(){
  const elements={}, handlers={}, messages=[];
  const element=id=>elements[id]??=( {id,children:[],innerHTML:'',textContent:'',value:'',open:false,onclick:null,
    matches:()=>false,blur(){document.activeElement={matches:()=>false}},showModal(){this.open=true},close(){this.open=false}} );
  const document={getElementById:id=>elements[id]||null,activeElement:{matches:()=>false},addEventListener:(name,fn)=>handlers[name]=fn};
  const styles=new Map();
  document.documentElement={dataset:{},style:{setProperty:(k,v)=>styles.set(k,v),removeProperty:k=>styles.delete(k)}};
  for(const id of ['nav','clock','workspace','connection','side-version','crumb','toast','notification','page','editor','save-ask','cancel-ask','ask-text'])element(id);
  const context=vm.createContext({document,window:{chrome:{webview:{postMessage:m=>messages.push(m),addEventListener(){}}},scrollTo(){}},setTimeout(){},console});
  vm.runInContext(script,context);
  const state={version:'V3-snapshot-3',tab:0,bsec:0,clock:'2026-11-07 20:00:00',workspace:'test-workspace',toast:'',stats:['0','0','0','0'],services:[{name:'AstrBot',desc:'对话',port:'6199',up:false,pid:0}],jobs:[],feed:[],items:[],features:[false,false,false,false],docs:[{title:'教程',hint:'离线',id:'guide'}],docsel:-1,asks:[{title:'帮助',body:'测试'}],updates:[],logsrc:0,check:'未检查',input:'',watchBusy:false,progress:0};
  return {context,elements,handlers,messages,element,state,styles,render:s=>{context.fixtureState=s;vm.runInContext('render(fixtureState)',context)}};
}
test('all seven pages render without a backend or script errors',()=>{
  const f=fixture();assert.equal(f.messages[0].cmd,'ready');
  for(let tab=0;tab<7;tab++){f.render({...f.state,tab});assert.match(f.elements.page.innerHTML,/<h1>/);}
  for(let bsec=0;bsec<4;bsec++){f.render({...f.state,tab:1,bsec});assert.match(f.elements.page.innerHTML,/一起看看/);}
});
test('backend text is escaped before entering HTML, including result and logs',()=>{
  const f=fixture(),payload='<img src=x onerror="alert(1)">';
  f.render({...f.state,tab:3,log:payload});
  assert.ok(!f.elements.page.innerHTML.includes(payload));assert.match(f.elements.page.innerHTML,/&lt;img/);
  f.render({...f.state,tab:1,bsec:2,resultOk:true,result:payload,resultTitle:payload});
  assert.ok(!f.elements.page.innerHTML.includes(payload));
});
test('live pushes preserve a focused draft while still updating status and toasts',()=>{
  const f=fixture();f.render(f.state);const before=f.elements.page.innerHTML;
  f.context.document.activeElement={matches:()=>true};
  f.render({...f.state,stats:['9','1','0','0'],toast:'完成',clock:'later'});
  assert.equal(f.elements.page.innerHTML,before);assert.equal(f.elements.toast.textContent,'完成');assert.equal(f.elements.clock.textContent,'later');
});
test('live pushes preserve unsaved configuration fields',()=>{
  const f=fixture();f.render({...f.state,tab:1,bsec:3});const before=f.elements.page.innerHTML;
  f.element('config-form');f.render({...f.state,tab:1,bsec:3,configNote:'连接成功',stats:['8','0','0','0']});
  assert.equal(f.elements.page.innerHTML,before);
});
test('typing digits does not trigger navigation; page keyboard navigation has typed parameters',()=>{
  const f=fixture();let prevented=false;
  f.handlers.keydown({key:'3',target:{matches:()=>true}});assert.equal(f.messages.length,1);
  f.handlers.keydown({key:'3',target:{matches:()=>false},preventDefault(){prevented=true}});
  assert.equal(f.messages.at(-1).cmd,'tab');assert.equal(f.messages.at(-1).index,2);assert.equal(prevented,true);
});
test('configuration submit sends only editable fields and clears entered secrets',()=>{
  const f=fixture();const secret={dataset:{row:'2'},type:'password',value:'test-secret',defaultValue:'',readOnly:false};
  const fields=[{dataset:{row:'1'},type:'checkbox',checked:true,defaultChecked:false,readOnly:false},secret,{dataset:{row:'4'},value:'readonly',readOnly:true}];
  const form={id:'config-form',dataset:{kind:'link'},querySelectorAll:selector=>selector.includes('password')?[secret]:fields};
  f.handlers.submit({target:form,preventDefault(){}});
  const m=f.messages.at(-1);assert.equal(m.cmd,'configsave');assert.equal(m.fields.length,2);assert.equal(m.fields[0].value,'开');assert.equal(secret.value,'');
});

test('unchanged fields are not submitted as edits',()=>{
  const f=fixture();
  const fields=[{dataset:{row:'1'},type:'text',value:'original',defaultValue:'original'}, {dataset:{row:'2'},type:'checkbox',checked:true,defaultChecked:true}];
  f.handlers.submit({target:{id:'config-form',dataset:{kind:'bili'},querySelectorAll:s=>s.includes('password')?[]:fields},preventDefault(){}});
  assert.equal(f.messages.at(-1).fields.length,0);
});

test('custom colors apply safely and switching to daytime clears overrides',()=>{
  const f=fixture();
  f.render({...f.state,tab:5,theme:'custom',themeBase:'light',theme_bg:'#fbf6ed',theme_accent:'#883399',theme_ink:'url(evil)'});
  assert.equal(f.context.document.documentElement.dataset.theme,'custom');
  assert.equal(f.styles.get('--bg'),'#fbf6ed');
  assert.equal(f.styles.get('--ink'),'#e9effc');
  assert.match(f.elements.page.innerHTML,/应用自定义主题/);
  f.render({...f.state,theme:'light'});
  assert.equal(f.context.document.documentElement.dataset.theme,'light');
  assert.equal(f.styles.has('--bg'),false);
});

test('theme form submits palette and base through the native settings bridge',()=>{
  const f=fixture();f.render({...f.state,tab:5});
  f.element('theme-base').value='light';
  f.element('theme-bg').value='#fafafa';
  f.handlers.submit({target:{id:'theme-form'},preventDefault(){}});
  const m=f.messages.at(-1);
  assert.equal(m.cmd,'theme');assert.equal(m.value,'custom');assert.equal(m.base,'light');assert.equal(m.bg,'#fafafa');
});
