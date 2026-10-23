#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#include "HostInternal.h"
#include "WasmFutex.h"
#include "wasm-rt-impl.h"
#include <pthread.h>
#include <limits.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include "NativePackedAssetCache.h"
#include "NativeAssetPreload.h"
#include "NativeOIV.h"

// A language choice requested by the native app when the WASM engine boots.
// This does not guarantee the underlying web game uses the locale or has the necessary fonts.
const char *PGSelectedGameLanguage(void) {
  NSString *chosen = [[NSUserDefaults standardUserDefaults] stringForKey:@"gtaPortAppLanguage"];
  static const char *supported[] = {
    "en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "ja-JP", "ko-KR",
    "pl-PL", "pt-BR", "ru-RU", "zh-CN", "es-MX", "zh-TW"
  };
  if (chosen != nil) {
    // Simplified Chinese (chinesesimp) can't load its fonts from these game files: GFxLoader fails on
    // gfxfontlib.gfx, then minimap.gfx and the game crash at every load (GTA-164, logs 1876, 1943 and ~28 older
    // ones). The game runs in Traditional Chinese then; the app itself stays in Simplified Chinese.
    if ([chosen isEqualToString:@"zh-CN"] && !getenv("PG_GAME_ZH_CN")) return "zh-TW";
    for (size_t i = 0; i < sizeof(supported)/sizeof(supported[0]); ++i) {
      if ([chosen isEqualToString:[NSString stringWithUTF8String:supported[i]]]) return supported[i];
    }
  }
  return "en-US";
}

// The server that holds your own copy of the game files (set in the app).
static NSString *assetServer=@"";
static void PGReapplyMods(void);static bool modsWantLocal;static bool modsLocked;static NSArray *modsBaseFiles;
void PGSetAssetServer(const char *url){
  NSString *value=[[NSString stringWithUTF8String:url?url:""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  while([value hasSuffix:@"/"])value=[value substringToIndex:value.length-1];
  assetServer=value;
  // Mods installed since the file list was first read (Settings › Mods on the home screen) count too.
  if(modsBaseFiles&&!modsLocked)PGReapplyMods();
}
NSString *PGAssetServer(void){return assetServer;}

// A folder on this device with the game's data/ files (chosen in the app):
// every asset read goes straight to the file; no server, no download cache.
static NSString *localDataRoot;
void PGSetLocalGameFolder(const char *dataPath){
  localDataRoot=dataPath&&*dataPath?[NSString stringWithUTF8String:dataPath]:nil;
  if(localDataRoot)pg_log("Game files are read from the folder on this device; no server is used.");
  // The file list may have been loaded before the folder was known (home screen); mods inside archives
  // and add-on packs need the folder, so they are applied again now, before the engine starts.
  if(localDataRoot&&modsBaseFiles&&!modsLocked)PGReapplyMods();
}
bool PGUsingLocalGameFolder(void){return localDataRoot!=nil;}
#include "NativeAssetHints.h"

@interface PGAssetCondition : NSCondition
@property(nonatomic,strong) NSMutableArray<NSArray<NSNumber *> *> *flights;
@end
@implementation PGAssetCondition
- (instancetype)init {if((self=[super init]))_flights=[NSMutableArray array];return self;}
@end

static NSArray *assetFiles;
static NSString *assetVersion;
static NSArray<PGAssetCondition *> *assetLocks;
static NSString *cacheRoot;
static NSURLSession *assetSession;
static struct w2c_env *assetHost;
static uint64_t assetTable;
static _Atomic uint64_t fetchedBytes;
static _Atomic uint64_t nextReport;
static _Atomic int activePrefetch;
static _Atomic int activeSpeculative;
static dispatch_queue_t prefetchQueue,speculativeQueue;
static bool assetBalancedQOS;
static NSString *packedRoot;
static int assetTraceFD=-1;
static int assetTimingFD=-1;
static _Atomic uint64_t assetTimingRecords;
static bool assetStreamSimulation,assetConcurrentFills=true;
static unsigned assetSimulatedLatencyMS;
static _Thread_local bool assetPrefetchRead;
static _Thread_local bool assetSpeculativeRead;
static bool assetQueuedHints=true;
static PGAssetHintQueue normalHints,lowHints;
static uint64_t hintsNormalSeen,hintsLowSeen,hintsScheduled,hintsCached,hintsLapped;
static _Thread_local double assetReadNetworkMS,assetReadLockMS;
static _Thread_local uint64_t assetReadNetworkBytes;
static _Thread_local unsigned assetReadSource;
static _Thread_local bool assetSizeMismatch;
static double assetNowMS(void){return NSProcessInfo.processInfo.systemUptime*1000;}
#ifdef PG_ASSET_TEST_HOOK
static void (*assetFillTestHook)(uint32_t,uint64_t);
#endif
static BOOL assetBlockInFlight(PGAssetCondition *condition,uint64_t block){
  for(NSArray<NSNumber *> *range in condition.flights)if(block>=range[0].unsignedLongLongValue&&block<range[1].unsignedLongLongValue)return YES;
  return NO;
}

// Mods (GitHub #3): files in the app's Mods folder (Files > GTA V Port > Mods) replace the game file
// at the same path, e.g. Mods/common/data/handling.meta or Mods/x64/levels/gta5/vehicles.rpf. They are
// read at launch: the game sees their sizes through a merged manifest, and their reads skip the
// download cache. Archives must be encrypted like the game's own (AES); OPEN or unencrypted ones
// would stop the game, so they are skipped with a log line.
static NSDictionary<NSNumber *,NSString *> *modFiles;
static NSString *modsManifest;
// Read by the engine when it starts: by then a game folder on the device would have been set.
const char *pg_assets_manifest_override(void){
  modsLocked=true;   // the engine has the file list now: mods stay as they are until the next launch
  if(modsWantLocal){static bool told;if(!told){told=true;pg_log("Mods: cars, skins and add-on packs inside the game's archives need the game files on this iPhone (Game files > A folder on this iPhone); with a server they are not loaded. Whole-file mods still work.");}}
  return modsManifest.fileSystemRepresentation;
}
// "Start without mods" (GTA-153): this launch reads an empty folder instead, so no mod file, pack or script loads.
static bool modsOff;
static NSString *modsFolder(void){
  if(modsOff)return [NSTemporaryDirectory() stringByAppendingPathComponent:@"NoMods"];
  const char *test=getenv("PG_MODS_FOLDER");
  if(test&&*test)return @(test);
  return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"Mods"];
}
void PGSetModsOff(bool off){
  if(modsOff==off||modsLocked)return;
  modsOff=off;
  if(off){[NSFileManager.defaultManager removeItemAtPath:modsFolder() error:nil];pg_log("Mods: off for this start (Start without mods); they stay installed.");}
  if(modsBaseFiles)PGReapplyMods();
}
// Which of the Mods folder's top-level entries the game used this launch (GTA-153): after an update, a mod the
// previous version didn't use stays off until the player turns it on (ModGuard in App/ModInstaller.swift).
static NSMutableSet<NSString *> *modsUsed;
void pg_mod_path_used(const char *path){
  if(!path||modsOff)return;
  NSString *root=[modsFolder().stringByResolvingSymlinksInPath stringByAppendingString:@"/"],*full=@(path).stringByResolvingSymlinksInPath;
  if(![full hasPrefix:root])return;
  NSString *entry=[full substringFromIndex:root.length].pathComponents.firstObject;
  if(!entry.length)return;
  @synchronized(NSFileManager.class){if(!modsUsed)modsUsed=[NSMutableSet set];[modsUsed addObject:entry];}
}
size_t PGModsUsed(char *out,size_t capacity){
  if(!out||!capacity)return 0;
  NSString *list;
  @synchronized(NSFileManager.class){list=[modsUsed.allObjects componentsJoinedByString:@"\n"]?:@"";}
  snprintf(out,capacity,"%s",list.UTF8String);
  return strlen(out);
}
// Mods made for GTA V Enhanced (the 2025 PC edition, GTA-87) keep their models and textures in newer resource
// versions, and the game here (the original PC version) stops on them: "Code is expecting version 162 but
// file adder.yft has version 171". Checked before the game starts and by the installer: a loose resource by
// its RSC7 header, an archive (add-on pack dlc.rpf, also the archives inside it) by its table of contents
// when it isn't encrypted, as OpenIV saves them (OPEN). An encrypted archive can't be checked and passes.
static const struct {const char *ext;uint32_t legacy,enhanced;} pgResourceVersions[]={{"yft",162,171},{"ydr",165,159},{"ydd",165,159},{"ytd",13,5}};
static bool pg_resource_version_problem(const char *name,uint32_t version,char *why,size_t n){
  const char *dot=strrchr(name,'.');if(!dot)return false;
  for(size_t i=0;i<sizeof pgResourceVersions/sizeof *pgResourceVersions;i++){
    if(strcasecmp(dot+1,pgResourceVersions[i].ext)||version==pgResourceVersions[i].legacy)continue;
    const char *base=strrchr(name,'/');base=base?base+1:name;
    if(version==pgResourceVersions[i].enhanced)snprintf(why,n,"made for GTA V Enhanced (%s is version %u, this game reads %u; install the mod's Legacy (original PC) version)",base,version,pgResourceVersions[i].legacy);
    else snprintf(why,n,"made for another game version (%s is version %u, this game reads %u)",base,version,pgResourceVersions[i].legacy);
    return true;
  }
  return false;
}
static bool pg_rpf_version_problem(FILE *file,uint64_t base,int depth,char *why,size_t n){
  uint32_t header[4];
  if(fseeko(file,(off_t)base,SEEK_SET)||fread(header,4,4,file)!=4||header[0]!=0x52504637)return false;
  if(header[3]&&header[3]!=0x4E45504F)return false;                  // encrypted: can't be read here
  uint32_t count=header[1],namesLength=header[2];
  if(!count||count>500000||namesLength>64u<<20)return false;
  uint64_t *entries=malloc(16ull*count);char *names=malloc(namesLength+1);bool problem=false;
  if(entries&&names&&fread(entries,16,count,file)==count&&fread(names,1,namesLength,file)==namesLength){
    names[namesLength]=0;
    for(uint32_t i=1;i<count&&!problem;i++){
      uint64_t e=entries[2*i];uint32_t offset=(uint32_t)((e>>40)&0x7FFFFF),nameAt=(uint32_t)(e&0xFFFF);
      if(offset==0x7FFFFF||nameAt>=namesLength)continue;
      const char *name=names+nameAt;
      if(e>>63){
        uint32_t system=(uint32_t)entries[2*i+1],graphics=(uint32_t)(entries[2*i+1]>>32);
        problem=pg_resource_version_problem(name,(((system>>28)&0xF)<<4)|((graphics>>28)&0xF),why,n);
      }else if(depth<4){
        size_t length=strlen(name);
        if(length>4&&!strcasecmp(name+length-4,".rpf"))problem=pg_rpf_version_problem(file,base+512ull*offset,depth+1,why,n);
      }
    }
  }
  free(entries);free(names);return problem;
}
bool PGModFileProblem(const char *path,char *why,size_t n){
  FILE *file=fopen(path,"rb");if(!file)return false;
  uint32_t header[4]={0};bool problem=false;
  if(fread(header,4,4,file)==4){
    if(header[0]==0x37435352)problem=pg_resource_version_problem(path,header[1],why,n);
    // An archive saved with no encryption at all (key 0; OpenIV saves OPEN, some RPF tools save none) stops
    // the engine: "Unencrypted archives no longer supported" (log 1121, a PC audio archive).
    else if(header[0]==0x52504637&&header[3]==0){snprintf(why,n,"an archive saved without encryption, which this game can't read (re-save it with OpenIV, or use the original file)");problem=true;}
    else if(header[0]==0x52504637)problem=pg_rpf_version_problem(file,0,0,why,n);
  }
  fclose(file);return problem;
}
// The game's file index for the mod installer (App/ModInstaller.swift): every file inside the archives,
// written by the engine as it opens them (EngineHost.c), with the game files' version on its first line.
const char *pg_game_index_path(void){
  static char path[PATH_MAX];
  if(!path[0])snprintf(path,sizeof path,"%s/game-file-index.txt",[NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject fileSystemRepresentation]);
  return path;
}
const char *pg_game_files_version(void){static char version[128];snprintf(version,sizeof version,"%s",(assetVersion?:@"current").UTF8String);return version;}
// An archive name as the engine reports it, as a game file path ("platform:\dlcPacks\x\dlc.rpf" ->
// "x64/dlcPacks/x/dlc.rpf"); false for archives inside other archives ("dlcMPBeach:/...").
bool pg_mods_archive_path(const char *enginePath,char *out,size_t cap){
  size_t n=0;const char *s=enginePath;
  if(!strncmp(s,"/game/",6))s+=6;
  if(!strncasecmp(s,"platform:",9)){s+=9;if(*s=='/'||*s=='\\')s++;n=(size_t)snprintf(out,cap,"x64/");}
  else if(strchr(s,':')){snprintf(out,cap,"%s",s);return false;}
  for(;*s&&n<cap-1;s++)out[n++]=*s=='\\'?'/':*s;
  out[n]=0;return true;
}
// The Mods folder for the script mod layer (Source/NativeASI.c), as a C path.
const char *pg_mods_folder_path(void){
  static char path[PATH_MAX];
  if(!path[0])snprintf(path,sizeof path,"%s",modsFolder().fileSystemRepresentation);
  return path;
}
// Mods use the PC game's paths (OpenIV): x64e.rpf/levels/..., common.rpf/data/..., update/update.rpf/common/...,
// update/x64/dlcpacks/<pack>/dlc.rpf. The web build's game files have the PC's top-level archives unpacked
// (x64/..., common/...) and keep the packs in x64/dlcPacks, so those paths are translated; names match
// regardless of case (mods write vehicleaihandlinginfo.meta, the game has VehicleaiHandlingInfo.meta).
static bool isGameLocation(NSString *folder){
  NSString *f=folder.lowercaseString;
  return [f isEqualToString:@"x64"]||[f isEqualToString:@"common"]||[f isEqualToString:@"common.rpf"]||[f isEqualToString:@"update"]||[f isEqualToString:@"mods"]||
    [f rangeOfString:@"^x64[a-z]?\\.rpf$" options:NSRegularExpressionSearch].location!=NSNotFound;
}
static NSString *modTranslate(NSString *relative){
  NSString *p=[relative stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
  NSArray *rules=@[@[@"^mods/",@""],@[@"^x64[a-z]?\\.rpf/",@"x64/"],@[@"^common\\.rpf/",@"common/"],@[@"^update/update\\.rpf/",@""],
                   @[@"^update/x64/dlcpacks/",@"x64/dlcPacks/"],@[@"^x64/dlcpacks/",@"x64/dlcPacks/"]];
  for(NSArray *rule in rules){
    NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:rule[0] options:NSRegularExpressionCaseInsensitive error:nil];
    p=[re stringByReplacingMatchesInString:p options:0 range:NSMakeRange(0,p.length) withTemplate:rule[1]];
  }
  return p;
}
// Files inside an archive: each one gets a 512-byte-aligned slot past the archive's real end (the manifest
// size grows to cover them). Files are served whole, as an archive stores them: game resources (RSC7: .yft,
// .ytd, .ydr, ...) keep their 16-byte header, whose flags also go into the archive entry; other files are
// stored unencrypted and uncompressed.
typedef struct { PGModPiece info; char inner[256]; char file[PATH_MAX]; uint64_t skip; int reported; } PGModSlot;
typedef struct { uint32_t id; char path[512]; uint64_t realSize; int count; PGModSlot *slots; } PGModArchive;
static PGModArchive *modArchives; static int modArchiveCount;
static PGModArchive *modArchiveFor(uint32_t id){for(int i=0;i<modArchiveCount;i++)if(modArchives[i].id==id)return &modArchives[i];return NULL;}
int pg_mods_for_archive(const char *enginePath,const PGModPiece **pieces){
  // Engine names: "/game/x64/levels/gta5/vehicles.rpf", "x64/audio/sfx/X.rpf", "platform:\dlcPacks\mpBeach\dlc.rpf".
  if(!modArchiveCount||!enginePath)return 0;
  char path[512];size_t n=0;const char *s=enginePath;
  if(!strncmp(s,"/game/",6))s+=6;
  if(!strncasecmp(s,"platform:",9)){s+=9;if(*s=='/'||*s=='\\')s++;n=(size_t)snprintf(path,sizeof path,"x64/");}
  for(;*s&&n<sizeof path-1;s++)path[n++]=*s=='\\'?'/':*s;
  path[n]=0;
  for(int i=0;i<modArchiveCount;i++)if(!strcasecmp(modArchives[i].path,path)){
    static __thread PGModPiece list[256];int count=modArchives[i].count<256?modArchives[i].count:256;
    for(int k=0;k<count;k++)list[k]=modArchives[i].slots[k].info;
    *pieces=list;return count;
  }
  return 0;
}
static uint64_t align512(uint64_t value){return (value+511)&~(uint64_t)511;}
static NSDictionary *modsBaseManifest;
static NSArray *applyMods(NSArray *files,NSDictionary *manifest){
  modsBaseFiles=files;modsBaseManifest=manifest;modsWantLocal=false;
  modFiles=nil;modsManifest=nil;modArchiveCount=0;   // earlier slots are left allocated: the engine may hold pointers into them
  @synchronized(NSFileManager.class){[modsUsed removeAllObjects];}
  NSString *folder=modsFolder();NSFileManager *fm=NSFileManager.defaultManager;
  [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
  NSString *readme=[folder stringByAppendingPathComponent:@"README.txt"];
  [@"Mods for GTA V on PC work here as downloaded. Put each file at its game path, like OpenIV's mods folder:\n"
    "  x64e.rpf/levels/gta5/vehicles.rpf/adder.yft  (replaces a car)\n"
    "  update/x64/dlcpacks/mycar/dlc.rpf  (an add-on car; added to the game automatically)\n"
    "  common.rpf/data/handling.meta  (replaces a data file)\n"
    "  MyMod.oiv  (an OpenIV package, installed as OpenIV would)\n"
    "  Trainer.asi  (a Script Hook V script; its keys are under Mod keys in the game)\n"
    "Cars, skins and add-on packs need the game files on this iPhone. Mods are read when the game starts.\n"
    "Mods can cause crashes and glitches we can't fix: ask in the Mods topic on Telegram.\n"
    "Guide: https://fivestarport.site/mods/\n" writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:nil];
  NSMutableDictionary *ids=[NSMutableDictionary dictionaryWithCapacity:files.count];
  for(NSUInteger i=0;i<files.count;i++)ids[[files[i][0] lowercaseString]]=@(i);
  NSMutableArray *merged=nil;NSMutableDictionary *mods=[NSMutableDictionary dictionary];
  NSMutableDictionary<NSNumber *,NSMutableArray *> *inside=[NSMutableDictionary dictionary];   // archive id -> @[inner, full]
  NSMutableArray<NSString *> *packs=[NSMutableArray array],*packSources=[NSMutableArray array];
  NSMutableDictionary<NSNumber *,NSMutableArray<NSString *> *> *packFiles=[NSMutableDictionary dictionary];   // size -> pack files added
  NSString *resolvedFolder=folder.stringByResolvingSymlinksInPath;
  // OpenIV packages (NativeOIV.m) become mod files at PC paths; their own files in Mods are left to them.
  bool oivNeedsGame=false;NSArray<NSString *> *oivOwned=nil;
  NSArray<NSArray *> *oivFiles=pg_oiv_expand(folder,^NSString *(NSString *pc){
    NSNumber *game=ids[modTranslate(pc).lowercaseString];
    return game&&localDataRoot?[localDataRoot stringByAppendingPathComponent:files[game.unsignedIntegerValue][0]]:nil;},localDataRoot!=nil,&oivNeedsGame,&oivOwned);
  if(oivNeedsGame)modsWantLocal=true;
  NSMutableArray<NSArray *> *candidates=[NSMutableArray array];   // @[path in Mods or PC path, file, size]
  NSDirectoryEnumerator *walk=[fm enumeratorAtURL:[NSURL fileURLWithPath:folder] includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLFileSizeKey,NSURLIsSymbolicLinkKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
  for(NSURL *url in walk){
    NSNumber *regular,*link,*size;[url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];[url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];[url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if(!regular.boolValue||link.boolValue)continue;
    NSString *full=url.path.stringByResolvingSymlinksInPath;
    if(![full hasPrefix:[resolvedFolder stringByAppendingString:@"/"]])continue;
    NSString *original=[full substringFromIndex:resolvedFolder.length+1];
    if([original isEqualToString:@"README.txt"])continue;
    // One folder per mod (Settings › Mods installs them so): Mods/<mod>/<game path>. A first folder that
    // isn't a game location is the mod's own; ".off" means switched off. Scripts and their settings
    // are for the script layer (NativeASI.c).
    bool owned=false;for(NSString *o in oivOwned)if([o hasSuffix:@"/"]?[original hasPrefix:o]:[original isEqualToString:o])owned=true;
    NSArray<NSString *> *parts=original.pathComponents;
    if([parts.firstObject.lowercaseString hasSuffix:@".off"])continue;
    if([@[@"asi",@"ini",@"log",@"json",@"cfg",@"txt",@"md",@"png",@"jpg"] containsObject:original.pathExtension.lowercaseString])continue;
    if(parts.count>1&&!isGameLocation(parts.firstObject))original=[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(1,parts.count-1)]];
    // Still not under a game location: a script's own files (Menyoo's menyooStuff/...).
    if(original.pathComponents.count>1&&!isGameLocation(original.pathComponents.firstObject))continue;
    if(!owned)[candidates addObject:@[original,full,size?:@0]];
  }
  [candidates addObjectsFromArray:oivFiles];
  NSUInteger modCount=0;
  for(NSArray *candidate in candidates){
    NSString *original=candidate[0],*full=candidate[1];NSNumber *size=candidate[2];
    char why[200];
    if(PGModFileProblem(full.fileSystemRepresentation,why,sizeof why)){
      char line[PATH_MAX+300];snprintf(line,sizeof line,"Mods: %s is %s; ignored, or the game would stop.",original.UTF8String,why);pg_log(line);continue;
    }
    modCount++;
    NSString *relative=modTranslate(original),*lower=relative.lowercaseString;
    // A bare add-on pack: "dlc.rpf" dropped into Mods or a mod folder, or "dlc 2.rpf" when the Files app
    // renamed a second one. It becomes a pack of its own, named after its folder or file (GTA-138).
    if(lower.pathComponents.count==1&&[lower rangeOfString:@"^dlc[ _-]*\\(?[0-9]*\\)?\\.rpf$" options:NSRegularExpressionSearch].location!=NSNotFound){
      NSString *dir=full.stringByDeletingLastPathComponent,*stem=original.stringByDeletingPathExtension;
      NSString *base=[dir isEqualToString:resolvedFolder]?stem:[stem.lowercaseString isEqualToString:@"dlc"]?dir.lastPathComponent:[dir.lastPathComponent stringByAppendingFormat:@"_%@",stem];
      NSString *pack=[[base componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@"_"];
      if(!pack.length)pack=@"addon";
      relative=[NSString stringWithFormat:@"x64/dlcPacks/%@/dlc.rpf",pack];lower=relative.lowercaseString;
    }
    // Two mods with the same pack folder name: the second gets a name of its own instead of replacing the
    // first (players install several add-on cars from mods that reuse one name, GTA-138).
    NSArray *packParts=lower.pathComponents;
    if(packParts.count==4&&[packParts[0] isEqualToString:@"x64"]&&[packParts[1] isEqualToString:@"dlcpacks"]&&[packParts[3] isEqualToString:@"dlc.rpf"]&&
       ids[lower]&&[ids[lower] unsignedIntegerValue]>=files.count){
      NSString *pack=relative.pathComponents[2];NSString *unique=pack;
      for(int n=2;ids[[NSString stringWithFormat:@"x64/dlcpacks/%@/dlc.rpf",unique].lowercaseString];n++)unique=[NSString stringWithFormat:@"%@_%d",pack,n];
      char line[PATH_MAX+160];snprintf(line,sizeof line,"Mods: %s uses the add-on pack name %s again; loaded as %s.",original.UTF8String,pack.UTF8String,unique.UTF8String);pg_log(line);
      relative=[NSString stringWithFormat:@"x64/dlcPacks/%@/dlc.rpf",unique];lower=relative.lowercaseString;
    }
    NSNumber *identity=ids[lower];
    if(!identity){
      // Inside an archive the game has: the outermost "<archive>.rpf/" prefix that is a game file.
      NSRange range=[lower rangeOfString:@".rpf/"];NSNumber *archive=nil;NSString *inner=nil;
      while(range.location!=NSNotFound){
        NSString *prefix=[lower substringToIndex:range.location+4];
        if(ids[prefix]){archive=ids[prefix];inner=[relative substringFromIndex:range.location+5];break;}
        range=[lower rangeOfString:@".rpf/" options:0 range:NSMakeRange(range.location+5,lower.length-range.location-5)];
      }
      if(archive&&[inner.lowercaseString rangeOfString:@".rpf/"].location!=NSNotFound){
        char line[PATH_MAX+120];snprintf(line,sizeof line,"Mods: %s is inside an archive within an archive; not supported yet, ignored.",original.UTF8String);pg_log(line);continue;
      }
      if(archive){
        if(!inside[archive])inside[archive]=[NSMutableArray array];
        [inside[archive] addObject:@[inner,full,size]];continue;
      }
      // A new add-on pack: x64/dlcPacks/<pack>/dlc.rpf, added to the file list and the game's pack list.
      NSArray *parts=lower.pathComponents;
      if(parts.count==4&&[parts[0] isEqualToString:@"x64"]&&[parts[1] isEqualToString:@"dlcpacks"]&&[parts[3] isEqualToString:@"dlc.rpf"]){
        // The same pack twice (one car installed two ways, or a copy left in Mods) loads once: two copies
        // would register its cars twice.
        bool again=false;for(NSString *other in packFiles[size])if([NSFileManager.defaultManager contentsEqualAtPath:other andPath:full]){again=true;break;}
        if(again){char line[PATH_MAX+96];snprintf(line,sizeof line,"Mods: %s is the same add-on pack as one already loaded; loaded once.",original.UTF8String);pg_log(line);continue;}
        if(!packFiles[size])packFiles[size]=[NSMutableArray array];
        [packFiles[size] addObject:full];
        if(!merged)merged=[files mutableCopy];
        NSString *pack=relative.pathComponents[2];
        NSString *path=[NSString stringWithFormat:@"x64/dlcPacks/%@/dlc.rpf",pack];
        mods[@(merged.count)]=full;ids[path.lowercaseString]=@(merged.count);
        [merged addObject:@[path,size,@((uint64_t)NSDate.date.timeIntervalSince1970)]];[packs addObject:pack];[packSources addObject:full];
        char line[PATH_MAX+96];snprintf(line,sizeof line,"Mods: add-on pack %s (%llu bytes).",pack.UTF8String,size.unsignedLongLongValue);pg_log(line);continue;
      }
      char line[PATH_MAX+80];snprintf(line,sizeof line,"Mods: %s is not a game file path; ignored.",original.UTF8String);pg_log(line);continue;
    }
    if(!merged)merged=[files mutableCopy];
    NSUInteger index=identity.unsignedIntegerValue;
    merged[index]=@[files[index][0],size,@((uint64_t)NSDate.date.timeIntervalSince1970)];
    mods[identity]=full;pg_mod_path_used(full.fileSystemRepresentation);
    char line[PATH_MAX+96];snprintf(line,sizeof line,"Mods: %s replaces the game's file (%llu bytes, was %llu).",[files[index][0] UTF8String],size.unsignedLongLongValue,[files[index][1] unsignedLongLongValue]);pg_log(line);
  }
  // Files inside archives: slots past each archive's end.
  if((inside.count||packs.count)&&!localDataRoot){modsWantLocal=true;[inside removeAllObjects];[packs removeAllObjects];}
  else for(NSString *source in packSources)pg_mod_path_used(source.fileSystemRepresentation);
  if(inside.count){
    if(!merged)merged=[files mutableCopy];
    modArchives=calloc(inside.count,sizeof *modArchives);
    for(NSNumber *archive in inside){
      NSUInteger index=archive.unsignedIntegerValue;
      if(mods[archive]){char line[PATH_MAX+96];snprintf(line,sizeof line,"Mods: %s is replaced whole; the files inside it from Mods are ignored.",[files[index][0] UTF8String]);pg_log(line);continue;}
      PGModArchive *a=&modArchives[modArchiveCount];a->id=(uint32_t)index;
      snprintf(a->path,sizeof a->path,"%s",[files[index][0] UTF8String]);a->realSize=[files[index][1] unsignedLongLongValue];
      NSArray *list=inside[archive];a->slots=calloc(list.count,sizeof *a->slots);
      uint64_t cursor=align512(a->realSize);
      for(NSArray *item in list){
        PGModSlot *slot=&a->slots[a->count];uint64_t size=[item[2] unsignedLongLongValue];
        snprintf(slot->inner,sizeof slot->inner,"%s",[item[0] UTF8String]);snprintf(slot->file,sizeof slot->file,"%s",[item[1] fileSystemRepresentation]);
        uint32_t header[4]={0};FILE *file=fopen(slot->file,"rb");size_t got=file?fread(header,4,4,file):0;if(file)fclose(file);
        if(got==4&&header[0]==0x37435352){slot->info.resource=1;slot->skip=0;slot->info.length=size;slot->info.low=header[2];slot->info.high=header[3];}
        else {slot->info.resource=0;slot->skip=0;slot->info.length=size;slot->info.low=(uint32_t)size;slot->info.high=0;}
        if(slot->info.length>=0xFFFFFF&&slot->info.resource){char line[PATH_MAX+96];snprintf(line,sizeof line,"Mods: %s is over 16 MB; not supported inside archives yet, ignored.",[item[1] lastPathComponent].UTF8String);pg_log(line);continue;}
        slot->info.inner=slot->inner;slot->info.offset=cursor;cursor=align512(cursor+slot->info.length);a->count++;pg_mod_path_used(slot->file);
        char line[PATH_MAX+128];snprintf(line,sizeof line,"Mods: %s/%s comes from the Mods folder (%llu bytes%s).",a->path,slot->inner,slot->info.length,slot->info.resource?", game resource":"");pg_log(line);
      }
      if(!a->count)continue;
      merged[index]=@[files[index][0],@(cursor),files[index][2]];
      modArchiveCount++;
    }
  }
  // New add-on packs go into the game's pack list (common/data/dlcList.xml), after the game's own.
  NSNumber *listId=ids[@"common/data/dlclist.xml"];
  if(packs.count&&listId){
    NSString *source=mods[listId]?:(localDataRoot?[localDataRoot stringByAppendingPathComponent:files[listId.unsignedIntegerValue][0]]:nil);
    NSString *text=source?[NSString stringWithContentsOfFile:source encoding:NSUTF8StringEncoding error:nil]:nil;
    NSRange close=text?[text rangeOfString:@"</Paths>" options:NSCaseInsensitiveSearch]:(NSRange){NSNotFound,0};
    if(close.location!=NSNotFound){
      NSMutableString *items=[NSMutableString string];
      for(NSString *pack in packs){
        NSString *item=[NSString stringWithFormat:@"platform:\\dlcPacks\\%@\\",pack];
        if([text rangeOfString:item options:NSCaseInsensitiveSearch].location==NSNotFound)[items appendFormat:@"\t\t<Item>%@</Item>\n",item];
      }
      NSString *updated=[text stringByReplacingCharactersInRange:NSMakeRange(close.location,0) withString:items];
      NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"dlcList-mods.xml"];
      if([updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]){
        mods[listId]=path;NSData *bytes=[updated dataUsingEncoding:NSUTF8StringEncoding];
        merged[listId.unsignedIntegerValue]=@[files[listId.unsignedIntegerValue][0],@(bytes.length),@((uint64_t)NSDate.date.timeIntervalSince1970)];
        char line[96];snprintf(line,sizeof line,"Mods: %lu add-on pack%s added to the game's pack list.",(unsigned long)packs.count,packs.count==1?"":"s");pg_log(line);
      }
    } else pg_log("Mods: the game's pack list couldn't be read; add-on packs won't load.");
  }
  if(!merged)return files;
  modFiles=mods;
  NSMutableDictionary *out=[manifest mutableCopy];out[@"files"]=merged;
  NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:@"manifest-mods.json"];
  if([[NSJSONSerialization dataWithJSONObject:out options:0 error:nil] writeToFile:path atomically:YES])modsManifest=path;
  else {modFiles=nil;modArchiveCount=0;pg_log("Mods: the merged file list couldn't be written; mods are off.");return files;}
  char line[160];snprintf(line,sizeof line,"Mods active: %lu mod file%s (%lu replaced, %d archive%s changed, %lu add-on pack%s).",(unsigned long)modCount,modCount==1?"":"s",
    (unsigned long)mods.count,modArchiveCount,modArchiveCount==1?"":"s",(unsigned long)packs.count,packs.count==1?"":"s");pg_log(line);
  return merged;
}
// Reads past a changed archive's real end come from the mod files in its slots.
static int64_t readModArchive(PGModArchive *a,NSString *realFile,uint64_t offset,uint8_t *destination,uint32_t length){
  uint64_t done=0;
  static _Atomic int pastEnd;
  if(offset+length>a->realSize&&getenv("PG_TEST_MODS")&&atomic_fetch_add(&pastEnd,1)<20){char line[300];snprintf(line,sizeof line,"TEST: read past the end of %s: offset %llu, %u bytes (real size %llu).",a->path,offset,length,a->realSize);pg_log(line);}
  if(offset<a->realSize){
    uint32_t part=(uint32_t)MIN((uint64_t)length,a->realSize-offset);
    int descriptor=open(realFile.fileSystemRepresentation,O_RDONLY);if(descriptor<0)return -1;
    while(done<part){ssize_t n=pread(descriptor,destination+done,part-done,(off_t)(offset+done));if(n<0&&errno==EINTR)continue;if(n<=0)break;done+=(uint64_t)n;}
    close(descriptor);if(done<part)return (int64_t)done;
  }
  while(done<length){
    uint64_t at=offset+done;PGModSlot *slot=NULL;
    for(int i=0;i<a->count;i++)if(at>=a->slots[i].info.offset&&at<a->slots[i].info.offset+a->slots[i].info.length){slot=&a->slots[i];break;}
    if(!slot){uint64_t next=UINT64_MAX;for(int i=0;i<a->count;i++)if(a->slots[i].info.offset>at&&a->slots[i].info.offset<next)next=a->slots[i].info.offset;
      uint64_t gap=MIN((uint64_t)(length-done),next==UINT64_MAX?(uint64_t)(length-done):next-at);memset(destination+done,0,gap);done+=gap;continue;}
    uint64_t within=at-slot->info.offset,part=MIN((uint64_t)(length-done),slot->info.length-within);
    if(!slot->reported&&getenv("PG_TEST_MODS")){slot->reported=1;char line[400];snprintf(line,sizeof line,"TEST: first read of mod slot %s/%s at %llu (+%llu, %u bytes).",a->path,slot->inner,offset,within,length);pg_log(line);}
    int descriptor=open(slot->file,O_RDONLY);if(descriptor<0){char line[PATH_MAX+48];snprintf(line,sizeof line,"Mods: %s could not be read.",slot->file);pg_log(line);return -1;}
    uint64_t got=0;while(got<part){ssize_t n=pread(descriptor,destination+done+got,part-got,(off_t)(slot->skip+within+got));if(n<0&&errno==EINTR)continue;if(n<=0)break;got+=(uint64_t)n;}
    close(descriptor);done+=got;if(got<part)break;
  }
  return (int64_t)done;
}

static _Atomic bool assetsConfigured;
static void PGReapplyMods(void){
  @autoreleasepool {
    NSArray *files=applyMods(modsBaseFiles,modsBaseManifest);
    NSMutableArray *locks=[assetLocks mutableCopy];
    while(locks.count<files.count)[locks addObject:[PGAssetCondition new]];
    assetLocks=locks;assetFiles=files;
  }
}
void pg_assets_configure(const char *manifest,const char *root) {
  // The Settings preloader may configure the same cache before Play; the
  // engine's later call then reuses it (same manifest and root).
  if(atomic_exchange(&assetsConfigured,true))return;
  @autoreleasepool {
    NSData *data=[NSData dataWithContentsOfFile:@(manifest)];
    NSDictionary *parsed=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
#if TARGET_OS_SIMULATOR
    // Simulator profiling: PG_LOCAL_MIRROR (folder with data/) reads the Mac's copy directly.
    assetStreamSimulation=[NSProcessInfo.processInfo.arguments containsObject:@"--stream-assets"];
    const char *mirror=getenv("PG_LOCAL_MIRROR");
    if(!localDataRoot&&!assetStreamSimulation&&mirror)localDataRoot=[[NSString stringWithUTF8String:mirror] stringByAppendingPathComponent:@"data"];
#endif
    assetFiles=applyMods(parsed[@"files"],parsed);
    assetVersion=parsed[@"version"];
    NSMutableArray *locks=[NSMutableArray arrayWithCapacity:assetFiles.count];
    for(NSUInteger i=0;i<assetFiles.count;i++)[locks addObject:[PGAssetCondition new]];
    assetLocks=locks;
    cacheRoot=[[@(root) stringByDeletingLastPathComponent] stringByAppendingPathComponent:[@"AssetCache-" stringByAppendingString:parsed[@"version"]?:@"current"]];
    assetConcurrentFills=![NSProcessInfo.processInfo.arguments containsObject:@"--serialized-asset-fills"];
    assetQueuedHints=![NSProcessInfo.processInfo.arguments containsObject:@"--reference-asset-hints"];
    assetBalancedQOS=[NSProcessInfo.processInfo.arguments containsObject:@"--balanced-asset-qos"];
#if TARGET_OS_SIMULATOR
    assetStreamSimulation=[NSProcessInfo.processInfo.arguments containsObject:@"--stream-assets"];
    const char *tag=getenv("PG_ASSET_CACHE_TAG");
    if(assetStreamSimulation&&tag&&*tag){NSString *name=@(tag);NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
      if(name.length<=64&&[name rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound)cacheRoot=[cacheRoot stringByAppendingFormat:@"-%@",name];}
    const char *latency=getenv("PG_ASSET_LATENCY_MS");if(assetStreamSimulation&&latency)assetSimulatedLatencyMS=(unsigned)MIN(2000,MAX(0,atoi(latency)));
    if(assetStreamSimulation){char mode[160];snprintf(mode,sizeof mode,"Simulator asset streaming enabled: %u ms injected latency, concurrent fills %u.",assetSimulatedLatencyMS,assetConcurrentFills);pg_log(mode);}
#endif
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheRoot withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSURL fileURLWithPath:cacheRoot] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    packedRoot=[cacheRoot stringByAppendingPathComponent:@"Packed-v1"];
    [[NSFileManager defaultManager] createDirectoryAtPath:packedRoot withIntermediateDirectories:YES attributes:nil error:nil];
    const char *trace=getenv("PG_NATIVE_ASSET_TRACE");
    if(trace&&atoi(trace)){
      NSString *tracePath=[[@(root) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"native-asset-ranges.csv"];
      assetTraceFD=open(tracePath.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC|O_APPEND,0600);
      if(assetTraceFD>=0)pg_log("Recording native startup asset ranges.");
    }
    const char *timing=getenv("PG_ASSET_IO_TRACE");
    if(timing&&atoi(timing)){
      NSString *timingPath=[[@(root) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"native-asset-timings.csv"];
      assetTimingFD=open(timingPath.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC|O_APPEND,0600);
      if(assetTimingFD>=0){const char *header="start_ms,end_ms,id,offset,length,result,source,prefetch,network_ms,lock_ms,network_bytes\n";write(assetTimingFD,header,strlen(header));}
    }
    NSURLSessionConfiguration *config=[NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.HTTPMaximumConnectionsPerHost=assetQueuedHints?16:8;config.timeoutIntervalForRequest=25;config.timeoutIntervalForResource=60;
    assetSession=[NSURLSession sessionWithConfiguration:config];
    atomic_store(&nextReport,25*1024*1024);
    prefetchQueue=dispatch_queue_create("playgta5.assets.prefetch",assetBalancedQOS?dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT,QOS_CLASS_UTILITY,0):DISPATCH_QUEUE_CONCURRENT);
    speculativeQueue=assetBalancedQOS?dispatch_queue_create("playgta5.assets.speculation",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT,QOS_CLASS_BACKGROUND,0)):prefetchQueue;
    pg_log(assetBalancedQOS?"Native background asset priorities: utility hints, background speculation (opt-in).":"Native background asset priorities: original.");
    if(!localDataRoot)[[assetSession dataTaskWithURL:[NSURL URLWithString:[assetServer stringByAppendingString:@"/data/manifest.json"]] completionHandler:^(NSData *body,NSURLResponse *response,NSError *error){
      if(error){NSString *message=[@"Asset server connection failed: " stringByAppendingString:error.localizedDescription];pg_log(message.UTF8String);}
      else if([(NSHTTPURLResponse *)response statusCode]==200){pg_log("Connected to the asset server.");}
      else {NSString *message=[NSString stringWithFormat:@"Asset server probe HTTP %ld, URL %@, server %@",(long)[(NSHTTPURLResponse *)response statusCode],response.URL,[(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Server"]];pg_log(message.UTF8String);}
    }] resume];
  }
}
static NSData *fetchRangeImpl(NSString *path,uint64_t offset,uint64_t length,uint64_t *actualSize) {
  NSString *escaped=[path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
  NSURL *url=[NSURL URLWithString:[[assetServer stringByAppendingString:@"/data/"] stringByAppendingString:escaped]];
  NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];
  [request setValue:[NSString stringWithFormat:@"bytes=%llu-%llu",offset,offset+length-1] forHTTPHeaderField:@"Range"];
  dispatch_semaphore_t done=dispatch_semaphore_create(0);
  __block NSData *received=nil;__block NSHTTPURLResponse *reply=nil;__block NSError *failure=nil;
  NSURLSessionDataTask *task=[assetSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){received=data;reply=(NSHTTPURLResponse *)response;failure=error;dispatch_semaphore_signal(done);}];
  task.priority=assetSpeculativeRead?NSURLSessionTaskPriorityLow:assetPrefetchRead?NSURLSessionTaskPriorityDefault:NSURLSessionTaskPriorityHigh;
  if(assetSimulatedLatencyMS)usleep(assetSimulatedLatencyMS*1000);
  [task resume];dispatch_semaphore_wait(done,DISPATCH_TIME_FOREVER);
  if(failure){pg_log(failure.localizedDescription.UTF8String);return nil;}
  NSString *range=[reply valueForHTTPHeaderField:@"Content-Range"];
  NSString *total=[[range componentsSeparatedByString:@"/"] lastObject];
  if(total.length&&![total isEqualToString:@"*"])*actualSize=strtoull(total.UTF8String,NULL,10);
  if(reply.statusCode==416)return [NSData data];
  if(reply.statusCode!=206){NSString *message=[NSString stringWithFormat:@"Asset range HTTP %ld, URL %@, server %@",(long)reply.statusCode,reply.URL,[reply valueForHTTPHeaderField:@"Server"]];pg_log(message.UTF8String);return nil;}
  uint64_t sum=atomic_fetch_add(&fetchedBytes,received.length)+received.length;
  assetReadNetworkBytes+=received.length;assetReadSource=3;
  uint64_t report=atomic_load(&nextReport);
  if(sum>=report&&atomic_compare_exchange_strong(&nextReport,&report,report+25*1024*1024)){
    char line[128];snprintf(line,sizeof line,"Native asset cache: %.1f MB downloaded.",sum/1048576.0);pg_log(line);
  }
  return received;
}
static NSData *fetchRange(NSString *path,uint64_t offset,uint64_t length,uint64_t *actualSize){
  double start=assetNowMS();@try{return fetchRangeImpl(path,offset,length,actualSize);}@finally{assetReadNetworkMS+=assetNowMS()-start;}
}
static int64_t readAssetLegacyLocked(uint32_t id,uint64_t offset,uint8_t *destination,uint32_t length) {
  if(id>=assetFiles.count)return -1;
  if(!length)return 0;
  NSArray *entry=assetFiles[id];NSString *path=entry[0];uint64_t size=[entry[1] unsignedLongLongValue];
  if(offset>=size)return 0;length=(uint32_t)MIN((uint64_t)length,size-offset);
#if TARGET_OS_SIMULATOR
  // Profiling uses the identical mirror directly, without a second asset cache.
#endif
  NSString *directory=[cacheRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%u",id]];
  [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
  uint64_t first=offset/4096,last=(offset+length-1)/4096;uint64_t copied=0;
  for(uint64_t block=first;block<=last;block++) {
    NSString *file=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%llu",block]];
    NSData *bytes=[NSData dataWithContentsOfFile:file];
    if(!bytes) {
      uint64_t runEnd=block;
      while(runEnd<last&&runEnd-block<255) {NSString *next=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%llu",runEnd+1]];if([[NSFileManager defaultManager] fileExistsAtPath:next])break;runEnd++;}
      uint64_t start=block*4096;uint64_t wanted=MIN((runEnd+1)*4096,size)-start;
      NSData *run=fetchRange(path,start,wanted,&size);if(!run)return -1;
      for(uint64_t b=block;b<=runEnd;b++) {
        uint64_t at=(b-block)*4096;if(at>=run.length)break;
        NSData *part=[run subdataWithRange:NSMakeRange(at,MIN((uint64_t)4096,run.length-at))];
        NSString *name=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%llu",b]];
        [part writeToFile:name options:NSDataWritingAtomic error:nil];
        if(b==block)bytes=part;
      }
      if(!bytes)return copied;
    }
    uint64_t within=offset>block*4096?offset-block*4096:0;
    if(within>=bytes.length)break;
    uint64_t n=MIN((uint64_t)length-copied,bytes.length-within);
    memcpy(destination+copied,(const uint8_t *)bytes.bytes+within,n);copied+=n;
    if(bytes.length<4096)break;
  }
  return copied;
}
static int64_t readAssetPackedLocked(uint32_t id,uint64_t offset,uint8_t *destination,uint32_t length) {
  if(id>=assetFiles.count)return -1;if(!length)return 0;
  NSArray *entry=assetFiles[id];NSString *path=entry[0];uint64_t size=[entry[1] unsignedLongLongValue];
  if(offset>=size)return 0;length=(uint32_t)MIN((uint64_t)length,size-offset);
#if TARGET_OS_SIMULATOR
  // Simulator graphics timing retains the direct mirror path. Cache mechanics
  // are checked independently against exact ranges and restart persistence.
  if(!assetStreamSimulation)return readAssetLegacyLocked(id,offset,destination,length);
#endif
  NSString *base=[packedRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%u",id]];
  PGPackedAssetCache cache;
  if(!pg_packed_open(&cache,[base stringByAppendingString:@".data"].fileSystemRepresentation,[base stringByAppendingString:@".map"].fileSystemRepresentation,size))return readAssetLegacyLocked(id,offset,destination,length);
  @try {
    uint64_t first=offset/4096,last=(offset+length-1)/4096;
    NSString *legacy=[cacheRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%u",id]];
    BOOL hasLegacy=[[NSFileManager defaultManager] fileExistsAtPath:legacy];
    PGAssetCondition *condition=assetLocks[id];
    for(uint64_t block=first;block<=last;block++){
      while(assetBlockInFlight(condition,block)&&!pg_packed_has(&cache,block)){double start=assetNowMS();[condition wait];assetReadLockMS+=assetNowMS()-start;}
      if(pg_packed_has(&cache,block))continue;
      uint64_t end=block,start=block*4096;
      NSData *old=hasLegacy?[NSData dataWithContentsOfFile:[legacy stringByAppendingPathComponent:[NSString stringWithFormat:@"%llu",block]]]:nil;
      NSData *run=nil;
      if(old){
        NSMutableData *migrated=[old mutableCopy];
        while(end<last&&end-block<255&&!pg_packed_has(&cache,end+1)&&!assetBlockInFlight(condition,end+1)){
          NSData *next=[NSData dataWithContentsOfFile:[legacy stringByAppendingPathComponent:[NSString stringWithFormat:@"%llu",end+1]]];
          if(!next)break;[migrated appendData:next];end++;
        }
        run=migrated;
      }else{
        while(end<last&&end-block<255&&!pg_packed_has(&cache,end+1)&&!assetBlockInFlight(condition,end+1)){
          if(hasLegacy&&[[NSFileManager defaultManager] fileExistsAtPath:[legacy stringByAppendingPathComponent:[NSString stringWithFormat:@"%llu",end+1]]])break;
          end++;
        }
        uint64_t wanted=MIN((end+1)*4096,size)-start,actualSize=size;
        NSArray<NSNumber *> *flight=@[@(block),@(end+1)];
        if(assetConcurrentFills){[condition.flights addObject:flight];[condition unlock];}
        @try {
#ifdef PG_ASSET_TEST_HOOK
          if(assetFillTestHook)assetFillTestHook(id,start);
#endif
          run=fetchRange(path,start,wanted,&actualSize);
        } @finally {
          if(assetConcurrentFills){[condition lock];[condition.flights removeObjectIdenticalTo:flight];[condition broadcast];}
        }
        if(actualSize!=size){pg_log("Asset range size disagrees with immutable manifest.");assetSizeMismatch=true;return -1;}
      }
      uint64_t wanted=MIN((end+1)*4096,size)-start;
      if(!run||run.length!=wanted)return -1;
      if(!pg_packed_store(&cache,start,run.bytes,run.length)){
        pg_log("Packed asset cache write failed; using the original cache for this read.");
        return readAssetLegacyLocked(id,offset,destination,length);
      }
      block=end;
    }
    return pg_packed_read(&cache,offset,destination,length);
  } @finally {pg_packed_close(&cache);}
}
// Cached reads bypass fills. Missing ranges reserve blocks while downloading
// outside the archive lock; overlapping reads wait for that one shared fill.
static int64_t readLocalAsset(uint32_t id,uint64_t offset,uint8_t *destination,uint32_t length){
  NSArray *entry=assetFiles[id];uint64_t size=[entry[1] unsignedLongLongValue];
  if(!length||offset>=size)return 0;
  length=(uint32_t)MIN((uint64_t)length,size-offset);
  NSString *file=modFiles[@(id)]?:[localDataRoot stringByAppendingPathComponent:entry[0]];
  PGModArchive *changed=modArchiveCount?modArchiveFor(id):NULL;
  if(changed){int64_t got=readModArchive(changed,file,offset,destination,length);if(got>=0)assetReadSource=4;return got;}
  int descriptor=open(file.fileSystemRepresentation,O_RDONLY);
  if(descriptor<0){NSString *message=[@"Game file missing from your folder: " stringByAppendingString:entry[0]];pg_log(message.UTF8String);return -1;}
  uint64_t done=0;
  while(done<length){
    ssize_t n=pread(descriptor,destination+done,length-done,(off_t)(offset+done));
    if(n<0&&errno==EINTR)continue;
    if(n<0){
      int error=errno;close(descriptor);
      NSString *message=[NSString stringWithFormat:@"Game file could not be read: %@ (error %d, %s)",entry[0],error,strerror(error)];
      pg_log(message.UTF8String);return -1;
    }
    if(n==0)break;
    done+=(uint64_t)n;
  }
  close(descriptor);assetReadSource=4;
  return (int64_t)done;
}
static int64_t readAssetImpl(uint32_t id,uint64_t offset,uint8_t *destination,uint32_t length) {
  if(id>=assetFiles.count)return -1;
  PGMeshTouch(destination,length);		// pread into a released mesh page would fail (GTA-152)
  if(localDataRoot||modFiles[@(id)])return readLocalAsset(id,offset,destination,length);
  if(assetTraceFD>=0&&length){char record[96];int n=snprintf(record,sizeof record,"%u,%llu,%u\n",id,offset,length);if(n>0&&n<sizeof record)write(assetTraceFD,record,(size_t)n);}
#if TARGET_OS_SIMULATOR
  if(assetStreamSimulation){
#endif
  uint64_t size=[assetFiles[id][1] unsignedLongLongValue];
  if(!length||offset>=size)return 0;
  length=(uint32_t)MIN((uint64_t)length,size-offset);
  NSString *base=[packedRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%u",id]];
  int64_t cached=pg_packed_read_existing([base stringByAppendingString:@".data"].fileSystemRepresentation,[base stringByAppendingString:@".map"].fileSystemRepresentation,size,offset,destination,length);
  if(cached>=0){assetReadSource=1;return cached;}
#if TARGET_OS_SIMULATOR
  }
#endif
  PGAssetCondition *lock=assetLocks[id];double start=assetNowMS();[lock lock];assetReadLockMS+=assetNowMS()-start;
  @try {return readAssetPackedLocked(id,offset,destination,length);}
  @finally {[lock unlock];}
}
// Health counters for the periodic log line (Settings > Share log).
static _Atomic uint64_t healthReads,healthReadBytes,healthReadErrors,healthShortReads,healthSlowReads,healthReadMicros;
void PGAssetHealth(uint64_t out[6]){out[0]=healthReads;out[1]=healthReadBytes;out[2]=healthReadErrors;out[3]=healthShortReads;out[4]=healthSlowReads;out[5]=healthReadMicros;}
// Sandbox on the GTA VI test map: env_test.meta lists only the testbed script archive (about 20
// test scripts), so the startup script finds no main, phone or cheat app there. Reads of that
// file get the GTA V map's script archive plus the cheat-app overlay instead. The engine knows
// every file's size from the manifest, so the rewrite keeps the size: indentation and carriage
// returns are dropped and spaces pad the end. A file that doesn't match is left alone.
static NSData *envTestMeta;
static NSData *envTestMetaRewrite(NSData *original){
  NSString *text=[[NSString alloc] initWithData:original encoding:NSUTF8StringEncoding];
  NSString *testbed=@"\t\t<Item>\r\n\t\t\t<filename>PLATFORM:/LEVELS/TESTBED/SCRIPT/SCRIPT.RPF</filename>\r\n\t\t\t<fileType>RPF_FILE</fileType>\r\n\t\t</Item>\r\n";
  if(!text||[text componentsSeparatedByString:testbed].count!=2)return nil;
  NSString *gta5=@"<Item><filename>platform:/levels/gta5/script/script.rpf</filename><fileType>RPF_FILE</fileType></Item>\n"
    @"<Item><filename>platform:/levels/gta5/script/script_wasm.rpf</filename><fileType>RPF_FILE</fileType><overlay value=\"true\"/></Item>\n";
  text=[text stringByReplacingOccurrencesOfString:testbed withString:gta5];
  text=[[text stringByReplacingOccurrencesOfString:@"\t" withString:@""] stringByReplacingOccurrencesOfString:@"\r" withString:@""];
  NSMutableData *out=[[text dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  if(out.length>original.length)return nil;
  NSMutableData *pad=[NSMutableData dataWithLength:original.length-out.length];memset(pad.mutableBytes,' ',pad.length);
  [out appendData:pad];return out;
}
static void envTestMetaOverlay(uint32_t id,uint64_t offset,uint8_t *destination,int64_t count){
  if(count<=0||![assetFiles[id][0] isEqualToString:@"common/data/levels/env_test/env_test.meta"])return;
  @synchronized([NSNull null]) {
    if(!envTestMeta){
      uint64_t size=[assetFiles[id][1] unsignedLongLongValue];
      NSMutableData *original=[NSMutableData dataWithLength:(NSUInteger)size];
      NSData *rewritten=readAssetImpl(id,0,original.mutableBytes,(uint32_t)size)==(int64_t)size?envTestMetaRewrite(original):nil;
      envTestMeta=rewritten?:[NSData data];
      pg_log(rewritten?"GTA VI test map: using the GTA V map's scripts (phone, cheats, free roam).":"GTA VI test map: its level file is not the expected one; the test scripts stay.");
    }
    if(envTestMeta.length&&offset<envTestMeta.length)
      memcpy(destination,(const uint8_t *)envTestMeta.bytes+offset,(size_t)MIN((uint64_t)count,envTestMeta.length-offset));
  }
}
// The mission passed screen asks for INPUT_FRONTEND_ENDSCREEN_ACCEPT and _EXPAND, which no control file
// maps (on any device), so its prompts read "???" and Continue can't be pressed (GTA-48). The control
// files get those mappings as the game reads them: the XML is compacted (whitespace between tags) to
// make room and padded back to its size, so file sizes stay as the manifest says.
// The radio wheel's direction (INPUT_RADIO_WHEEL_LR/_UD) has no mouse mapping in this game's fixed.meta, so with a
// mouse it didn't follow while the weapon wheel did (GTA-9, Kevin on the Mac): it gets the weapon wheel's mouse source.
static NSDictionary<NSString *,NSArray<NSArray<NSString *> *> *> *controlAdditions(void){
  static NSDictionary *table;static dispatch_once_t once;
  dispatch_once(&once,^{table=@{
    @"common/data/control/standard_accept_cancel.meta":@[@[@"INPUT_FRONTEND_ENDSCREEN_ACCEPT",@"IOMS_PAD_DIGITALBUTTON",@"RDOWN"],@[@"INPUT_FRONTEND_ENDSCREEN_EXPAND",@"IOMS_PAD_DIGITALBUTTON",@"RLEFT"]],
    @"common/data/control/alternate_accept_cancel.meta":@[@[@"INPUT_FRONTEND_ENDSCREEN_ACCEPT",@"IOMS_PAD_DIGITALBUTTON",@"RRIGHT"],@[@"INPUT_FRONTEND_ENDSCREEN_EXPAND",@"IOMS_PAD_DIGITALBUTTON",@"RLEFT"]],
    @"x64/data/control/fixed.meta":@[@[@"INPUT_FRONTEND_ENDSCREEN_ACCEPT",@"IOMS_KEYBOARD",@"KEY_RETURN"],@[@"INPUT_FRONTEND_ENDSCREEN_EXPAND",@"IOMS_KEYBOARD",@"KEY_SPACE"],
      @[@"INPUT_RADIO_WHEEL_LR",@"IOMS_MOUSE_NORMALIZED",@"IOM_AXIS_X"],@[@"INPUT_RADIO_WHEEL_UD",@"IOMS_MOUSE_NORMALIZED",@"IOM_AXIS_Y"]]};});
  return table;
}
NSData *PGControlMetaRewrite(NSData *original,NSArray<NSArray<NSString *> *> *additions){
  NSString *text=[[NSString alloc] initWithData:original encoding:NSUTF8StringEncoding];
  if(!text||[text containsString:additions[0][0]])return nil;
  NSRegularExpression *gaps=[NSRegularExpression regularExpressionWithPattern:@">\\s+<" options:0 error:nil];
  NSMutableString *compact=[[gaps stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@"><"] mutableCopy];
  NSRange end=[compact rangeOfString:@"</Mappings>" options:NSBackwardsSearch];
  if(end.location==NSNotFound)return nil;
  NSMutableString *items=[NSMutableString string];
  for(NSArray<NSString *> *a in additions)[items appendFormat:@"<Item><Input>%@</Input><Source>%@</Source><Parameters><Item>%@</Item></Parameters></Item>",a[0],a[1],a[2]];
  [compact insertString:items atIndex:end.location];
  NSMutableData *out=[[compact dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  if(out.length>original.length)return nil;
  while(out.length<original.length)[out appendBytes:" " length:1];
  return out;
}
static NSMutableDictionary<NSNumber *,NSData *> *controlMetas;
static void controlMetaOverlay(uint32_t id,uint64_t offset,uint8_t *destination,int64_t count){
  if(count<=0)return;
  NSArray *additions=controlAdditions()[assetFiles[id][0]];
  if(!additions)return;
  NSData *rewritten;
  @synchronized(controlAdditions()) {
    if(!controlMetas)controlMetas=[NSMutableDictionary dictionary];
    rewritten=controlMetas[@(id)];
    if(!rewritten){
      uint64_t size=[assetFiles[id][1] unsignedLongLongValue];
      NSMutableData *original=[NSMutableData dataWithLength:(NSUInteger)size];
      rewritten=readAssetImpl(id,0,original.mutableBytes,(uint32_t)size)==(int64_t)size?PGControlMetaRewrite(original,additions):nil;
      controlMetas[@(id)]=rewritten?:[NSData data];
      char line[200];snprintf(line,sizeof line,"Controls: %s %s.",[assetFiles[id][0] UTF8String],rewritten?"gets its missing mappings (mission passed screen, radio wheel mouse)":"has no room or is not the expected file; unchanged");pg_log(line);
      rewritten=controlMetas[@(id)];
    }
  }
  if(rewritten.length&&offset<rewritten.length)
    memcpy(destination,(const uint8_t *)rewritten.bytes+offset,(size_t)MIN((uint64_t)count,rewritten.length-offset));
}
// Pools the game stops on when they fill ("<Pool> Pool Full, Size == N"): PC players raise them in gameconfig.xml, and
// the game's own file gets that as it's read. The XML is compacted (whitespace between tags) to make room and padded
// back to its size, as for the control files.
// - HandlingData (CHandlingObject): add-on cars bring their own handling entries; 560 filled with a few (10 player
//   logs on v1.4.1), and 1500 with 87 mod files (log 957). 3000 entries of 816 bytes are about 2.4 MB.
// - ScriptStore: players' own game files differ; in some it is 900, and the game stopped while registering script.rpf
//   at slot 899 (logs 619, 716, 721, 882). The files this was tested with say 1400 and register about 1030.
// - CScenarioInfo: 220, filled by add-on packs with scenarios (log 948).
// - phInstGta: physics instances; the pc section's 8192 filled with no mods at all, driving in a mission (log 895).
static const struct { const char *pool, *what; long minimum; } pgGamePools[] = {
  {"HandlingData", "vehicle handling entries", 3000}, {"ScriptStore", "scripts", 1500},
  {"CScenarioInfo", "scenario types", 400}, {"phInstGta", "physics instances", 12288},
};
static NSData *gameConfig;
NSData *PGGameConfigRewrite(NSData *original,NSString *pool,long minimum,long *was){
  NSString *text=[[NSString alloc] initWithData:original encoding:NSUTF8StringEncoding];
  if(!text)return nil;
  // Every entry: the file has an "Any" platform section and per-platform overrides (the pc one is what this game
  // uses: phInstGta is 2214 under Any and 8192 under pc), so each entry below the minimum is raised. `was` is the
  // largest size found.
  NSRegularExpression *entry=[NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(<PoolName>%@</PoolName>\\s*<PoolSize value=\")(\\d+)(\"\\s*/>)",pool] options:0 error:nil];
  NSArray<NSTextCheckingResult *> *matches=[entry matchesInString:text options:0 range:NSMakeRange(0,text.length)];
  if(!matches.count)return nil;
  NSMutableString *changed=[text mutableCopy];bool raised=false;long largest=0;
  for(NSTextCheckingResult *match in matches.reverseObjectEnumerator){
    long current=[[text substringWithRange:[match rangeAtIndex:2]] integerValue];largest=MAX(largest,current);
    if(current>=minimum)continue;
    [changed replaceCharactersInRange:[match rangeAtIndex:2] withString:[NSString stringWithFormat:@"%ld",minimum]];raised=true;
  }
  if(was)*was=largest;
  if(!raised)return nil;
  NSRegularExpression *gaps=[NSRegularExpression regularExpressionWithPattern:@">\\s+<" options:0 error:nil];
  // Trailing padding from an earlier rewrite counts as room too.
  NSString *compact=[[gaps stringByReplacingMatchesInString:changed options:0 range:NSMakeRange(0,changed.length) withTemplate:@"><"]
                     stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSMutableData *out=[[compact dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  if(out.length>original.length)return nil;
  while(out.length<original.length)[out appendBytes:" " length:1];
  return out;
}
static void gameConfigOverlay(uint32_t id,uint64_t offset,uint8_t *destination,int64_t count){
  if(count<=0||![assetFiles[id][0] isEqualToString:@"common/data/gameconfig.xml"])return;
  @synchronized([NSNumber class]) {
    if(!gameConfig){
      uint64_t size=[assetFiles[id][1] unsignedLongLongValue];
      NSMutableData *original=[NSMutableData dataWithLength:(NSUInteger)size];
      NSData *current=readAssetImpl(id,0,original.mutableBytes,(uint32_t)size)==(int64_t)size?original:nil;bool changed=false;
#if TARGET_OS_SIMULATOR
      // Test (PG_TEST_DUMP_GAMECONFIG=path): the game's own gameconfig.xml, as read, for checking pool entries.
      const char *dump=getenv("PG_TEST_DUMP_GAMECONFIG");if(dump&&current)[current writeToFile:@(dump) atomically:YES];
#endif
      for(size_t i=0;current&&i<sizeof pgGamePools/sizeof *pgGamePools;i++){
        long was=-1;NSData *rewritten=PGGameConfigRewrite(current,@(pgGamePools[i].pool),pgGamePools[i].minimum,&was);
        char line[160];
        if(rewritten)snprintf(line,sizeof line,"Game config: room for %ld %s (was %ld).",pgGamePools[i].minimum,pgGamePools[i].what,was);
        else if(was<0)snprintf(line,sizeof line,"Game config: no %s pool in the file; unchanged.",pgGamePools[i].pool);
        else snprintf(line,sizeof line,"Game config: %s %ld, unchanged.",pgGamePools[i].what,was);
        pg_log(line);
        if(rewritten){current=rewritten;changed=true;}
      }
      gameConfig=changed?current:[NSData data];
    }
    if(gameConfig.length&&offset<gameConfig.length)
      memcpy(destination,(const uint8_t *)gameConfig.bytes+offset,(size_t)MIN((uint64_t)count,gameConfig.length-offset));
  }
}
// Minimap place and size (GTA-131): the game reads them from common/data/ui/frontend.xml, <minimap><data name=
// "minimap" alignX="L" alignY="B" posX=... posY=... sizeX=... sizeY=.../> with its mask and blur, and the same
// three for the expanded map ("bigmap"). The app moves and scales each set as the file is read, keeping the
// pieces' places relative to each other: offsets in the game's HUD units (fractions of the screen; with
// alignY="B" a negative posY is higher up) and a size factor around the minimap's own corner. The expanded
// map moves with it but stays on screen. A Mods replacement of the file is moved too. Same compact-and-pad as gameconfig.
static double minimapDX, minimapDY, minimapScale = 1, subtitleRaise;
// Help messages (the box with "Press ... to ..."): HUD_HELP_TEXT, top left of the HUD at 0, 0 (0.203 × 0.389). With the
// minimap at the top left it covers the map, so the app can put it elsewhere: its top-left corner in HUD units
// (fractions of the HUD area, from its top left) and a size factor (the text grows with it).
static double helpX, helpY, helpScale = 1;
static bool helpMoved;
static NSData *frontendLayout;
// Subtitles above the home bar (GTA-95): HUD_SUBTITLE_TEXT sits at the bottom edge (alignY="B" posY=".0051"), where
// the home bar covers it; it moves up by this fraction of the screen height. (The game's safe zone doesn't move it.)
void PGSetSubtitleRaise(double raise) { subtitleRaise = raise >= 0 && raise < 0.3 ? raise : 0; }
void PGSetMinimapLayout(double dx, double dy, double scale) {
  minimapDX = dx; minimapDY = dy; minimapScale = scale > 0.4 && scale < 2.5 ? scale : 1;
}
void PGSetHelpTextLayout(double x, double y, double scale) {
  helpX = x >= -0.1 && x <= 1 ? x : 0; helpY = y >= -0.1 && y <= 1 ? y : 0; helpScale = scale > 0.4 && scale < 2.5 ? scale : 1;
  helpMoved = helpX != 0 || helpY != 0 || helpScale != 1;
}
NSData *PGFrontendRewrite(NSData *original, double dx, double dy, double scale) {
  NSString *text = [[NSString alloc] initWithData:original encoding:NSUTF8StringEncoding];
  if (!text) return nil;
  NSRegularExpression *entry = [NSRegularExpression regularExpressionWithPattern:
    @"(<data name=\"(minimap|bigmap)(_mask|_blur)?\"[^>]*?posX=\")([-\\d.]+)(\"[^>]*?posY=\")([-\\d.]+)(\"[^>]*?sizeX=\")([-\\d.]+)(\"[^>]*?sizeY=\")([-\\d.]+)(\")"
    options:0 error:nil];
  NSArray<NSTextCheckingResult *> *matches = [entry matchesInString:text options:0 range:NSMakeRange(0, text.length)];
  // Each set scales around its main piece's corner (posX, posY of "minimap" / "bigmap").
  double cornerX[2] = {0, 0}, cornerY[2] = {0, 0}, top[2] = {0, 0}; bool found[2] = {false, false};
  for (NSTextCheckingResult *m in matches) {
    int set = [[text substringWithRange:[m rangeAtIndex:2]] isEqualToString:@"bigmap"];
    double y = [[text substringWithRange:[m rangeAtIndex:6]] doubleValue], h = [[text substringWithRange:[m rangeAtIndex:10]] doubleValue];
    if ([m rangeAtIndex:3].location == NSNotFound) {
      cornerX[set] = [[text substringWithRange:[m rangeAtIndex:4]] doubleValue]; cornerY[set] = y; found[set] = true;
    }
    top[set] = MAX(top[set], -y + h);	// highest edge above the bottom
  }
  if (!found[0]) return nil;
  NSMutableString *changed = [text mutableCopy];
  if (subtitleRaise > 0) {
    NSRegularExpression *subtitle = [NSRegularExpression regularExpressionWithPattern:@"(<component name=\"HUD_SUBTITLE_TEXT\"[^>]*?posY=\")([-\\d.]+)(\")" options:0 error:nil];
    NSTextCheckingResult *t = [subtitle firstMatchInString:changed options:0 range:NSMakeRange(0, changed.length)];
    if (t) [changed replaceCharactersInRange:[t rangeAtIndex:2] withString:[NSString stringWithFormat:@"%.4f", [[changed substringWithRange:[t rangeAtIndex:2]] doubleValue] - subtitleRaise]];
  }
  if (helpMoved) {
    NSRegularExpression *help = [NSRegularExpression regularExpressionWithPattern:
      @"(<component name=\"HUD_HELP_TEXT\"[^>]*?alignX=\")([A-Z])(\"[^>]*?alignY=\")([A-Z])(\"[^>]*?posX=\")([-\\d.]+)(\"[^>]*?posY=\")([-\\d.]+)(\"[^>]*?sizeX=\")([-\\d.]+)(\"[^>]*?sizeY=\")([-\\d.]+)(\")"
      options:0 error:nil];
    NSTextCheckingResult *h = [help firstMatchInString:changed options:0 range:NSMakeRange(0, changed.length)];
    if (h) {
      double w = [[changed substringWithRange:[h rangeAtIndex:10]] doubleValue], height = [[changed substringWithRange:[h rangeAtIndex:12]] doubleValue];
      NSString *values[6] = {@"L", @"T", [NSString stringWithFormat:@"%.5f", helpX], [NSString stringWithFormat:@"%.5f", helpY],
        [NSString stringWithFormat:@"%.5f", w * helpScale], [NSString stringWithFormat:@"%.5f", height * helpScale]};
      NSUInteger groups[6] = {12, 10, 8, 6, 4, 2};	// right to left, so earlier ranges stay valid
      for (int i = 0; i < 6; i++) [changed replaceCharactersInRange:[h rangeAtIndex:groups[i]] withString:values[5 - i]];
      // In the top-left list (listId 2) the game stacks the box at the top by itself, whatever posY says (posX does
      // apply). For a place lower down it leaves the list (as the floating help messages have listId -1); a place
      // along the top stays in it, as the game made it.
      NSRegularExpression *list = [NSRegularExpression regularExpressionWithPattern:@"(<component name=\"HUD_HELP_TEXT\"[^>]*?listId=\")(-?\\d+)(\"\\s+listPriority=\")(-?\\d+)(\")" options:0 error:nil];
      NSTextCheckingResult *l = [list firstMatchInString:changed options:0 range:NSMakeRange(0, changed.length)];
      if (l && (helpY != 0 || helpScale != 1)) { [changed replaceCharactersInRange:[l rangeAtIndex:4] withString:@"-1"]; [changed replaceCharactersInRange:[l rangeAtIndex:2] withString:@"-1"]; }
    }
  }
  // The subtitle entry comes before the minimap's in the file: find the minimap entries again in the edited text.
  matches = [entry matchesInString:changed options:0 range:NSMakeRange(0, changed.length)];
  text = [changed copy];
  for (NSTextCheckingResult *m in matches.reverseObjectEnumerator) {
    int set = [[text substringWithRange:[m rangeAtIndex:2]] isEqualToString:@"bigmap"];
    double x = [[text substringWithRange:[m rangeAtIndex:4]] doubleValue], y = [[text substringWithRange:[m rangeAtIndex:6]] doubleValue];
    double w = [[text substringWithRange:[m rangeAtIndex:8]] doubleValue], h = [[text substringWithRange:[m rangeAtIndex:10]] doubleValue];
    // The expanded map is taller: moving up by -dy raises its top edge, which stops at the screen's top.
    double s = set ? 1 : scale, moveY = set ? MAX(dy, -(0.98 - top[1])) : dy;
    NSString *values[4] = {
      [NSString stringWithFormat:@"%.5f", cornerX[set] + dx + (x - cornerX[set]) * s],
      [NSString stringWithFormat:@"%.5f", cornerY[set] + moveY + (y - cornerY[set]) * s],
      [NSString stringWithFormat:@"%.5f", w * s], [NSString stringWithFormat:@"%.5f", h * s]};
    NSUInteger groups[4] = {10, 8, 6, 4};	// right to left, so earlier ranges stay valid
    for (int i = 0; i < 4; i++) [changed replaceCharactersInRange:[m rangeAtIndex:groups[i]] withString:values[3 - i]];
  }
  // The notification feed sits over the minimap and "MUST match" its place: it follows sideways.
  NSRegularExpression *feed = [NSRegularExpression regularExpressionWithPattern:@"(<GameStream>\\s*<position\\s+alignX=\"L\"\\s+alignY=\"B\"\\s+posX=\")([-\\d.]+)(\")" options:0 error:nil];
  NSTextCheckingResult *f = [feed firstMatchInString:changed options:0 range:NSMakeRange(0, changed.length)];
  if (f) [changed replaceCharactersInRange:[f rangeAtIndex:2] withString:[NSString stringWithFormat:@"%.5f", [[changed substringWithRange:[f rangeAtIndex:2]] doubleValue] + dx]];
  NSRegularExpression *gaps = [NSRegularExpression regularExpressionWithPattern:@">\\s+<" options:0 error:nil];
  NSString *compact = [[gaps stringByReplacingMatchesInString:changed options:0 range:NSMakeRange(0, changed.length) withTemplate:@"><"]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSMutableData *out = [[compact dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  if (out.length > original.length) return nil;
  while (out.length < original.length) [out appendBytes:" " length:1];
  return out;
}
static void frontendOverlay(uint32_t id, uint64_t offset, uint8_t *destination, int64_t count) {
  if (count <= 0 || ![assetFiles[id][0] isEqualToString:@"common/data/ui/frontend.xml"]) return;
  @synchronized([NSNumber class]) {
    if (!frontendLayout) {
#if TARGET_OS_SIMULATOR
      // Test (PG_MINIMAP="dx,dy,scale"): a layout without the app's Settings, for calibrating the editor.
      double tx, ty, ts; const char *test = getenv("PG_MINIMAP");
      if (test && sscanf(test, "%lf,%lf,%lf", &tx, &ty, &ts) == 3) PGSetMinimapLayout(tx, ty, ts);
      // Test (PG_HELP_TEXT="x,y,scale"): a help message place without the app's Settings.
      test = getenv("PG_HELP_TEXT");
      if (test && sscanf(test, "%lf,%lf,%lf", &tx, &ty, &ts) == 3) PGSetHelpTextLayout(tx, ty, ts);
#endif
      // A mod's frontend.xml is moved too: the player chose the place, and the default changes nothing.
      // (A leftover copy of the game's own file in Mods kept the setting from working, GTA-131.)
      NSData *rewritten = nil;
      if (minimapDX != 0 || minimapDY != 0 || minimapScale != 1 || subtitleRaise > 0 || helpMoved) {
        uint64_t size = [assetFiles[id][1] unsignedLongLongValue];
        NSMutableData *original = [NSMutableData dataWithLength:(NSUInteger)size];
        if (readAssetImpl(id, 0, original.mutableBytes, (uint32_t)size) == (int64_t)size)
          rewritten = PGFrontendRewrite(original, minimapDX, minimapDY, minimapScale);
        char line[160];
        snprintf(line, sizeof line, rewritten ? "Minimap: moved by %.3f, %.3f, size %.2f; subtitles raised by %.3f; help messages at %.3f, %.3f, size %.2f%s." : "Minimap: frontend.xml not as expected; position %.3f, %.3f, size %.2f, subtitles %.3f, help messages %.3f, %.3f, %.2f not applied%s.",
                 minimapDX, minimapDY, minimapScale, subtitleRaise, helpX, helpY, helpScale, modFiles[@(id)] ? " (in a mod's frontend.xml)" : "");
        pg_log(line);
      }
      frontendLayout = rewritten ?: [NSData data];
    }
    if (frontendLayout.length && offset < frontendLayout.length)
      memcpy(destination, (const uint8_t *)frontendLayout.bytes + offset, (size_t)MIN((uint64_t)count, frontendLayout.length - offset));
  }
}
static int64_t readAsset(uint32_t id,uint64_t offset,uint8_t *destination,uint32_t length){
  assetReadNetworkMS=assetReadLockMS=0;assetReadNetworkBytes=0;assetReadSource=2;
  double healthStart=assetNowMS();
  double start=assetTimingFD>=0?healthStart:0;int64_t result=readAssetImpl(id,offset,destination,length);
  envTestMetaOverlay(id,offset,destination,result);
  controlMetaOverlay(id,offset,destination,result);
  gameConfigOverlay(id,offset,destination,result);
  frontendOverlay(id,offset,destination,result);
  double took=assetNowMS()-healthStart;
  atomic_fetch_add(&healthReads,1);atomic_fetch_add(&healthReadMicros,(uint64_t)(took*1000));
  if(result<0)atomic_fetch_add(&healthReadErrors,1);
  else{atomic_fetch_add(&healthReadBytes,(uint64_t)result);if((uint64_t)result<length)atomic_fetch_add(&healthShortReads,1);}
  if(took>250)atomic_fetch_add(&healthSlowReads,1);
  if(assetTimingFD>=0&&atomic_fetch_add(&assetTimingRecords,1)<200000){char record[256];int n=snprintf(record,sizeof record,"%.3f,%.3f,%u,%llu,%u,%lld,%u,%u,%.3f,%.3f,%llu\n",start,assetNowMS(),id,offset,length,result,assetReadSource,assetPrefetchRead,assetReadNetworkMS,assetReadLockMS,assetReadNetworkBytes);if(n>0&&n<sizeof record)write(assetTimingFD,record,(size_t)n);}
  return result;
}
static _Atomic bool assetEngineBooted;
void pg_assets_prewarm(void){
  atomic_store(&assetEngineBooted,true);
  if(localDataRoot){pg_log("Startup asset warming skipped: the game files are on this device.");pg_log("ASSET_WARM_COMPLETE");return;}
#if TARGET_OS_SIMULATOR
  if(!assetStreamSimulation||[NSProcessInfo.processInfo.arguments containsObject:@"--skip-asset-warm"]){pg_log("Simulator startup asset warming skipped.");return;}
#endif
  @autoreleasepool {
    NSString *path=[NSBundle.mainBundle pathForResource:@"bootset_native" ofType:@"json"];
    NSString *metadataPath=[NSBundle.mainBundle pathForResource:@"bootset_native.summary" ofType:@"json"];
    NSData *metadataData=metadataPath?[NSData dataWithContentsOfFile:metadataPath]:nil;
    NSDictionary *metadata=metadataData?[NSJSONSerialization JSONObjectWithData:metadataData options:0 error:nil]:nil;
    if(![metadata[@"version"] isEqual:assetVersion])path=nil;
    if(!path)path=[NSBundle.mainBundle pathForResource:@"bootset_low" ofType:@"json"];
    NSData *data=path?[NSData dataWithContentsOfFile:path]:nil;
    NSArray *boot=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if(![boot isKindOfClass:NSArray.class]){pg_log("Startup asset warm set unavailable; continuing demand loading.");return;}
    NSMutableDictionary<NSString *,NSNumber *> *ids=[NSMutableDictionary dictionaryWithCapacity:assetFiles.count];
    for(NSUInteger i=0;i<assetFiles.count;i++)ids[assetFiles[i][0]]=@(i);
    NSMutableArray *jobs=[NSMutableArray array];uint64_t total=0;
    for(NSArray *entry in boot){
      if(![entry isKindOfClass:NSArray.class]||entry.count!=2)continue;NSNumber *identity=ids[entry[0]];if(!identity)continue;
      uint64_t size=[assetFiles[identity.unsignedIntValue][1] unsignedLongLongValue];NSMutableArray *ranges=[NSMutableArray array];
      for(NSArray *range in entry[1]){
        if(![range isKindOfClass:NSArray.class]||range.count!=2)continue;
        uint64_t first=[range[0] unsignedLongLongValue],last=[range[1] unsignedLongLongValue];if(first>=size||last<first)continue;
        first=first/4096*4096;last=MIN((MIN(last,size-1)/4096+1)*4096,size);if(last<=first)continue;
        [ranges addObject:@[@(first),@(last)]];total+=last-first;
      }
      if(ranges.count)[jobs addObject:@[identity,ranges]];
    }
    uint64_t present=0;
    for(NSArray *job in jobs){uint32_t id=[job[0] unsignedIntValue];uint64_t size=[assetFiles[id][1] unsignedLongLongValue];NSString *base=[packedRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%u",id]];
      for(NSArray *range in job[1]){uint64_t first=[range[0] unsignedLongLongValue],end=[range[1] unsignedLongLongValue];present+=pg_packed_present_bytes([base stringByAppendingString:@".data"].fileSystemRepresentation,[base stringByAppendingString:@".map"].fileSystemRepresentation,size,first,end-first);}}
    NSNumber *available=nil;[[NSURL fileURLWithPath:cacheRoot] getResourceValue:&available forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
    if(available&&available.unsignedLongLongValue<total-present+256*1024*1024){pg_log("Startup asset warming skipped to preserve available phone storage.");return;}
    char storage[192];snprintf(storage,sizeof storage,"Startup asset storage: %.1f MB already cached, %.1f MB missing.",present/1048576.0,(total-present)/1048576.0);pg_log(storage);
    if(!total)return;
    char begin[160];snprintf(begin,sizeof begin,"ASSET_WARM_PROGRESS 0 %.0f",total/1048576.0);pg_log(begin);
    if(present==total){
      // Published bitmap bits describe immutable, fully synced cache blocks.
      // Preparation only needs readiness; avoid copying the whole warm set.
      snprintf(begin,sizeof begin,"ASSET_WARM_PROGRESS 100 %.0f",total/1048576.0);pg_log(begin);
      pg_log("Startup asset warming: all planned bytes verified cached; no data copies needed.");
      pg_log("ASSET_WARM_COMPLETE");return;
    }
    __block _Atomic uint64_t next=0,completed=0,lastReport=0;
    __block _Atomic unsigned failures=0;
    uint64_t totalBytes=total;
    dispatch_apply(6,prefetchQueue,^(size_t lane){@autoreleasepool {
      uint8_t *scratch=malloc(1024*1024);if(!scratch){atomic_fetch_add(&failures,1);return;}
      for(;;){
        if(atomic_load(&failures)>=3)break;
        uint64_t jobIndex=atomic_fetch_add(&next,1);if(jobIndex>=jobs.count)break;
        NSArray *job=jobs[jobIndex];uint32_t id=[job[0] unsignedIntValue];
        uint64_t assetSize=[assetFiles[id][1] unsignedLongLongValue];NSString *base=[packedRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%u",id]];
        NSString *dataPath=[base stringByAppendingString:@".data"],*mapPath=[base stringByAppendingString:@".map"];
        @autoreleasepool {for(NSArray *range in job[1]){
          uint64_t offset=[range[0] unsignedLongLongValue],end=[range[1] unsignedLongLongValue];
          while(offset<end){
            if(atomic_load(&failures)>=3)break;
            uint32_t length=(uint32_t)MIN((uint64_t)1024*1024,end-offset);
            uint64_t cached=pg_packed_present_bytes(dataPath.fileSystemRepresentation,mapPath.fileSystemRepresentation,assetSize,offset,length);
            int64_t actual=cached==length?length:readAsset(id,offset,scratch,length);
            if(actual!=length){atomic_fetch_add(&failures,1);break;}
            offset+=length;uint64_t done=atomic_fetch_add(&completed,length)+length,percent=MIN((uint64_t)100,done*100/totalBytes),previous=atomic_load(&lastReport);
            if(percent>=previous+2&&atomic_compare_exchange_strong(&lastReport,&previous,percent)){char progress[128];snprintf(progress,sizeof progress,"ASSET_WARM_PROGRESS %llu %.0f",percent,totalBytes/1048576.0);pg_log(progress);}
          }
        }}
      }
      free(scratch);
    }});
    char summary[192];snprintf(summary,sizeof summary,"Startup asset warming: %.1f / %.1f MB ready, %u failures; continuing engine boot.",atomic_load(&completed)/1048576.0,totalBytes/1048576.0,atomic_load(&failures));pg_log(summary);
    pg_log("ASSET_WARM_COMPLETE");
  }
}
static void pumpAssetHints(void){
  PGAssetHint hint;
  while(pg_asset_hint_next(&normalHints,&lowHints,(unsigned)atomic_load(&activePrefetch),(unsigned)atomic_load(&activeSpeculative),16,4,&hint)){
    if(hint.id>=assetFiles.count)continue;
    uint64_t size=[assetFiles[hint.id][1] unsignedLongLongValue];if(hint.offset>=size)continue;
    hint.length=(uint32_t)MIN((uint64_t)hint.length,size-hint.offset);
    NSString *base=[packedRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%u",hint.id]];
    if(pg_packed_present_bytes([base stringByAppendingString:@".data"].fileSystemRepresentation,[base stringByAppendingString:@".map"].fileSystemRepresentation,size,hint.offset,hint.length)==hint.length){hintsCached++;continue;}
    PGAssetHint job=hint;atomic_fetch_add(&activePrefetch,1);if(job.speculative)atomic_fetch_add(&activeSpeculative,1);hintsScheduled++;
    dispatch_block_t work=^{@autoreleasepool {
      assetPrefetchRead=true;assetSpeculativeRead=job.speculative;
      uint8_t *bytes=malloc(1024*1024);
      @try {if(bytes){uint64_t end=job.offset+job.length;for(uint64_t at=job.offset;at<end;){uint32_t length=(uint32_t)MIN((uint64_t)1024*1024,end-at);if(readAsset(job.id,at,bytes,length)!=length)break;at+=length;}}}
      @finally {free(bytes);assetPrefetchRead=assetSpeculativeRead=false;if(job.speculative)atomic_fetch_sub(&activeSpeculative,1);atomic_fetch_sub(&activePrefetch,1);}
    }};
    if(assetBalancedQOS)work=dispatch_block_create_with_qos_class(DISPATCH_BLOCK_ENFORCE_QOS_CLASS,job.speculative?QOS_CLASS_BACKGROUND:QOS_CLASS_UTILITY,0,work);
    dispatch_async(assetBalancedQOS&&job.speculative?speculativeQueue:prefetchQueue,work);
  }
}
// A dedicated consumer keeps processing upcoming reads even when all demand
// threads are waiting for a large region file. It follows the mirror protocol:
// bit 30 selects speculation, and only the lower 30 bits are a byte count.
static void *assetHintLoop(void *unused){
  pthread_setname_np("gta.asset.hints");if(assetBalancedQOS)pthread_set_qos_class_self_np(QOS_CLASS_UTILITY,0);
  wasm_rt_trap_t trap=wasm_rt_impl_try();if(trap){pg_log("Native asset hint worker encountered invalid engine memory.");return NULL;}
  _Atomic int32_t *table=pg_pointer(assetHost,assetTable,64);double report=assetNowMS();
  for(;;){int32_t bell=atomic_load(table);@autoreleasepool {
    uint32_t ring=atomic_load(table+2),capacity=atomic_load(table+3),head=atomic_load(table+4),tail=atomic_load(table+5);
    if(ring&&capacity){uint32_t oldest=pg_asset_hint_oldest(head,tail,capacity);hintsLapped+=(uint32_t)(oldest-tail);tail=oldest;
      while(tail!=head){uint64_t address=assetTable+((uint64_t)ring+(uint64_t)(tail%capacity)*4)*4;_Atomic int32_t *entry=pg_pointer(assetHost,address,16);uint32_t raw=atomic_load(entry+3);if(!raw)break;
        PGAssetHint hint;uint32_t id=atomic_load(entry);uint64_t offset=(uint32_t)atomic_load(entry+1)|((uint64_t)(uint32_t)atomic_load(entry+2)<<32);
        if(pg_asset_hint_decode(id,offset,raw,&hint)){if(hint.speculative){pg_asset_hint_push(&lowHints,hint);hintsLowSeen++;}else{pg_asset_hint_push(&normalHints,hint);hintsNormalSeen++;}}
        atomic_store(entry+3,0);tail++;
      }
      atomic_store(table+5,(int32_t)tail);
    }
    pumpAssetHints();double now=assetNowMS();if(now-report>=10000){char line[256];snprintf(line,sizeof line,"Native asset hints: normal %llu, speculative %llu, scheduled %llu, cached %llu, lapped %llu, queues %u/%u, active %d/%d.",hintsNormalSeen,hintsLowSeen,hintsScheduled,hintsCached,hintsLapped,normalHints.count,lowHints.count,atomic_load(&activePrefetch),atomic_load(&activeSpeculative));pg_log(line);report=now;}
  }pg_atomic_wait32(w2c_env_memory(assetHost),assetTable,bell,10000000);}
}
static void *assetLoop(void *unused) {
  char workerName[32];snprintf(workerName,sizeof workerName,"gta.asset.read.%ld",(long)(intptr_t)unused);pthread_setname_np(workerName);
  wasm_rt_trap_t trap=wasm_rt_impl_try();if(trap){pg_log("Native asset worker encountered invalid engine memory.");return NULL;}
  _Atomic int32_t *table=pg_pointer(assetHost,assetTable,64);
  for(;;) {
    int32_t bell=atomic_load(table);int count=atomic_load(table+1);
    if(count<0||count>4096){pg_log("Invalid native asset slot count.");return NULL;}
    for(int i=0;i<count;i++) {
      uint64_t address=assetTable+(16+(uint64_t)i*16)*4;
      _Atomic int32_t *slot=pg_pointer(assetHost,address,64);int32_t expected=1;
      if(!atomic_compare_exchange_strong(slot,&expected,3))continue;
      @autoreleasepool {
        uint32_t id=atomic_load(slot+1),len=atomic_load(slot+6);
        uint64_t off=(uint32_t)atomic_load(slot+2)|((uint64_t)(uint32_t)atomic_load(slot+3)<<32);
        uint64_t dest=(uint32_t)atomic_load(slot+4)|((uint64_t)(uint32_t)atomic_load(slot+5)<<32);
        int64_t result=readAsset(id,off,pg_pointer(assetHost,dest,len),len);
        atomic_store(slot+7,(int32_t)result);atomic_store(slot,2);
        pg_atomic_notify(w2c_env_memory(assetHost),address,UINT32_MAX);
      }
    }
    // Consume optional prefetch hints. Demand reads remain authoritative.
    if (!assetQueuedHints&&(intptr_t)unused==0) {
    uint32_t hintOffset=atomic_load(table+2),entries=atomic_load(table+3);
    uint32_t used=atomic_load(table+5),claimed=atomic_load(table+4);
    while(entries&&used!=claimed) {
      uint64_t address=assetTable+(hintOffset+(uint64_t)(used%entries)*4)*4;
      _Atomic int32_t *hint=pg_pointer(assetHost,address,16);
      int32_t wanted=atomic_load(hint+3);if(!wanted||atomic_load(&activePrefetch)>=4)break;
      uint32_t id=(uint32_t)atomic_load(hint);
      uint64_t offset=(uint32_t)atomic_load(hint+1)|((uint64_t)(uint32_t)atomic_load(hint+2)<<32);
      uint32_t length=MIN((uint32_t)wanted,512*1024);
      atomic_store(hint+3,0);used++;atomic_store(table+5,used);atomic_fetch_add(&activePrefetch,1);
      dispatch_async(prefetchQueue,^{@autoreleasepool {assetPrefetchRead=assetSpeculativeRead=true;uint8_t *bytes=malloc(length);if(bytes){readAsset(id,offset,bytes,length);free(bytes);}assetPrefetchRead=assetSpeculativeRead=false;atomic_fetch_sub(&activePrefetch,1);}});
    }
    }
    pg_atomic_wait32(w2c_env_memory(assetHost),assetTable,bell,10000000);
  }
}
void w2c_env_wasm_httpfs_io_start_js(struct w2c_env *host,u64 table) {
  if(assetTable)return;assetHost=host;assetTable=table;
  pg_log("Native asset request queue attached; files cached on the phone.");
  for(int i=0;i<6;i++){pthread_t thread;pthread_create(&thread,NULL,assetLoop,(void *)(intptr_t)i);pthread_detach(thread);}
  if(assetQueuedHints){pthread_t thread;pthread_create(&thread,NULL,assetHintLoop,NULL);pthread_detach(thread);pg_log("Native upcoming asset queue enabled: 16 hints, at most 4 speculative; demand reads take priority.");}
}

// MARK: Download all game files (see NativeAssetPreload.h)

void PGAssetCachePrepare(const char *manifestPath,const char *filesRoot){pg_assets_configure(manifestPath,filesRoot);}
bool PGAssetPreloadSupported(void){
  if(!assetFiles.count||!packedRoot||localDataRoot)return false;
#if TARGET_OS_SIMULATOR
  return assetStreamSimulation;
#else
  return true;
#endif
}
// Files whose server size disagrees with the bundled manifest can never be
// cached (the engine rejects them too). They are remembered in the cache
// directory and left out of the plan so it can still complete.
static NSMutableIndexSet *preloadUnavailable;
static pthread_mutex_t preloadUnavailableLock=PTHREAD_MUTEX_INITIALIZER;
static NSString *preloadUnavailablePath(void){return [cacheRoot stringByAppendingPathComponent:@"preload-unavailable.txt"];}
static NSIndexSet *preloadUnavailableIDs(void){
  pthread_mutex_lock(&preloadUnavailableLock);
  if(!preloadUnavailable){
    preloadUnavailable=[NSMutableIndexSet indexSet];
    NSString *text=[NSString stringWithContentsOfFile:preloadUnavailablePath() encoding:NSUTF8StringEncoding error:nil];
    for(NSString *line in [text componentsSeparatedByString:@"\n"])if(line.length)[preloadUnavailable addIndex:(NSUInteger)line.integerValue];
  }
  NSIndexSet *copy=[preloadUnavailable copy];pthread_mutex_unlock(&preloadUnavailableLock);return copy;
}
static bool preloadMarkUnavailable(uint32_t id){
  preloadUnavailableIDs();
  pthread_mutex_lock(&preloadUnavailableLock);
  if([preloadUnavailable containsIndex:id]){pthread_mutex_unlock(&preloadUnavailableLock);return false;}
  [preloadUnavailable addIndex:id];NSMutableString *text=[NSMutableString string];
  [preloadUnavailable enumerateIndexesUsingBlock:^(NSUInteger index,BOOL *stop){[text appendFormat:@"%lu\n",(unsigned long)index];}];
  [text writeToFile:preloadUnavailablePath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
  pthread_mutex_unlock(&preloadUnavailableLock);return true;
}
static NSArray<NSNumber *> *preloadSelection(const char *filter){
  NSIndexSet *unavailable=preloadUnavailableIDs();
  NSArray<NSString *> *prefixes=nil;
  if(filter&&*filter){NSMutableArray *list=[NSMutableArray array];for(NSString *part in [@(filter) componentsSeparatedByString:@","])if(part.length)[list addObject:part];prefixes=list;}
  NSMutableArray<NSNumber *> *ids=[NSMutableArray arrayWithCapacity:assetFiles.count];
  for(NSUInteger i=0;i<assetFiles.count;i++){
    if(prefixes){BOOL match=NO;NSString *path=assetFiles[i][0];for(NSString *prefix in prefixes)if([path hasPrefix:prefix]){match=YES;break;}if(!match)continue;}
    if([unavailable containsIndex:i])continue;
    [ids addObject:@(i)];
  }
  return ids;
}
static uint64_t preloadPresent(uint32_t id,uint64_t offset,uint64_t length){
  uint64_t size=[assetFiles[id][1] unsignedLongLongValue];
  NSString *base=[packedRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"%u",id]];
  return pg_packed_present_bytes([base stringByAppendingString:@".data"].fileSystemRepresentation,[base stringByAppendingString:@".map"].fileSystemRepresentation,size,offset,length);
}
void PGAssetPreloadMeasure(const char *filter,uint64_t *totalBytes,uint64_t *cachedBytes,uint32_t *fileCount){
  uint64_t total=0,cached=0;uint32_t files=0;
  if(assetFiles.count&&packedRoot){@autoreleasepool {
    for(NSNumber *identity in preloadSelection(filter)){
      uint32_t id=identity.unsignedIntValue;uint64_t size=[assetFiles[id][1] unsignedLongLongValue];
      total+=size;files++;if(size)cached+=preloadPresent(id,0,size);
    }
  }}
  if(totalBytes)*totalBytes=total;if(cachedBytes)*cachedBytes=cached;if(fileCount)*fileCount=files;
}

static pthread_mutex_t preloadLock=PTHREAD_MUTEX_INITIALIZER;
static NSArray<NSNumber *> *preloadIDs;
static NSUInteger preloadCursorFile;
static uint64_t preloadCursorOffset;
static _Atomic bool preloadStop,preloadExhausted;
static _Atomic int preloadRunning;
static _Atomic unsigned preloadLanes=4;
static _Atomic uint64_t preloadTotal,preloadCached,preloadDownloaded,preloadReported;
static _Atomic unsigned preloadConsecutiveFailures;
static _Atomic int32_t preloadError;
static const uint32_t preloadSpan=1024*1024;

// Next missing span, in manifest order. Whole files already on the device are
// skipped with one presence-map check.
static bool preloadNextSpan(uint32_t *id,uint64_t *offset,uint32_t *length){
  pthread_mutex_lock(&preloadLock);bool found=false;
  while(!found&&preloadCursorFile<preloadIDs.count){
    uint32_t file=preloadIDs[preloadCursorFile].unsignedIntValue;uint64_t size=[assetFiles[file][1] unsignedLongLongValue];
    if(preloadCursorOffset==0&&(!size||preloadPresent(file,0,size)==size)){preloadCursorFile++;continue;}
    if(preloadCursorOffset>=size){preloadCursorFile++;preloadCursorOffset=0;continue;}
    *id=file;*offset=preloadCursorOffset;*length=(uint32_t)MIN((uint64_t)preloadSpan,size-preloadCursorOffset);
    preloadCursorOffset+=*length;found=true;
  }
  pthread_mutex_unlock(&preloadLock);return found;
}
static void preloadFail(int32_t error,const char *message){
  int32_t none=PGAssetPreloadErrorNone;atomic_compare_exchange_strong(&preloadError,&none,error);
  atomic_store(&preloadStop,true);pg_log(message);
}
static void *preloadLane(void *context){
  unsigned lane=(unsigned)(uintptr_t)context;
  char name[32];snprintf(name,sizeof name,"gta.asset.preload.%u",lane);pthread_setname_np(name);
  // Same low URL priority as speculative engine hints: demand reads go first.
  assetPrefetchRead=assetSpeculativeRead=true;
  uint8_t *scratch=malloc(preloadSpan);
  if(!scratch)preloadFail(PGAssetPreloadErrorStorage,"Asset preload: out of memory for a download buffer.");
  while(scratch&&!atomic_load(&preloadStop)){
    if(atomic_load(&preloadExhausted))break;
    if(lane>=atomic_load(&preloadLanes)){usleep(250000);continue;}
    uint32_t id,length;uint64_t offset;
    if(!preloadNextSpan(&id,&offset,&length)){atomic_store(&preloadExhausted,true);break;}
    @autoreleasepool {
      if([preloadUnavailableIDs() containsIndex:id])continue;
      uint64_t before=preloadPresent(id,offset,length);
      if(before==length)continue;
      bool stored=false;
      bool unavailable=false;
      for(unsigned attempt=0;attempt<4&&!atomic_load(&preloadStop);attempt++){
        assetSizeMismatch=false;
        if(attempt){for(unsigned wait=0;wait<(4u<<attempt)&&!atomic_load(&preloadStop);wait++)usleep(250000);}
        int64_t actual=readAsset(id,offset,scratch,length);
        if(assetSizeMismatch){unavailable=true;break;}
        if(actual!=length)continue;
        // readAsset can still return bytes when the packed write failed (it
        // falls back to the old cache). Only a published span counts.
        if(preloadPresent(id,offset,length)!=length){preloadFail(PGAssetPreloadErrorStorage,"Asset preload: cache write did not persist; stopping (storage full?).");break;}
        stored=true;break;
      }
      if(unavailable){
        // Drop the whole file from this run's plan and every later one.
        if(preloadMarkUnavailable(id)){
        uint64_t size=[assetFiles[id][1] unsignedLongLongValue],present=preloadPresent(id,0,size);
        atomic_fetch_sub(&preloadTotal,size);atomic_fetch_sub(&preloadCached,present);
        pthread_mutex_lock(&preloadLock);if(preloadCursorFile<preloadIDs.count&&preloadIDs[preloadCursorFile].unsignedIntValue==id){preloadCursorFile++;preloadCursorOffset=0;}pthread_mutex_unlock(&preloadLock);
        char line[PATH_MAX+96];snprintf(line,sizeof line,"Asset preload: %s differs in size from the manifest on the server; skipped.",[assetFiles[id][0] UTF8String]);pg_log(line);
        }
      }else if(stored){
        atomic_store(&preloadConsecutiveFailures,0);
        atomic_fetch_add(&preloadDownloaded,length-before);
        uint64_t cached=atomic_fetch_add(&preloadCached,length-before)+length-before,total=atomic_load(&preloadTotal);
        uint64_t percent=total?cached*100/total:100,reported=atomic_load(&preloadReported);
        if(percent>=reported+5&&atomic_compare_exchange_strong(&preloadReported,&reported,percent)){char line[160];snprintf(line,sizeof line,"ASSET_PRELOAD_PROGRESS %llu %.1f %.1f",percent,cached/1048576.0,total/1048576.0);pg_log(line);}
      }else if(!atomic_load(&preloadStop)&&atomic_fetch_add(&preloadConsecutiveFailures,1)+1>=3){
        preloadFail(PGAssetPreloadErrorNetwork,"Asset preload: the asset server did not answer; stopping.");
      }
    }
  }
  free(scratch);
  if(atomic_fetch_sub(&preloadRunning,1)==1){
    // Last lane out re-measures: engine demand fills count too.
    uint64_t total=0,cached=0;uint32_t files=0;
    pthread_mutex_lock(&preloadLock);NSArray<NSNumber *> *ids=preloadIDs;pthread_mutex_unlock(&preloadLock);
    @autoreleasepool {NSIndexSet *unavailable=preloadUnavailableIDs();for(NSNumber *identity in ids){uint32_t file=identity.unsignedIntValue;if([unavailable containsIndex:file])continue;uint64_t size=[assetFiles[file][1] unsignedLongLongValue];total+=size;files++;if(size)cached+=preloadPresent(file,0,size);}}
    atomic_store(&preloadCached,cached);atomic_store(&preloadTotal,total);
    // Went through the whole plan without a pause and still missing bytes:
    // some spans kept failing. Say so instead of looking merely paused.
    int32_t none=PGAssetPreloadErrorNone;
    if(cached<total&&atomic_load(&preloadExhausted)&&!atomic_load(&preloadStop))atomic_compare_exchange_strong(&preloadError,&none,PGAssetPreloadErrorNetwork);
    char line[224];snprintf(line,sizeof line,"Asset preload stopped: %.1f / %.1f MB on device across %u files, %.1f MB downloaded this run, error %d.",cached/1048576.0,total/1048576.0,files,atomic_load(&preloadDownloaded)/1048576.0,atomic_load(&preloadError));pg_log(line);
    if(cached==total)pg_log("ASSET_PRELOAD_COMPLETE");
  }
  return NULL;
}
bool PGAssetPreloadStart(const char *filter,unsigned lanes){
  if(!PGAssetPreloadSupported())return false;
  int idle=0;if(!atomic_compare_exchange_strong(&preloadRunning,&idle,-1))return true;
  lanes=MAX(1u,MIN(6u,lanes));
  NSArray<NSNumber *> *ids=preloadSelection(filter);uint64_t total=0,cached=0;
  for(NSNumber *identity in ids){uint32_t file=identity.unsignedIntValue;uint64_t size=[assetFiles[file][1] unsignedLongLongValue];total+=size;if(size)cached+=preloadPresent(file,0,size);}
  pthread_mutex_lock(&preloadLock);preloadIDs=ids;preloadCursorFile=0;preloadCursorOffset=0;pthread_mutex_unlock(&preloadLock);
  atomic_store(&preloadTotal,total);atomic_store(&preloadCached,cached);atomic_store(&preloadDownloaded,0);
  atomic_store(&preloadReported,total?cached*100/total:100);atomic_store(&preloadConsecutiveFailures,0);
  atomic_store(&preloadError,PGAssetPreloadErrorNone);atomic_store(&preloadStop,false);atomic_store(&preloadExhausted,false);atomic_store(&preloadLanes,lanes);
  char line[200];snprintf(line,sizeof line,"Asset preload started: %.1f / %.1f MB already on device across %lu files, %u lanes.",cached/1048576.0,total/1048576.0,(unsigned long)ids.count,lanes);pg_log(line);
  atomic_store(&preloadRunning,6);
  for(unsigned i=0;i<6;i++){pthread_t thread;if(pthread_create(&thread,NULL,preloadLane,(void *)(uintptr_t)i)){atomic_fetch_sub(&preloadRunning,1);continue;}pthread_detach(thread);}
  return true;
}
void PGAssetPreloadStop(void){atomic_store(&preloadStop,true);}
void PGAssetPreloadSetLanes(unsigned lanes){atomic_store(&preloadLanes,MAX(1u,MIN(6u,lanes)));}
PGAssetPreloadStatus PGAssetPreloadGetStatus(void){
  PGAssetPreloadStatus status={0};int running=atomic_load(&preloadRunning);
  status.running=running!=0;status.totalBytes=atomic_load(&preloadTotal);status.cachedBytes=atomic_load(&preloadCached);
  status.downloadedBytes=atomic_load(&preloadDownloaded);status.error=atomic_load(&preloadError);
  return status;
}
bool PGAssetCacheRemoveAll(uint64_t *freedBytes){
  if(freedBytes)*freedBytes=0;
  if(!cacheRoot||atomic_load(&preloadRunning)||atomic_load(&assetEngineBooted))return false;
  uint64_t cached=0;PGAssetPreloadMeasure(NULL,NULL,&cached,NULL);
  NSFileManager *files=NSFileManager.defaultManager;NSError *error=nil;
  // One explicit directory: this manifest version's cache (packed and legacy).
  if([files fileExistsAtPath:cacheRoot]&&![files removeItemAtPath:cacheRoot error:&error]){pg_log([@"Asset cache removal failed: " stringByAppendingString:error.localizedDescription].UTF8String);return false;}
  [files createDirectoryAtPath:packedRoot withIntermediateDirectories:YES attributes:nil error:nil];
  [[NSURL fileURLWithPath:cacheRoot] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
  atomic_store(&preloadCached,0);
  pthread_mutex_lock(&preloadUnavailableLock);preloadUnavailable=nil;pthread_mutex_unlock(&preloadUnavailableLock);
  if(freedBytes)*freedBytes=cached;
  char line[128];snprintf(line,sizeof line,"Asset cache removed: %.1f MB of game files freed.",cached/1048576.0);pg_log(line);
  return true;
}
