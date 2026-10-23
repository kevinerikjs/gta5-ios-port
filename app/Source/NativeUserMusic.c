// Self Radio: the player's own songs on the radio station RADIO_19_USER (GTA-5, Scripts/prepare_user_music.py).
//
// The PC game lists the songs in the user music folder with Windows Media Foundation, writes that list
// to usertracks.db (96 bytes per song) and usertracks.dbs (the paths), and decodes a song in
// rage::audMediaReader into a ring buffer that the station's stream player plays. This build has
// neither part, so:
// - PGUserMusicPrepare writes the list from Files › GTA V Port › Self Radio (App/SelfRadio.swift) before the
//   engine starts (the station only shows with 3 songs or more), and the engine's own scan only reports it
//   finished, so the engine reads that list;
// - this game's audio data has no station settings for Self Radio (RADIO_19_USER), so the engine never made the
//   station; when the engine looks them up and finds nothing, pg_user_music_station answers with settings made
//   here (only with 3 songs or more, so nothing changes for players without songs);
// - when the station prepares a song, pg_user_music_open opens it with ExtAudioFile (any format iOS
//   plays: m4a, mp3, wav, aiff, caf, flac) and a thread decodes it to 48 kHz stereo 16-bit into a
//   native buffer; the stream player's thread copies from there into the reader's ring buffer each
//   frame (pg_user_music_pump), so only that thread ever moves the ring buffer's positions.
//
// usertracks.db record: +0 path (set when loaded), +8 artist and +40 title (UTF-8, 32 bytes each),
// +72 length in ms, +84 loudness (0: none), +92 path length; the other fields are left 0.
// usertracks.dbs: each path as 4-byte characters, no terminator.
// Ring buffer (rage::audReferencedRingBuffer, as voice chat makes one): +0 data, +8 size, +16 read
// position, +20 write position, +24 bytes waiting, +73 lock with the critical section (0: none),
// +76 references. The engine frees it and its data with operator delete, so both come from operator new.
#include "HostInternal.h"
#include "engine-functions.h"
#include <AudioToolbox/AudioToolbox.h>
#include <fts.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

u64 PG_FN_OPERATOR_NEW(w2c_game *, u64);

enum { RATE = 48000, FRAME_BYTES = 4, RING_BYTES = RATE * FRAME_BYTES / 2, DECODED_BYTES = RATE * FRAME_BYTES * 4,
       CHUNK_FRAMES = 4096, RECORD = 96 };
enum { READER_STATE = 4168, READY = 3, TRACK_READER = 2224 };
enum { RING_DATA = 0, RING_SIZE = 8, RING_WRITE = 20, RING_WAITING = 24, RING_LOCKED = 73, RING_REFERENCES = 76 };

typedef struct Stream {
  struct Stream *next;
  uint64_t reader, ring;
  ExtAudioFileRef file;
  pthread_t thread;
  char name[64];
  uint32_t lengthMs;
  uint8_t *decoded;                       // DECODED_BYTES, filled by the thread, emptied by the pump
  _Atomic uint64_t written, read;         // byte counts into decoded
  _Atomic bool stop, ended;
  _Atomic uint64_t fed;                   // song bytes given to the engine
  _Atomic int32_t peak;                   // loudest sample fed since the last log line
} Stream;
// Self Radio's station is added only with enough songs (PGUserMusicPrepare, pg_user_music_station).
static bool stationWanted;
static pthread_mutex_t streamsLock = PTHREAD_MUTEX_INITIALIZER;
static Stream *streams;
static _Atomic int streamCount;

static uint8_t *memoryAt(w2c_game *instance, uint64_t address, uint64_t size) {
  if (address + size > instance->w2c_env_memory->size || address + size < address) return NULL;
  return (uint8_t *)(void *)instance->w2c_env_memory->data + address;
}

static AudioStreamBasicDescription clientFormat(void) {
  return (AudioStreamBasicDescription){ .mSampleRate = RATE, .mFormatID = kAudioFormatLinearPCM,
    .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, .mBytesPerPacket = FRAME_BYTES,
    .mFramesPerPacket = 1, .mBytesPerFrame = FRAME_BYTES, .mChannelsPerFrame = 2, .mBitsPerChannel = 16 };
}

// Opens a song for decoding to the client format; its length in ms, or 0 when iOS can't play it.
static ExtAudioFileRef openSong(const char *path, uint32_t *lengthMs) {
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
  ExtAudioFileRef file = NULL;
  OSStatus status = url ? ExtAudioFileOpenURL(url, &file) : -1;
  if (url) CFRelease(url);
  if (status || !file) return NULL;
  AudioStreamBasicDescription source = {0}, client = clientFormat();
  UInt32 size = sizeof source; SInt64 frames = 0; UInt32 framesSize = sizeof frames;
  if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &source) || source.mSampleRate <= 0 ||
      ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &framesSize, &frames) || frames <= 0 ||
      ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client)) {
    ExtAudioFileDispose(file);
    return NULL;
  }
  *lengthMs = (uint32_t)((double)frames * 1000.0 / source.mSampleRate);
  return file;
}

// UTF-8 into a 32-byte field: cut at a whole character, always terminated.
static void putText(uint8_t *field, CFStringRef text) {
  char buffer[256] = "";
  if (text && CFGetTypeID(text) == CFStringGetTypeID()) CFStringGetCString(text, buffer, sizeof buffer, kCFStringEncodingUTF8);
  size_t length = strlen(buffer);
  if (length > 31) { length = 31; while (length && ((uint8_t)buffer[length] & 0xC0) == 0x80) length--; }
  memcpy(field, buffer, length);
}

typedef struct { char *path, *name; } Song;
static int bySongName(const void *a, const void *b) { return strcasecmp(((const Song *)a)->name, ((const Song *)b)->name); }

// Every song in the folder and its subfolders (an album per folder works too), by name.
int32_t PGUserMusicPrepare(const char *musicFolder, const char *filesRoot) {
  Song *songs = NULL; size_t found = 0, capacity = 0, skipped = 0;
  char *const roots[] = { (char *)musicFolder, NULL };
  FTS *walk = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
  for (FTSENT *entry; walk && (entry = fts_read(walk));) {
    if (entry->fts_info == FTS_D && entry->fts_level > 0 && entry->fts_name[0] == '.') { fts_set(walk, entry, FTS_SKIP); continue; }
    if (entry->fts_info != FTS_F || entry->fts_name[0] == '.') continue;
    const char *extension = strrchr(entry->fts_name, '.');
    if (extension && !strcasecmp(extension, ".m4p")) { skipped++; continue; }   // Apple Music and old iTunes Store songs are protected
    if (found == capacity) { capacity = capacity ? capacity * 2 : 32; songs = realloc(songs, capacity * sizeof *songs); }
    songs[found++] = (Song){ strdup(entry->fts_path), strdup(entry->fts_path + strlen(musicFolder)) };
  }
  if (walk) fts_close(walk);
  if (found) qsort(songs, found, sizeof *songs, bySongName);
  uint8_t *records = calloc(found ? found : 1, RECORD);
  size_t pathsCapacity = 4096, pathsLength = 0; uint8_t *paths = malloc(pathsCapacity);
  int32_t count = 0;
  for (size_t i = 0; i < found && count < 65535; i++) {
    uint32_t lengthMs = 0;
    ExtAudioFileRef file = openSong(songs[i].path, &lengthMs);
    if (!file) {
      skipped++;
      char line[PATH_MAX + 64]; snprintf(line, sizeof line, "Self Radio: %s can't be played (not a song iOS can open).", songs[i].name + (songs[i].name[0] == '/'));
      pg_log(line);
      continue;
    }
    uint8_t *record = records + (size_t)count * RECORD;
    CFDictionaryRef tags = NULL; AudioFileID audioFile = NULL; UInt32 size = sizeof audioFile;
    if (!ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile) && audioFile) {
      size = sizeof tags;
      if (AudioFileGetProperty(audioFile, kAudioFilePropertyInfoDictionary, &size, &tags)) tags = NULL;
    }
    CFStringRef artist = tags ? CFDictionaryGetValue(tags, CFSTR(kAFInfoDictionary_Artist)) : NULL;
    CFStringRef title = tags ? CFDictionaryGetValue(tags, CFSTR(kAFInfoDictionary_Title)) : NULL;
    putText(record + 8, artist);
    if (title) putText(record + 40, title);
    else {
      // No title tag: the file name without its extension.
      const char *base = strrchr(songs[i].name, '/');
      char name[256]; snprintf(name, sizeof name, "%s", base ? base + 1 : songs[i].name);
      char *dot = strrchr(name, '.'); if (dot && dot != name) *dot = 0;
      CFStringRef text = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
      putText(record + 40, text);
      if (text) CFRelease(text);
    }
    if (tags) CFRelease(tags);
    ExtAudioFileDispose(file);
    memcpy(record + 72, &lengthMs, 4);
    CFStringRef path = CFStringCreateWithCString(NULL, songs[i].path, kCFStringEncodingUTF8);
    CFIndex characters = 0, bytes = 0;
    if (path) {
      CFRange all = CFRangeMake(0, CFStringGetLength(path));
      CFStringGetBytes(path, all, kCFStringEncodingUTF32LE, 0, false, NULL, 0, &bytes);
      while (pathsLength + (size_t)bytes > pathsCapacity) { pathsCapacity *= 2; paths = realloc(paths, pathsCapacity); }
      CFStringGetBytes(path, all, kCFStringEncodingUTF32LE, 0, false, paths + pathsLength, bytes, &bytes);
      characters = bytes / 4;
      CFRelease(path);
    }
    pathsLength += (size_t)bytes;
    uint32_t pathCharacters = (uint32_t)characters;
    memcpy(record + 92, &pathCharacters, 4);
    count++;
  }
  // The engine reads the list from /userdata/AppData/Local\Rockstar Games\GTA V\User Music\usertracks.db and .dbs in
  // every mode (CApp::UpdateState makes that path with Windows separators, so it is one file name here).
  char directory[PATH_MAX]; snprintf(directory, sizeof directory, "%s/userdata", filesRoot);
  mkdir(filesRoot, 0700); mkdir(directory, 0700);
  strlcat(directory, "/AppData", sizeof directory);
  mkdir(directory, 0700);
  const char *const names[] = { "usertracks.db", "usertracks.dbs" };
  for (int f = 0; f < 2; f++) {
    char file[PATH_MAX];
    snprintf(file, sizeof file, "%s/Local\\Rockstar Games\\GTA V\\User Music\\%s", directory, names[f]);
    FILE *out = fopen(file, "wb");
    if (!out) continue;
    if (f == 0 && count) fwrite(records, RECORD, (size_t)count, out);
    if (f == 1 && pathsLength) fwrite(paths, 1, pathsLength, out);
    fclose(out);
  }
  stationWanted = count >= 3;
  if (skipped) { char line[96]; snprintf(line, sizeof line, "Self Radio: %zu file%s left out.", skipped, skipped == 1 ? "" : "s"); pg_log(line); }
  for (size_t i = 0; i < found; i++) { free(songs[i].path); free(songs[i].name); }
  free(songs); free(records); free(paths);
  return count;
}

// audMetadataManager::GetObject_Verify found no object. For Self Radio's station settings (RadioStationSettings,
// metadata type 25), which this game's audio data doesn't have, the answer is made here once, laid out like the
// other stations' (read from RADIO_01_CLASS_ROCK and the rest in this game's memory):
//   +0 type 25, +4 flags (two bits each: 1 yes, 2 no, 0 unset), +8 place in the radio wheel, +16 genre,
//   +18 name (32 bytes), +52 number of track lists, +56 their metadata references.
// Its one track list (RadioStationTrackList, type 26, read from RADIO_01_CLASS_ROCK's): +8 category 2 (music),
// +68 number of tracks, +72 the tracks (8 bytes: context, sound). The user station's music always takes the
// first track (audRadioStation::GetTrack), and that track's sound 3379414067 makes it a user track: the song to
// play then comes from the song list (audRadioTrack::Init). Its reference is in a chunk no game data has (0xFE),
// which audMetadataManager::GetObject_Verify(audMetadataRef) asks pg_user_music_ref about.
// Flags as RADIO_07_DANCE_01 (music only), plus pair 8 = 1: the user station (audRadioStation +6213), whose music
// comes from the song list (ComputeNumTracksAvailable). Lock (pair 6) left unset: the engine locks the station
// itself while there are fewer than 3 songs. Last in the wheel (after RADIO_VERITY at 30000), as on PC. Genre 0
// is no genre, so traffic never picks it (ChooseRandomRadioStationForGenre).
enum { USER_STATION_HASH = 4149039730u, STATION_SETTINGS = 25, STATION_SETTINGS_BYTES = 60, TRACK_LIST = 26, TRACK_LIST_BYTES = 80 };
static const uint32_t USER_TRACK_LIST_REF = 0xFE000001u, USER_TRACK_SOUND = 3379414067u;
static uint64_t userTrackList, userStationSettings;
u64 pg_user_music_station(w2c_game *instance, u32 hash, u32 type) {
  if (hash != USER_STATION_HASH || type != STATION_SETTINGS || !stationWanted) return 0;
  static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER; static uint64_t settings;
  pthread_mutex_lock(&lock);
  if (!settings) {
    const uint64_t made = PG_FN_OPERATOR_NEW(instance, STATION_SETTINGS_BYTES);
    uint8_t *bytes = memoryAt(instance, made, STATION_SETTINGS_BYTES);
    if (bytes) {
      memset(bytes, 0, STATION_SETTINGS_BYTES);
      const uint32_t flags = 0xAAA90A0Au, wheel = 31000;
      bytes[0] = STATION_SETTINGS;
      memcpy(bytes + 4, &flags, 4); memcpy(bytes + 8, &wheel, 4);
      memcpy(bytes + 18, "RADIO_19_USER", 13);
      const uint32_t lists = 1;
      memcpy(bytes + 52, &lists, 4); memcpy(bytes + 56, &USER_TRACK_LIST_REF, 4);
      const uint64_t list = PG_FN_OPERATOR_NEW(instance, TRACK_LIST_BYTES);
      uint8_t *fields = memoryAt(instance, list, TRACK_LIST_BYTES);
      if (fields) {
        memset(fields, 0, TRACK_LIST_BYTES);
        const uint32_t listFlags = 0xAAAAAAA0u, tracks = 1;
        fields[0] = TRACK_LIST; memcpy(fields + 4, &listFlags, 4); fields[8] = 2; fields[17] = 10;
        memcpy(fields + 68, &tracks, 4); memcpy(fields + 76, &USER_TRACK_SOUND, 4);
        userTrackList = list;
      }
      settings = made; userStationSettings = made;
      pg_log("Self Radio: the station is added to the radio (this game's audio data has none).");
    }
  }
  pthread_mutex_unlock(&lock);
  return settings;
}

// The radio wheel's icon (CRadioWheel::Update hands the wheel movie each station's name, SET_RADIO_STATIONS; the movie
// draws the icon it has for that name). This game's movie draws nothing for RADIO_19_USER, so Self Radio's place in the
// wheel was an empty gap. Its icons are only this game's stations' (RADIO_36_AUDIOPLAYER, RADIO_20_THELAB, RADIO_21_
// DLC_XM17 and RADIO_23_DLC_XM19_RADIO are blank too); the smiley, Self Radio's icon on PC, is RADIO_VERITY's here (the
// web build's own station). So Self Radio shares it (Kevin, 2026-10-21); the wheel's middle names each station. The
// station keeps its own name everywhere else. Simulator tests: PG_TEST_USER_STATION_ICON=<name>.
static const char *userStationIcon = "RADIO_VERITY";
u64 pg_radio_wheel_name(w2c_game *instance, u64 settings, u64 name) {
  if (!settings || settings != userStationSettings) return name;
  static uint64_t substitute;
  if (!substitute) {
    const char *icon = userStationIcon;
#if TARGET_OS_SIMULATOR
    if (getenv("PG_TEST_USER_STATION_ICON")) icon = getenv("PG_TEST_USER_STATION_ICON");
#endif
    const uint64_t made = PG_FN_OPERATOR_NEW(instance, 64);
    uint8_t *bytes = memoryAt(instance, made, 64);
    if (!bytes) return name;
    memset(bytes, 0, 64); snprintf((char *)bytes, 64, "%s", icon);
    substitute = made;
  }
  return substitute;
}

// GetObject_Verify(audMetadataRef) for a reference in chunk 0xFE: Self Radio's track list.
u64 pg_user_music_ref(w2c_game *instance, u32 ref, u32 type) {
  return ref == USER_TRACK_LIST_REF && type == TRACK_LIST ? userTrackList : 0;
}

// RebuildFileDatabaseCB: the list was written before the engine started. Marks the scan finished
// (the engine waits while the state at +32 is 2), so the engine reloads the list from the files.
u32 pg_user_music_scan(w2c_game *instance, u64 manager) {
  uint8_t *state = memoryAt(instance, manager + 32, 4);
  if (!state) return 0;
  atomic_store((_Atomic uint32_t *)(void *)state, 3);
  pg_log("Self Radio: the game's song scan takes the list the app wrote.");
  return 1;
}

static void *decodeSong(void *argument) {
  Stream *stream = argument;
  pthread_setname_np("gta.selfradio");
  uint8_t *chunk = malloc(CHUNK_FRAMES * FRAME_BYTES);
  double nextLog = 2;
  while (!atomic_load(&stream->stop)) {
    const uint64_t written = atomic_load(&stream->written), space = DECODED_BYTES - (written - atomic_load(&stream->read));
    // The fed seconds and the loudest sample, from the stream player's thread, logged from here.
    const double seconds = (double)atomic_load(&stream->fed) / (RATE * FRAME_BYTES);
    if (seconds >= nextLog) {
      char line[160]; snprintf(line, sizeof line, "Self Radio: %s: %.0f s played, peak level %.2f.", stream->name, seconds, atomic_exchange(&stream->peak, 0) / 32768.0);
      pg_log(line);
      nextLog = seconds < 10 ? seconds + 2 : seconds + 60;
    }
    if (atomic_load(&stream->ended) || space < CHUNK_FRAMES * FRAME_BYTES) { usleep(10000); continue; }
    AudioBufferList list = { .mNumberBuffers = 1, .mBuffers[0] = { .mNumberChannels = 2, .mDataByteSize = CHUNK_FRAMES * FRAME_BYTES, .mData = chunk } };
    UInt32 frames = CHUNK_FRAMES;
    if (ExtAudioFileRead(stream->file, &frames, &list) || !frames) { atomic_store(&stream->ended, true); continue; }
    const uint64_t bytes = (uint64_t)frames * FRAME_BYTES, at = written % DECODED_BYTES, first = bytes < DECODED_BYTES - at ? bytes : DECODED_BYTES - at;
    memcpy(stream->decoded + at, chunk, first);
    memcpy(stream->decoded, chunk + first, bytes - first);
    atomic_store(&stream->written, written + bytes);
  }
  free(chunk);
  return NULL;
}

// audRadioTrack::Prepare, before it gives up the reader it just made: the song at this index in
// the list (the manager's list), from start_ms. Fills the reader's ring buffer from here on.
u32 pg_user_music_open(w2c_game *instance, u64 track, u64 reader, u64 manager, u32 index, u32 start_ms) {
  if (getenv("PG_USER_MUSIC") && !strcmp(getenv("PG_USER_MUSIC"), "0")) return 0; // reproduces the old behaviour
  uint8_t *readerFields = memoryAt(instance, reader, READER_STATE + 4), *trackReader = memoryAt(instance, track + TRACK_READER, 8);
  uint8_t *list = memoryAt(instance, manager, 8);
  if (!readerFields || !trackReader || !list) return 0;
  uint64_t database; memcpy(&database, list, 8);
  uint8_t *header = database ? memoryAt(instance, database, 32) : NULL;
  if (!header || index >= *(uint16_t *)(header + 24)) {
    char line[96]; snprintf(line, sizeof line, "Self Radio: song %u is not in the list.", index); pg_log(line);
    return 0;
  }
  uint64_t records; memcpy(&records, header + 16, 8);
  uint8_t *record = memoryAt(instance, records + (uint64_t)index * RECORD, RECORD);
  if (!record) return 0;
  uint64_t pathAddress; uint32_t characters; memcpy(&pathAddress, record, 8); memcpy(&characters, record + 92, 4);
  uint8_t *wide = memoryAt(instance, pathAddress, (uint64_t)characters * 4);
  if (!wide || !characters) return 0;
  char path[PATH_MAX] = "";
  CFStringRef text = CFStringCreateWithBytes(NULL, wide, (CFIndex)characters * 4, kCFStringEncodingUTF32LE, false);
  if (text) { CFStringGetFileSystemRepresentation(text, path, sizeof path); CFRelease(text); }
  uint32_t lengthMs = 0;
  ExtAudioFileRef file = path[0] ? openSong(path, &lengthMs) : NULL;
  const char *name = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
  if (!file) {
    char line[PATH_MAX + 64]; snprintf(line, sizeof line, "Self Radio: can't play %s.", name); pg_log(line);
    return 0;
  }
  if (start_ms && start_ms < lengthMs) ExtAudioFileSeek(file, (SInt64)start_ms * RATE / 1000);
  // The ring buffer, as the engine's own code makes one, with no lock: only the stream player's
  // thread moves its positions (here and in AdvanceReadOffset).
  const uint64_t ring = PG_FN_OPERATOR_NEW(instance, 80), data = PG_FN_OPERATOR_NEW(instance, RING_BYTES);
  uint8_t *fields = memoryAt(instance, ring, 80), *bytes = memoryAt(instance, data, RING_BYTES);
  if (!fields || !bytes) { ExtAudioFileDispose(file); return 0; }
  memset(fields, 0, 80); memset(bytes, 0, RING_BYTES);
  const uint32_t size = RING_BYTES, references = 1;
  memcpy(fields + RING_DATA, &data, 8); memcpy(fields + RING_SIZE, &size, 4); memcpy(fields + RING_REFERENCES, &references, 4);
  fields[RING_LOCKED] = 0;
  Stream *stream = calloc(1, sizeof *stream);
  stream->reader = reader; stream->ring = ring; stream->file = file; stream->lengthMs = lengthMs;
  stream->decoded = malloc(DECODED_BYTES);
  snprintf(stream->name, sizeof stream->name, "%s", name);
  memcpy(readerFields, &ring, 8);
  atomic_store((_Atomic uint32_t *)(void *)(readerFields + READER_STATE), READY);
  memcpy(trackReader, &reader, 8);
  pthread_mutex_lock(&streamsLock);
  stream->next = streams; streams = stream; atomic_fetch_add(&streamCount, 1);
  pthread_mutex_unlock(&streamsLock);
  pthread_create(&stream->thread, NULL, decodeSong, stream);
  char line[PATH_MAX + 96]; snprintf(line, sizeof line, "Self Radio: playing %s (%u:%02u) from %u:%02u.", name, lengthMs / 60000, lengthMs / 1000 % 60, start_ms / 60000, start_ms / 1000 % 60);
  pg_log(line);
  return 1;
}

static uint32_t lengthOf(uint64_t reader) {
  uint32_t length = 0;
  pthread_mutex_lock(&streamsLock);
  for (Stream *s = streams; s; s = s->next) if (s->reader == reader) length = s->lengthMs;
  pthread_mutex_unlock(&streamsLock);
  return length;
}
// The song's length in ms where Prepare asks the decoder; -1 as before for a reader that isn't ours.
u32 pg_user_music_length(w2c_game *instance, u64 reader) { uint32_t length = lengthOf(reader); return length ? length : (u32)-1; }
// Play and Update ask the decoder for the sample rate to start the stream player with.
u32 pg_user_music_rate(w2c_game *instance, u64 reader) { return lengthOf(reader) ? RATE : (u32)-1; }

// audMediaReader::Close: stops the song's decoding before the engine lets go of the ring buffer.
void pg_user_music_close(w2c_game *instance, u64 reader) {
  if (!atomic_load(&streamCount)) return;
  pthread_mutex_lock(&streamsLock);
  Stream *stream = NULL;
  for (Stream **link = &streams; *link; link = &(*link)->next)
    if ((*link)->reader == reader) { stream = *link; *link = stream->next; atomic_fetch_sub(&streamCount, 1); break; }
  pthread_mutex_unlock(&streamsLock);
  if (!stream) return;
  atomic_store(&stream->stop, true);
  pthread_join(stream->thread, NULL);
  ExtAudioFileDispose(stream->file);
  char line[160]; snprintf(line, sizeof line, "Self Radio: stopped %s after %.0f s.", stream->name, (double)atomic_load(&stream->fed) / (RATE * FRAME_BYTES));
  pg_log(line);
  free(stream->decoded);
  free(stream);
}

// A song is audible when the stream player took some of it in the last second.
static _Atomic double lastFed;
bool PGSelfRadioAudible(void) {
  struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
  return atomic_load(&streamCount) && now.tv_sec + now.tv_nsec / 1e9 - atomic_load(&lastFed) < 1.0;
}
// The radio wheel's Next track on PC (CRadioWheel::Update, NextTrackCB): the audio engine's next-track request
// (15938284), which it takes in any order but "like a radio station" (19566784 = 0), after 2 s of the song.
static w2c_game *pumpInstance;
void PGSelfRadioNext(void) {
  w2c_game *instance = pumpInstance;
  if (!instance || !PGSelfRadioAudible()) return;
  uint8_t *mode = memoryAt(instance, 19566784, 4), *request = memoryAt(instance, 15938284, 1);
  if (!mode || !request || !*(uint32_t *)(void *)mode) { pg_log("Self Radio: Next song works in shuffle and in order (Settings › Self Radio)."); return; }
  *(_Atomic uint8_t *)(void *)request = 1;
  pg_log("Self Radio: next song.");
}

// audStreamPlayer::GenerateFrame, before it reads its ring buffer (player +48): when that is a
// song's, moves what has been decoded into the ring buffer's free space; after the song's end,
// silence until the station moves on.
void pg_user_music_pump(w2c_game *instance, u64 player) {
  if (!atomic_load(&streamCount)) return;
  uint8_t *fields = memoryAt(instance, player + 48, 8);
  if (!fields) return;
  uint64_t ring; memcpy(&ring, fields, 8);
  if (!ring || pthread_mutex_trylock(&streamsLock)) return;
  Stream *stream = streams;
  while (stream && stream->ring != ring) stream = stream->next;
  uint8_t *header = stream ? memoryAt(instance, ring, 80) : NULL;
  if (header) {
    uint64_t data; uint32_t size, write; memcpy(&data, header + RING_DATA, 8); memcpy(&size, header + RING_SIZE, 4);
    write = atomic_load((_Atomic uint32_t *)(void *)(header + RING_WRITE));
    _Atomic uint32_t *waiting = (_Atomic uint32_t *)(void *)(header + RING_WAITING);
    uint8_t *bytes = size && write < size ? memoryAt(instance, data, size) : NULL;
    const uint32_t space = bytes ? (size - atomic_load(waiting)) & ~3u : 0;
    const uint64_t read = atomic_load(&stream->read), ready = atomic_load(&stream->written) - read;
    const bool silence = !ready && atomic_load(&stream->ended);
    uint32_t moved = (uint32_t)(silence ? space : ready < space ? ready : space);
    int32_t peak = atomic_load(&stream->peak);
    for (uint32_t done = 0; done < moved;) {
      const uint32_t at = (write + done) % size, run = moved - done < size - at ? moved - done : size - at;
      if (silence) memset(bytes + at, 0, run);
      else {
        uint64_t from = (read + done) % DECODED_BYTES, part = run < DECODED_BYTES - from ? run : DECODED_BYTES - from;
        memcpy(bytes + at, stream->decoded + from, part);
        memcpy(bytes + at + part, stream->decoded, run - part);
        for (uint32_t k = 0; k < run; k += 2) { int16_t v; memcpy(&v, bytes + at + k, 2); int32_t a = v < 0 ? -v : v; if (a > peak) peak = a; }
      }
      done += run;
    }
    if (moved) {
      atomic_store((_Atomic uint32_t *)(void *)(header + RING_WRITE), (write + moved) % size);
      atomic_fetch_add(waiting, moved);
      if (!silence) {
        atomic_store(&stream->read, read + moved); atomic_fetch_add(&stream->fed, moved); atomic_store(&stream->peak, peak);
        struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now); atomic_store(&lastFed, now.tv_sec + now.tv_nsec / 1e9);
        pumpInstance = instance;
      }
    }
  }
  pthread_mutex_unlock(&streamsLock);
}
