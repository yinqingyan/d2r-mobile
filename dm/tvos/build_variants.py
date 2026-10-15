#!/usr/bin/env python3
"""Regenerate framebuffer-fetch MSL using the existing translator rules, then compile for tvOS."""
import argparse, concurrent.futures, hashlib, json, pathlib, re, subprocess, sys
p=argparse.ArgumentParser();p.add_argument('source',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);p.add_argument('--toolchain',type=pathlib.Path,required=True);p.add_argument('-j',type=int,default=2);a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'gfx/tools'));import dmsh_fetch
chain=re.search(r'#define DMSH_CHAIN "([^"]+)"',(root/'gfx/nvn/dmsh_chain.h').read_text())[1]
out=a.output.resolve()/('b-'+chain);out.mkdir(parents=True,exist_ok=True);modules=a.output.resolve()/'module-cache'
want={s.strip() for s in (root/'gfx/nvn/bf_want.tsv').read_text().splitlines() if s.strip() and not s.startswith('#')}
tasks=[]
for f in sorted(a.source.glob('*_b.json')):
 j=json.loads(f.read_text())
 if j.get('fetch'):tasks.append((f,j))
print('Expected framebuffer-fetch variants:',len(tasks),flush=True)
def build(item):
 f,j=item;k=f.stem[:-2];src=(a.source/(k+'_b.metal')).read_text();msl,meta=dmsh_fetch.variant(src,j['bindings'],om_only_ok=k in want)
 assert msl and meta==j['fetch'],f'variant reflection mismatch {k}'
 source=out/(k+'_bf.metal');source.write_text(msl);air=out/(k+'_bf.air');target=out/(k+'_bf.metallib')
 for cmd in ([str(a.toolchain/'usr/bin/metal'),'-c','-target','air64-apple-tvos26.0','-fmodules-cache-path='+str(modules),str(source),'-o',str(air)],[str(a.toolchain/'usr/bin/metallib'),str(air),'-o',str(target)]):
  r=subprocess.run(cmd,capture_output=True,text=True)
  if r.returncode:raise RuntimeError(k+': '+r.stderr)
 air.unlink();source.unlink();return target
files=[]
with concurrent.futures.ThreadPoolExecutor(max_workers=a.j) as pool:
 for i,f in enumerate(pool.map(build,tasks),1):
  files.append(f)
  if i%25==0:print(i,'/',len(tasks),flush=True)
manifest={'platform':'appletvos','chain':chain,'count':len(files),'files':{f.name:{'size':f.stat().st_size,'sha256':hashlib.sha256(f.read_bytes()).hexdigest()} for f in files}}
(out/'tvos-variants.json').write_text(json.dumps(manifest,indent=1));print('PASS all variants',len(files),flush=True)
