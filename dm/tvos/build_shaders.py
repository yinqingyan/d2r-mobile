#!/usr/bin/env python3
"""Compile the existing translated MSL for physical tvOS, leaving iOS caches intact."""
import argparse, concurrent.futures, csv, hashlib, json, os, pathlib, re, subprocess, sys
p=argparse.ArgumentParser();p.add_argument('source',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);p.add_argument('--toolchain',type=pathlib.Path,required=True);p.add_argument('-j',type=int,default=3);a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[1]
chain=re.search(r'#define DMSH_CHAIN "([^"]+)"',(root/'gfx/nvn/dmsh_chain.h').read_text())[1]
rows=csv.DictReader((l for l in (root/'gfx/nvn/shader_map.tsv').read_text().splitlines() if not l.startswith('#')),delimiter='\t')
keys=sorted({r['dm_ctl_sha16'] for r in rows});out=a.output.resolve()/('b-'+chain);out.mkdir(parents=True,exist_ok=True)
modules=a.output.resolve()/'module-cache';modules.mkdir(exist_ok=True)
metal=a.toolchain/'usr/bin/metal';lib=a.toolchain/'usr/bin/metallib'
record='metal -c -target air64-apple-tvos26.0; metallib'
version=subprocess.check_output([str(metal),'--version'],text=True)
def build(k):
 src=a.source/(k+'_b.metal');meta=a.source/(k+'_b.json');target=out/(k+'_b.metallib');ref=out/(k+'_b.json');stamp=out/(k+'.sha256')
 j=json.loads(meta.read_text());assert j['chain']==chain,(k,j.get('chain'))
 fingerprint=hashlib.sha256(src.read_bytes()+meta.read_bytes()+version.encode()+record.encode()).hexdigest()
 if target.exists() and ref.exists() and stamp.exists() and stamp.read_text()==fingerprint:return 'cached'
 air=out/(k+'.air');tmp=out/(k+'.tmp.metallib')
 for cmd in ([str(metal),'-c','-target','air64-apple-tvos26.0','-fmodules-cache-path='+str(modules),str(src),'-o',str(air)],[str(lib),str(air),'-o',str(tmp)]):
  proc=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
  if proc.returncode:raise RuntimeError(k+': '+proc.stdout)
 os.replace(tmp,target);air.unlink();j['chain_metal']=record;j['platform']='appletvos';ref.write_text(json.dumps(j,ensure_ascii=False,indent=1));stamp.write_text(fingerprint);return 'built'
failed=[];done=0
with concurrent.futures.ThreadPoolExecutor(max_workers=a.j) as pool:
 futures={pool.submit(build,k):k for k in keys}
 for f in concurrent.futures.as_completed(futures):
  try:f.result()
  except Exception as e:failed.append(str(e));print('ERROR',e,flush=True)
  done+=1
  if done%100==0 or done==len(keys):print(f'{done}/{len(keys)} complete; failures={len(failed)}',flush=True)
if failed:(a.output/'errors.txt').write_text('\n'.join(failed));sys.exit(1)
manifest={'platform':'appletvos','chain':chain,'count':len(keys),'compiler':version,'files':{}}
for k in keys:
 for ext in ['metallib','json']:
  q=out/(k+'_b.'+ext);manifest['files'][q.name]={'size':q.stat().st_size,'sha256':hashlib.sha256(q.read_bytes()).hexdigest()}
(out/'tvos-manifest.json').write_text(json.dumps(manifest,indent=1));print('PASS: complete tvOS shader cache',flush=True)
