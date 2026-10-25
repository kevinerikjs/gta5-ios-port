// Runs script mods (.asi) on a Mac without the game (GTA-188): Source/NativeASI.c and Blink on a plain block of
// guest memory, to test the Windows C/C++ runtime layer (DllMain and the CRT start-up, C++ exceptions, stdio, the
// C++ library) in seconds instead of a simulator run. Game commands all answer "not in this game version" and no
// key is ever down. Build and run with Tests/asi_crt/run_host.sh.
//
//   asi_host <mod.asi> <its folder> [frames] [key code] [frame to press it at, default 10]
#include "NativeASI.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static uint8_t *memoryBase;
static const uint64_t memorySize = 3ull << 30;
static uint64_t top = 0x100000;  // guest addresses below 64 KB are never valid (Blink's pg_blink_low)
static uint64_t bins[48];        // freed blocks by power-of-two size: a 16-byte header keeps the bin
static int binOf(uint64_t size) { int b = 5; while ((1ull << b) < size + 16) b++; return b; }
static uint64_t hostAlloc(uint64_t size) {
  int b = binOf(size); uint64_t block;
  if (bins[b]) { block = bins[b]; memcpy(&bins[b], memoryBase + block + 16, 8); }
  else { block = top; top += 1ull << b; if (top > memorySize) { fprintf(stderr, "asi_host: out of guest memory\n"); return 0; } }
  uint64_t bin = (uint64_t)b; memcpy(memoryBase + block, &bin, 8);
  return block + 16;
}
static void hostFree(uint64_t address) {
  if (!address) return;
  uint64_t block = address - 16, b; memcpy(&b, memoryBase + block, 8);
  if (b < 5 || b >= 48) { fprintf(stderr, "asi_host: bad free of 0x%llx\n", (unsigned long long)address); return; }
  memcpy(memoryBase + block + 16, &bins[b], 8); bins[b] = block;
}
static void hostLog(const char *line) { printf("%s\n", line); fflush(stdout); }
// ASI_HOST_NATIVES_ONE: every game command answers 1 (so "is it loaded" loops end), instead of "not in this version".
static bool hostNative(uint64_t hash, uint64_t arguments, uint32_t count, uint64_t result) {
  (void)hash; (void)arguments; (void)count;
  static int one = -1; if (one < 0) one = getenv("ASI_HOST_NATIVES_ONE") != 0;
  if (!one) return false;
  // ASI_HOST_TEXT: show the text mods draw (ADD_TEXT_COMPONENT_SUBSTRING_PLAYER_NAME).
  if (hash == 0x6c188be134e074aaull && count && getenv("ASI_HOST_TEXT")) { uint64_t at; memcpy(&at, memoryBase + arguments, 8); printf("asi_host: text \"%s\"\n", at ? (char *)memoryBase + at : "(null)"); }
  uint64_t v = 1; memcpy(memoryBase + result, &v, 8); return true;
}
static int pressed;
static bool hostKey(int key) { return key == pressed; }
void PGMeshTouch(const void *start, uint64_t length) { (void)start; (void)length; }

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: asi_host <mod.asi> <its folder> [frames] [key] [frame]\n"); return 2; }
  int frames = argc > 3 ? atoi(argv[3]) : 60, key = argc > 4 ? (int)strtol(argv[4], 0, 0) : 0, at = argc > 5 ? atoi(argv[5]) : 10;
  memoryBase = mmap(0, memorySize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
  if (memoryBase == MAP_FAILED) { perror("mmap"); return 1; }
  PGAsiHost host = {memoryBase, memorySize, hostAlloc, hostFree, hostLog, hostNative, 0, hostKey, 0, 2189, argv[2]};
  if (!pg_asi_init(&host)) { fprintf(stderr, "asi_host: the interpreter did not start\n"); return 1; }
  int fd = open(argv[1], O_RDONLY); struct stat st;
  if (fd < 0 || fstat(fd, &st)) { perror(argv[1]); return 1; }
  uint8_t *bytes = malloc((size_t)st.st_size);
  if (read(fd, bytes, (size_t)st.st_size) != st.st_size) { perror("read"); return 1; }
  close(fd);
  const char *name = strrchr(argv[1], '/'); name = name ? name + 1 : argv[1];
  if (!pg_asi_load(name, argv[2], bytes, (uint64_t)st.st_size)) { printf("asi_host: %s did not load\n", name); return 1; }
  uint64_t total = 0, spent = 0;
  for (int frame = 0; frame < frames; frame++) {
    if (key && frame == at) { pressed = key; pg_asi_key(key, true); printf("asi_host: key 0x%x down\n", key); }
    if (key && frame == at + 6) { pressed = 0; pg_asi_key(key, false); printf("asi_host: key 0x%x up\n", key); }
    pg_asi_tick(); usleep(16000);
    uint64_t us, count; pg_asi_stats(&us, &count); total += count; spent += us;
    if (frame % 60 == 59) { printf("asi_host: frames %d-%d: %llu million instructions, %llu ms in the interpreter\n", frame - 59, frame, (unsigned long long)(total / 1000000), (unsigned long long)(spent / 1000)); total = spent = 0; }
  }
  uint64_t us, instructions; pg_asi_stats(&us, &instructions);
  printf("asi_host: %d frames; the last took %llu us, %llu instructions; guest heap top %llu MB\n", frames, (unsigned long long)us, (unsigned long long)instructions, (unsigned long long)(top >> 20));
  return 0;
}
