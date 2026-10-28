// Original watch/status artwork, generated without external graphics packages.
import { mkdir, writeFile } from 'node:fs/promises';
import { deflateSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root=fileURLToPath(new URL('../',import.meta.url));
const crc = bytes => {
  let c=0xffffffff;
  for(const b of bytes){c^=b;for(let i=0;i<8;i++)c=c&1?0xedb88320^(c>>>1):c>>>1;}
  return (c^0xffffffff)>>>0;
};
function chunk(type,bytes){const n=Buffer.alloc(4);n.writeUInt32BE(bytes.length);const data=Buffer.concat([Buffer.from(type),bytes]);const tail=Buffer.alloc(4);tail.writeUInt32BE(crc(data));return Buffer.concat([n,data,tail]);}
function inside(x,y,l,t,w,h,r){const a=Math.max(l+r,Math.min(x,l+w-r)),b=Math.max(t+r,Math.min(y,t+h-r));return (x-a)**2+(y-b)**2<=r*r;}
function icon(n){
  const raw=Buffer.alloc((n*3+1)*n);
  for(let y=0;y<n;y++)for(let x=0;x<n;x++){
    const a=(x+.5)/n,b=(y+.5)/n;let color=[20,20,20];
    if(inside(a,b,.39,.08,.22,.84,.08))color=[61,61,61];
    if(inside(a,b,.21,.22,.58,.56,.16))color=[245,245,245];
    if(inside(a,b,.255,.265,.49,.47,.12))color=[20,20,20];
    for(const [l,h] of [[.37,.13],[.48,.23],[.59,.34]])if(inside(a,b,l,.66-h,.055,h,.027))color=[92,217,184];
    const offset=y*(n*3+1)+1+x*3;raw.set(color,offset);
  }
  const header=Buffer.alloc(13);header.writeUInt32BE(n,0);header.writeUInt32BE(n,4);header[8]=8;header[9]=2;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header),chunk('IDAT',deflateSync(raw)),chunk('IEND',Buffer.alloc(0))]);
}
for(const platform of ['Mac','iOS','Watch']){
  const assets=path.join(root,'Resources',platform,'Assets.xcassets'),folder=path.join(assets,'AppIcon.appiconset');
  await mkdir(folder,{recursive:true});
  const slots=platform==='Mac'?[16,32,128,256,512].flatMap(n=>[{n,idiom:'mac',size:`${n}x${n}`,scale:'1x'},{n:n*2,idiom:'mac',size:`${n}x${n}`,scale:'2x'}]):[{n:1024,idiom:'universal',size:'1024x1024',platform:platform==='iOS'?'ios':'watchos'}];
  for(const n of new Set(slots.map(x=>x.n)))await writeFile(path.join(folder,`icon-${n}.png`),icon(n));
  const info={author:'xcode',version:1};
  await writeFile(path.join(assets,'Contents.json'),JSON.stringify({info},null,2)+'\n');
  await writeFile(path.join(folder,'Contents.json'),JSON.stringify({images:slots.map(({n,...slot})=>({...slot,filename:`icon-${n}.png`})),info},null,2)+'\n');
}
console.log('Generated original Codex Control icons.');
