// Minimal tvOS shell: shared host, renderer and controller; no touch/download UI.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>
#include <pthread.h>
#include <signal.h>
#include "front.h"
#include "romfs_validate.h"
#include "dm_input.h"
#include "dmsh_chain.h"
#import <CommonCrypto/CommonDigest.h>
static CAMetalLayer *layer;
static BOOL started;
static __weak UIWindow *tvWindow;
void dm_gamepad_start(void (*callback)(int));
void dm_gamepad_reset(void);
void dm_focus_set(int);
void dm_audio_suspend(int);
void dm_gfx_suspend(int);
void guest_clock_freeze_for(int,int);
int dm_main(int,char **);
// Keep native ZR behavior until tvOS has a verified gameplay/panel observer.
int dm_front_navigation(void) { return 1; }
double dm_brightness_now(void) { return -1; }
int dm_thermal_now(void) { return (int)NSProcessInfo.processInfo.thermalState; }
void *front_metal_layer(void) { return (__bridge void *)layer; }
uint64_t front_game_res(int docked) { return ((uint64_t)(docked?900:720)<<32)|(docked?1600:1280); }
void front_run(void (*guest)(void)) {
 sigset_t all;sigfillset(&all);pthread_sigmask(SIG_UNBLOCK,&all,NULL);guest();
}
@interface TVView : UIView @end
@implementation TVView
+ (Class)layerClass { return CAMetalLayer.class; }
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)layoutSubviews { [super layoutSubviews];layer.drawableSize=CGSizeMake(1920,1080); }
@end
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(strong,nonatomic) UIWindow *window;
@end
int front_text_input(const char *title,const char *sub,const char *guide,const char *initial,int max_chars,char *out,int cap) {
 if(NSThread.isMainThread || !out || cap<1)return -1;
 dispatch_semaphore_t done=dispatch_semaphore_create(0);__block int accepted=0;
 dispatch_async(dispatch_get_main_queue(), ^{
  GCEventViewController *root=(GCEventViewController *)tvWindow.rootViewController;
  root.controllerUserInteractionEnabled=YES;dm_gamepad_reset();
  void (^finish)(void)=^{root.controllerUserInteractionEnabled=NO;[root.view becomeFirstResponder];dm_gamepad_reset();dispatch_semaphore_signal(done);};
  UIAlertController *a=[UIAlertController alertControllerWithTitle:@(title?:"") message:@(sub?:"") preferredStyle:UIAlertControllerStyleAlert];
  [a addTextFieldWithConfigurationHandler:^(UITextField *f){ f.text=@(initial?:"");f.placeholder=@(guide?:""); }];
  [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x){finish();}]];
  [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){snprintf(out,cap,"%s",a.textFields.firstObject.text.UTF8String);accepted=1;finish();}]];
  [tvWindow.rootViewController presentViewController:a animated:YES completion:nil];
 });
 dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);return accepted;
}
static void pathenv(const char *key,NSString *value) {setenv(key,value.fileSystemRepresentation,0);}
static NSDictionary *readJSON(NSString *path) {
 NSData *data=[NSData dataWithContentsOfFile:path];
 id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
 return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static NSMutableDictionary *validationStamps;
static BOOL checkedFile(NSString *path, NSDictionary *info) {
 NSDictionary *attr=[NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
 if(!attr || ![info[@"sha256"] isKindOfClass:NSString.class] || attr.fileSize != [info[@"size"] unsignedLongLongValue])return NO;
 NSString *stamp=[NSString stringWithFormat:@"%@|%llu|%.6f|%@",path,attr.fileSize,attr.fileModificationDate.timeIntervalSince1970,info[@"sha256"]];
 if([validationStamps[path] isEqualToString:stamp])return YES;
 FILE *file=fopen(path.fileSystemRepresentation,"rb");if(!file)return NO;
 CC_SHA256_CTX c;CC_SHA256_Init(&c);unsigned char buf[65536],digest[CC_SHA256_DIGEST_LENGTH];size_t n;
 while((n=fread(buf,1,sizeof buf,file))>0)CC_SHA256_Update(&c,buf,(CC_LONG)n);
 BOOL ok=!ferror(file);fclose(file);CC_SHA256_Final(digest,&c);
 NSMutableString *hex=[NSMutableString new];for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];
 ok=ok && [hex isEqualToString:info[@"sha256"]];
 if(ok)validationStamps[path]=stamp;return ok;
}
// Heavy validation runs off the UI thread. Size/hash stamps allow subsequent launches to reuse checks.
static NSString *validateResources(NSString *base, BOOL needsASTC) {
 NSString *stampPath=[base stringByAppendingPathComponent:@"validation-stamps.plist"];
 validationStamps=[[NSDictionary dictionaryWithContentsOfFile:stampPath] mutableCopy]?:[NSMutableDictionary new];
 // Migrate oversized development-only validation preferences into the file cache.
 NSString *domain=NSBundle.mainBundle.bundleIdentifier;
 NSMutableDictionary *prefs=[[NSUserDefaults.standardUserDefaults persistentDomainForName:domain] mutableCopy];
 for(NSString *key in prefs.allKeys)if([key hasPrefix:@"/var/mobile/"] || [key hasPrefix:@"/private/var/mobile/"])[prefs removeObjectForKey:key];
 if(prefs)[NSUserDefaults.standardUserDefaults setPersistentDomain:prefs forName:domain];
 NSFileManager *fm=NSFileManager.defaultManager;char why[1024]={0};
 if(!dm_romfs_validate([base stringByAppendingPathComponent:@"RomFS/data"].fileSystemRepresentation,why,sizeof why))return [NSString stringWithFormat:@"游戏文件尚未齐全\n%s",why];
 NSString *msl=[base stringByAppendingPathComponent:@"msl/b-" DMSH_CHAIN];
 NSDictionary *manifest=readJSON([msl stringByAppendingPathComponent:@"tvos-manifest.json"]);
 if(![manifest[@"platform"] isEqual:@"appletvos"] || ![manifest[@"chain"] isEqual:@DMSH_CHAIN] || [manifest[@"count"] intValue]!=6927)return @"等待完整的 tvOS 着色器";
 NSDictionary *baseFiles=manifest[@"files"];if(![baseFiles isKindOfClass:NSDictionary.class] || baseFiles.count!=13854)return @"着色器清单不完整";
 NSDictionary *variants=readJSON([msl stringByAppendingPathComponent:@"tvos-variants.json"]);
 if(![variants[@"platform"] isEqual:@"appletvos"] || ![variants[@"chain"] isEqual:@DMSH_CHAIN] || [variants[@"count"] intValue]!=285 || ![variants[@"files"] isKindOfClass:NSDictionary.class] || [variants[@"files"] count]!=285)return @"等待完整的 tvOS 着色器变体";
 NSMutableDictionary *files=[baseFiles mutableCopy];[files addEntriesFromDictionary:variants[@"files"]];
 for(NSString *name in files){
  if(![name isEqualToString:name.lastPathComponent] || !checkedFile([msl stringByAppendingPathComponent:name],files[name]))return [@"着色器校验未通过：" stringByAppendingString:name];
 }
 if(needsASTC){
  NSString *overlay=[base stringByAppendingPathComponent:@"romfs_overlay_astc"];
  NSDictionary *pack=readJSON([overlay stringByAppendingPathComponent:@"pack.json"]);
  NSString *name=pack[@"name"];
  if(![name isKindOfClass:NSString.class] || ![name isEqualToString:name.lastPathComponent] || !checkedFile([[base stringByAppendingPathComponent:@"astc/data"] stringByAppendingPathComponent:name],pack))return @"等待 A15 纹理补充包";
  if(![fm fileExistsAtPath:[overlay stringByAppendingPathComponent:@"data/.build.config"]])return @"等待 A15 纹理索引";
 }
 [validationStamps writeToFile:stampPath atomically:YES];
 return nil;
}
static void *boot(void *unused) { @autoreleasepool {
 NSString *res=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"];
 char *argv[]={"dmhost",(char *)res.fileSystemRepresentation,"main","sdk",NULL};
 void dm_padmode_request(int);dm_padmode_request(1);
 NSLog(@"D2R TV: starting shared host");int rc=dm_main(4,argv);NSLog(@"D2R TV: host returned %d",rc);
 } return NULL;
}
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
 self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
 tvWindow=self.window;
 GCEventViewController *vc=[GCEventViewController new];vc.controllerUserInteractionEnabled=NO;TVView *view=[[TVView alloc] initWithFrame:self.window.bounds];vc.view=view;
 layer=(CAMetalLayer *)view.layer;layer.device=MTLCreateSystemDefaultDevice();layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=YES;
 self.window.rootViewController=vc;[self.window makeKeyAndVisible];[view becomeFirstResponder];dm_gamepad_start(NULL);
 NSString *cache=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject;
 NSString *base=[cache stringByAppendingPathComponent:@"D2R"];
 NSFileManager *fm=NSFileManager.defaultManager;NSError *error=nil;
 for(NSString *p in @[@"save",@"temp",@"RomFS",@"msl"]){[fm createDirectoryAtPath:[base stringByAppendingPathComponent:p] withIntermediateDirectories:YES attributes:nil error:&error];}
 pathenv("DM_ROMFS",[base stringByAppendingPathComponent:@"RomFS"]);pathenv("DM_SAVE",[base stringByAppendingPathComponent:@"save"]);pathenv("DM_TEMP",[base stringByAppendingPathComponent:@"temp"]);pathenv("DM_MSL_DIR",[base stringByAppendingPathComponent:@"msl"]);
 pathenv("DM_NVN_SHMAP",[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm/shader_map.tsv"]);
 BOOL diagnosticBC=getenv("DM_TV_ALLOW_BC_FALLBACK")!=NULL;
 BOOL needsASTC=!layer.device.supportsBCTextureCompression && !diagnosticBC;
 if(diagnosticBC)NSLog(@"D2R TV: diagnostic original-BC fallback enabled; memory/performance not validated");
 NSString *overlay=needsASTC ? [NSString stringWithFormat:@"%@:%@",[base stringByAppendingPathComponent:@"romfs_overlay_astc"],[base stringByAppendingPathComponent:@"astc"]] : [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs_overlay"];
 pathenv("DM_ROMFS_OVERLAY",overlay);
 void dm_custom_init(const char *);dm_custom_init(base.fileSystemRepresentation);
 chdir(base.fileSystemRepresentation);
 NSLog(@"D2R TV: shell ready; GPU=%@ BC=%d resources=%@",layer.device.name,layer.device.supportsBCTextureCompression,base);
 NSError *metalError=nil;
 id<MTL4CommandQueue> probe=[layer.device newMTL4CommandQueueWithDescriptor:[MTL4CommandQueueDescriptor new] error:&metalError];
 NSLog(@"D2R TV: Metal4 queue=%@ error=%@",probe,metalError);
 UILabel *label=[[UILabel alloc] initWithFrame:CGRectInset(view.bounds,100,100)];label.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;label.numberOfLines=0;label.textColor=UIColor.whiteColor;label.textAlignment=NSTextAlignmentCenter;label.font=[UIFont systemFontOfSize:30];
 label.text=@"D2R TV\n正在检查游戏文件";[view addSubview:label];
 if(!probe || error){label.text=@"D2R TV\n设备初始化失败，请查看启动日志";NSLog(@"D2R TV: initialization error %@",error?:metalError);return;}
 dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
  NSString *problem=validateResources(base,needsASTC);
  dispatch_async(dispatch_get_main_queue(), ^{
   if(problem){label.text=[@"D2R TV\n" stringByAppendingString:problem];NSLog(@"D2R TV: BLOCKED %@",problem);return;}
   [label removeFromSuperview];
   pthread_attr_t attr;pthread_attr_init(&attr);pthread_attr_setstacksize(&attr,16*1024*1024);pthread_t thread;int rc=pthread_create(&thread,&attr,boot,NULL);pthread_attr_destroy(&attr);
   if(!rc){pthread_detach(thread);started=YES;
    const char *shot=getenv("DM_TV_SHOT_SECONDS");int seconds=shot?atoi(shot):0;
    if(seconds>0)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)seconds*NSEC_PER_SEC),dispatch_get_main_queue(),^{
     void mtl_grab_next_present(void (^)(CGImageRef));uint64_t mtl_present_count(void);
     NSLog(@"D2R TV: capture requested, presented=%llu",(unsigned long long)mtl_present_count());
     mtl_grab_next_present(^(CGImageRef image){@autoreleasepool{
      NSData *png=UIImagePNGRepresentation([UIImage imageWithCGImage:image]);
      BOOL ok=[png writeToFile:[base stringByAppendingPathComponent:@"frame.png"] atomically:YES];
      NSLog(@"D2R TV: rendered frame saved=%d bytes=%lu",ok,(unsigned long)png.length);
     }});
    });
   }else NSLog(@"D2R TV: pthread_create failed %d",rc);
  });
 });
 return;
}
- (void)sceneWillResignActive:(UIScene *)scene {dm_gamepad_reset();if(started)dm_focus_set(2);}
- (void)sceneDidEnterBackground:(UIScene *)scene {if(started){dm_focus_set(3);dm_audio_suspend(1);guest_clock_freeze_for(1,1);dm_gfx_suspend(1);}}
- (void)sceneWillEnterForeground:(UIScene *)scene {if(started){dm_gfx_suspend(0);guest_clock_freeze_for(1,0);dm_audio_suspend(0);}}
- (void)sceneDidBecomeActive:(UIScene *)scene {if(!self.window.rootViewController.presentedViewController){((GCEventViewController *)self.window.rootViewController).controllerUserInteractionEnabled=NO;[self.window.rootViewController.view becomeFirstResponder];}if(started)dm_focus_set(1);}
@end
@interface App : UIResponder <UIApplicationDelegate> @end
@implementation App @end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(App.class));}}
