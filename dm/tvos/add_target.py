#!/usr/bin/env python3
"""Add DmTV to the existing generated iOS project without changing iOS objects.
Run again after ios/run.sh regenerates DmIOS.xcodeproj.
"""
import copy, hashlib, json, os, pathlib, re, subprocess
root=pathlib.Path(__file__).resolve().parents[1]
project=root/'ios/DmIOS.xcodeproj/project.pbxproj'
text=project.read_text()
p=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(project)])); o=p['objects']; new={}
def add(name,obj):
 k=hashlib.sha1(('DmTV:'+name).encode()).hexdigest()[:24].upper();new[k]=obj;return k
if any(v.get('name')=='DmTV' and v['isa']=='PBXNativeTarget' for v in o.values()):
 print('DmTV already exists');raise SystemExit
src=next(v for v in o.values() if v.get('name')=='DmIOS' and v['isa']=='PBXNativeTarget')
phases=[]
for ph in src['buildPhases']:
 v=copy.deepcopy(o[ph]);typ=v['isa']
 if typ not in ('PBXSourcesBuildPhase','PBXResourcesBuildPhase','PBXFrameworksBuildPhase'):continue
 if typ=='PBXSourcesBuildPhase':
  v['files']=[b for b in v['files'] if (lambda s:s.startswith(('host__','gfx__','third_party__')) or s in ('main.c','embed.S','dm_gamepad.m','dm_metal_cache_guard.c'))(o[o[b]['fileRef']]['path'])]
  ref=add('main ref',dict(isa='PBXFileReference',path='../tvos/main.m',sourceTree='SOURCE_ROOT',lastKnownFileType='sourcecode.c.objc'))
  v['files'].append(add('main build',dict(isa='PBXBuildFile',fileRef=ref)))
 if typ=='PBXFrameworksBuildPhase':v['files']=[]
 if typ=='PBXResourcesBuildPhase':
  v['files']=[b for b in v['files'] if o[o[b]['fileRef']]['path'] in ('Gen/dm','Gen/save_ref','Gen/romfs_overlay')]
  if (root/'tvos/Assets.xcassets').exists():
   ref=add('icon ref',dict(isa='PBXFileReference',path='../tvos/Assets.xcassets',sourceTree='SOURCE_ROOT',lastKnownFileType='folder.assetcatalog'))
   v['files'].append(add('icon build',dict(isa='PBXBuildFile',fileRef=ref)))
 phases.append(add(typ,v))
phases.append(add('clean metadata',dict(isa='PBXShellScriptBuildPhase',buildActionMask='2147483647',files=[],inputPaths=[],outputPaths=[],runOnlyForDeploymentPostprocessing='0',alwaysOutOfDate='1',name='Clean generated app metadata',shellPath='/bin/sh',shellScript='/usr/bin/xattr -cr "$TARGET_BUILD_DIR/$WRAPPER_NAME"')))
configs=[]
for c in o[src['buildConfigurationList']]['buildConfigurations']:
 v=copy.deepcopy(o[c]);s=v['buildSettings'];s.update(SDKROOT='appletvos',SUPPORTED_PLATFORMS='appletvos',TVOS_DEPLOYMENT_TARGET='26.0',TARGETED_DEVICE_FAMILY='3',PRODUCT_BUNDLE_IDENTIFIER=os.environ.get('TVOS_BUNDLE_ID','org.example.d2rmobile.tv'),DEVELOPMENT_TEAM=os.environ.get('TVOS_TEAM_ID',''),INFOPLIST_FILE='../tvos/Info.plist',OTHER_CFLAGS='$(inherited) -mcpu=apple-a15',CODE_SIGN_ENTITLEMENTS='',ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon' if (root/'tvos/Assets.xcassets').exists() else '')
 configs.append(add(v['name'],v))
cl=copy.deepcopy(o[src['buildConfigurationList']]);cl['buildConfigurations']=configs
product=add('product',dict(isa='PBXFileReference',path='DmTV.app',sourceTree='BUILT_PRODUCTS_DIR',explicitFileType='wrapper.application',includeInIndex='0'))
t=copy.deepcopy(src);t.update(name='DmTV',productName='DmTV',productReference=product,buildPhases=phases,buildConfigurationList=add('config list',cl),dependencies=[])
tid=add('target',t)
def dump(v):
 if isinstance(v,dict):return '{ '+ ' '.join(f'{k} = {dump(x)};' for k,x in v.items())+' }'
 if isinstance(v,list):return '( '+''.join(dump(x)+', ' for x in v)+' )'
 return json.dumps(str(v),ensure_ascii=False)
# Only insert new objects and one project target reference. Existing iOS objects stay byte-for-byte intact.
text=text.replace('objects = {','objects = {\n'+''.join(f'\t\t{k} = {dump(v)};\n' for k,v in new.items()),1)
text=re.sub(r'(targets = \()',r'\1\n\t\t\t\t'+tid+',',text,count=1)
project.write_text(text)
scheme=project.parent/'xcshareddata/xcschemes/DmTV.xcscheme';scheme.parent.mkdir(parents=True,exist_ok=True)
br=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{tid}" BuildableName="DmTV.app" BlueprintName="DmTV" ReferencedContainer="container:DmIOS.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{br}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Release" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{br}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{br}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print('Added DmTV; existing iOS target unchanged')
