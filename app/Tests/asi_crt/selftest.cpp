// Self-test for the Windows C/C++ runtime of the script mod layer (GTA-188): a script mod built with clang for
// x86_64-pc-windows-msvc against the DLL runtime (/MD style imports), checking what NativeASIRuntime.inc answers:
// printf/scanf formatting, number conversions, stdio, qsort, _initterm, and C++ exceptions (destructors on the
// way, catch by value/reference/base class, catch (...), rethrow, a throw from a catch block, catch blocks that wait,
// exceptions through runtime callbacks, std exceptions the runtime throws, dynamic_cast, SEH __finally/__except).
// Results go to stdout, which the layer writes to the log as "ASI console:" lines; the last line says
// "SELFTEST DONE: n checks, m failures". Two more scripts end on purpose: an uncaught exception and a noexcept
// violation each stop only their own script, with a log line.
// Build: Tests/asi_crt/build_selftest.sh (no Windows headers or libraries needed).
typedef unsigned long long size_t;
typedef char *va_list;
#define va_start(v, l) __builtin_va_start(v, l)
#define va_end(v) __builtin_va_end(v)
struct FILE;
extern "C" {
__declspec(dllimport) void *malloc(size_t);
__declspec(dllimport) void free(void *);
__declspec(dllimport) int __stdio_common_vsprintf(unsigned long long, char *, size_t, const char *, void *, va_list);
__declspec(dllimport) int __stdio_common_vsprintf_s(unsigned long long, char *, size_t, const char *, void *, va_list);
__declspec(dllimport) int __stdio_common_vsscanf(unsigned long long, const char *, size_t, const char *, void *, va_list);
__declspec(dllimport) FILE *__acrt_iob_func(unsigned);
__declspec(dllimport) int fputs(const char *, FILE *);
__declspec(dllimport) FILE *fopen(const char *, const char *);
__declspec(dllimport) int fclose(FILE *);
__declspec(dllimport) size_t fread(void *, size_t, size_t, FILE *);
__declspec(dllimport) size_t fwrite(const void *, size_t, size_t, FILE *);
__declspec(dllimport) int fgetc(FILE *);
__declspec(dllimport) int ungetc(int, FILE *);
__declspec(dllimport) char *fgets(char *, int, FILE *);
__declspec(dllimport) int fseek(FILE *, long, int);
__declspec(dllimport) long ftell(FILE *);
__declspec(dllimport) int feof(FILE *);
__declspec(dllimport) int _get_stream_buffer_pointers(FILE *, char ***, char ***, int **);
__declspec(dllimport) long strtol(const char *, char **, int);
__declspec(dllimport) unsigned long strtoul(const char *, char **, int);
__declspec(dllimport) long long strtoll(const char *, char **, int);
__declspec(dllimport) double strtod(const char *, char **);
__declspec(dllimport) float strtof(const char *, char **);
__declspec(dllimport) int atoi(const char *);
__declspec(dllimport) int *_errno(void);
__declspec(dllimport) int strcmp(const char *, const char *);
__declspec(dllimport) size_t strlen(const char *);
__declspec(dllimport) void qsort(void *, size_t, size_t, int (*)(const void *, const void *));
__declspec(dllimport) void _initterm(void (**)(void), void (**)(void));
__declspec(dllimport) int remove(const char *);
__declspec(dllimport) double sin(double);
__declspec(dllimport) float atan2f(float, float);
__declspec(dllimport) void scriptRegister(void *, void (*)());
__declspec(dllimport) void __std_exception_destroy(void *);
__declspec(dllimport) void scriptWait(unsigned);
int sehThrough(void (*)(), int *);  // selftest_seh.c
int sehCatch(void (*)());
}
namespace std {  // the parts of the library's types a catch needs: the decorated names and what() in the vtable
class exception {  // as in <exception>: what() and the destructor are inline, over __std_exception_data
public:
  exception() : what_(0), free_(false) {}
  virtual ~exception() { __std_exception_destroy(&what_); }
  virtual const char *what() const { return what_ ? what_ : "Unknown exception"; }
private:
  const char *what_; bool free_;
};
__declspec(dllimport) void __cdecl _Xout_of_range(const char *);
__declspec(dllimport) void __cdecl _Xlength_error(const char *);
}
#define stdout __acrt_iob_func(1)
void *operator new(size_t n) { return malloc(n); }  // Visual Studio links these into each mod
void operator delete(void *p) noexcept { free(p); }
void operator delete(void *p, size_t) noexcept { free(p); }

static int checks, failures;
static char line[600];
static void say(const char *format, ...) {
  va_list a; va_start(a, format); __stdio_common_vsprintf(2, line, sizeof line, format, 0, a); va_end(a);
  fputs(line, stdout); fputs("\n", stdout);
}
static void check(bool ok, const char *what) { checks++; if (!ok) { failures++; say("SELFTEST FAIL: %s", what); } }
static char out[256];
static int fmt(const char *format, ...) { va_list a; va_start(a, format); int n = __stdio_common_vsprintf(2, out, sizeof out, format, 0, a); va_end(a); return n; }
static void fmtIs(const char *want) { checks++; if (strcmp(out, want)) { failures++; say("SELFTEST FAIL: printf gave [%s], wanted [%s]", out, want); } }
static int sprintfWith(unsigned long long options, char *b, size_t size, const char *f, ...) { va_list a; va_start(a, f); int r = __stdio_common_vsprintf(options, b, size, f, 0, a); va_end(a); return r; }
static int sprintfS(char *b, size_t size, const char *f, ...) { va_list a; va_start(a, f); int r = __stdio_common_vsprintf_s(0, b, size, f, 0, a); va_end(a); return r; }
static int scan(const char *in, const char *format, ...) { va_list a; va_start(a, format); int n = __stdio_common_vsscanf(0, in, (size_t)-1, format, 0, a); va_end(a); return n; }

static void testPrintf() {
  fmt("%d|%i|%u|%x|%X", -5, 42, 3000000000u, 255, 255); fmtIs("-5|42|3000000000|ff|FF");
  fmt("%5d|%-5d|%05d|%+d|% d", 42, 42, 42, 42, 42); fmtIs("   42|42   |00042|+42| 42");
  fmt("%f|%.2f|%10.3f|%-8.1f|%e|%g|%g", 3.14159, 2.5, 3.14159, 1.5, 12345.678, 0.0001, 100000.0); fmtIs("3.141590|2.50|     3.142|1.5     |1.234568e+04|0.0001|100000");
  fmt("%s|%.3s|%10s|%-6s|%*d|%.*f", "hello", "abcdef", "right", "left", 4, 7, 1, 2.25); fmtIs("hello|abc|     right|left  |   7|2.2");
  fmt("%ls|%S|%c%c|%lc", L"wide", L"WIDE", 'a', 'b', L'z'); fmtIs("wide|WIDE|ab|z");
  fmt("%p", (void *)0x1234ABCDull); fmtIs("000000001234ABCD");
  fmt("%lld|%llu|%I64d|%zu|%ld|%lu", -9000000000LL, 18000000000000000000ULL, 123456789012LL, (size_t)77, -2147483647L, 4294967295UL);
  fmtIs("-9000000000|18000000000000000000|123456789012|77|-2147483647|4294967295");
  fmt("%hd|%hhd|%hu|%#x|%#o|%%|%.0f|%s", 70000, 300, 70000, 255, 8, 2.75, (char *)0); fmtIs("4464|44|4464|0xff|010|%|3|(null)");
  int n = fmt("%s", "a long string"); check(n == 13, "printf's result is its length");
  char small[5];
  n = sprintfWith(2, small, 5, "%s", "abcdefgh"); check(n == 8 && !strcmp(small, "abcd"), "snprintf truncates and returns the full length");
  n = sprintfWith(1, small, 5, "%s", "abcdefgh"); check(n == -1 && small[4] == 'e', "_vsnprintf returns -1 when the text doesn't fit");
  n = sprintfS(small, 4, "%s", "abcd"); check(n == -1 && small[0] == 0, "sprintf_s empties a buffer that is too small");
  fmt("%.3f|%g|%g", sin(1.0), (double)atan2f(1.0f, 1.0f), 1e-20); fmtIs("0.841|0.785398|1e-20");
}
static void testScanf() {
  int a = 0, b = 0, h = 0; float f = 0; char s[16] = ""; double d = 0; long long q = 0; unsigned char c = 0; int used = 0;
  check(scan("42 -17 3.5 hello 0x1F", "%d %d %f %s %x", &a, &b, &f, s, &h) == 5 && a == 42 && b == -17 && f == 3.5f && !strcmp(s, "hello") && h == 31, "sscanf numbers, a word, hex");
  check(scan("12,34", "%d,%d", &a, &b) == 2 && a == 12 && b == 34, "sscanf with a literal comma");
  check(scan("abc", "%d", &a) == 0, "sscanf stops at a mismatch");
  check(scan("", "%d", &a) == -1, "sscanf of empty input returns EOF");
  char k[16], v[16];
  check(scan("key=value", "%[^=]=%s", k, v) == 2 && !strcmp(k, "key") && !strcmp(v, "value"), "sscanf scan set");
  check(scan("2.5 -9000000000 200x", "%lf %lld %hhu%n", &d, &q, &c, &used) == 3 && d == 2.5 && q == -9000000000LL && c == 200 && used == 19, "sscanf %lf %lld %hhu %n");
}
static void testConvert() {
  char *end; *_errno() = 0;
  check(strtol("2147483648", &end, 10) == 2147483647L && *_errno() == 34, "strtol clamps to 32 bits with ERANGE");
  check(strtol("-0x1F zz", &end, 0) == -31 && !strcmp(end, " zz"), "strtol base 0 hex and its end");
  check(strtoul("-1", &end, 10) == 4294967295UL, "strtoul of -1");
  *_errno() = 0; check(strtoll("9223372036854775808", &end, 10) == 9223372036854775807LL && *_errno() == 34, "strtoll overflow");
  check(strtod("1.5e3xyz", &end) == 1500.0 && !strcmp(end, "xyz"), "strtod and its end");
  check(strtof("3.25", 0) == 3.25f && atoi("  -12abc") == -12, "strtof, atoi");
  check(strtol("junk", &end, 10) == 0 && !strcmp(end, "junk"), "strtol without digits leaves end at the start");
}
static void testStdio() {
  FILE *w = fopen("C:\\GTA5\\selftest-file.txt", "w");
  check(w != 0, "fopen for writing");
  if (!w) return;
  fputs("line one\nline two\n", w); fclose(w);
  FILE *r = fopen("selftest-file.txt", "rb"); char buf[64] = "";
  size_t n = fread(buf, 1, sizeof buf - 1, r); buf[n] = 0; fclose(r);
  check(n == 20 && !strcmp(buf, "line one\r\nline two\r\n"), "text mode writes \\r\\n");
  r = fopen("selftest-file.txt", "r");
  check(fgets(buf, sizeof buf, r) && !strcmp(buf, "line one\n"), "text mode reads \\n");
  check(ftell(r) == 10, "ftell counts the \\r");
  int ch = fgetc(r); check(ch == 'l' && ungetc(ch, r) == 'l' && fgetc(r) == 'l', "fgetc and ungetc");
  // A file buffer reads the FILE's buffer directly, as basic_filebuf does.
  char **base, **ptr; int *count; _get_stream_buffer_pointers(r, &base, &ptr, &count);
  check(*count > 0 && **ptr == 'i', "the FILE's buffer pointers show the data read ahead");
  (*ptr)++; (*count)--;
  check(fgetc(r) == 'n', "fgetc goes on after the buffer was read directly");
  fseek(r, 0, 2); check(ftell(r) == 20, "fseek to the end");
  check(fgetc(r) == -1 && feof(r), "end of file");
  fclose(r); remove("selftest-file.txt");
  check(fopen("no such file.txt", "r") == 0 && *_errno() == 2, "fopen of a missing file: ENOENT");
}
static int compareInts(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }
static int compareThrows(const void *a, const void *b) { if (*(const int *)a == 3 || *(const int *)b == 3) throw 33; return compareInts(a, b); }
static int initCount;
static void initOne() { initCount++; }
static void initThrows() { throw 77; }

// C++ exceptions.
static int liveObjects, destroyed;
static char order[64]; static int orderLength;
static void mark(char c) { if (orderLength < 63) order[orderLength++] = c; order[orderLength] = 0; }
struct Tracker { char name; Tracker(char n) : name(n) { liveObjects++; } ~Tracker() { liveObjects--; destroyed++; mark(name); } };
struct Error { int code; char text[16]; Error(int c) : code(c) { text[0] = 'E'; text[1] = 0; liveObjects++; } Error(const Error &e) : code(e.code) { text[0] = e.text[0]; text[1] = 0; liveObjects++; } ~Error() { liveObjects--; } };
struct Base { int v; Base(int x) : v(x) {} virtual ~Base() {} virtual int kind() const { return 1; } };
struct Derived : Base { Derived(int x) : Base(x) {} int kind() const override { return 2; } };
__declspec(noinline) static void throwInt(int v) { Tracker t('t'); if (v) throw v; }
__declspec(noinline) static void throwError(int v) { Tracker t('e'); throw Error(v); }
__declspec(noinline) static void rethrowing() { try { throwError(5); } catch (Error &) { mark('r'); throw; } }
__declspec(noinline) static void throwFromCatch() { try { throwInt(1); } catch (int) { Tracker inCatch('c'); throw Error(9); } }
static void throwForSeh() { throw 123; }
struct B1 { virtual ~B1() {} int a = 1; };
struct B2 { virtual ~B2() {} int b = 2; };
struct D : B1, B2 { int c = 3; };
struct Other { virtual ~Other() {} };

static void testExceptions() {
  orderLength = 0;
  try { Tracker a('a'); Tracker b('b'); throwInt(7); check(false, "throw returned"); }
  catch (int v) { check(v == 7, "catch (int) gets the value"); }
  check(!strcmp(order, "tba"), "destructors run innermost first while unwinding"); check(liveObjects == 0, "no object left alive");
  try { throwError(42); } catch (const Error &e) { check(e.code == 42 && e.text[0] == 'E', "catch by const reference"); }
  check(liveObjects == 0, "the thrown object is destroyed after its catch block");
  try { throwError(43); } catch (Error e) { check(e.code == 43, "catch by value (copy constructor)"); }
  check(liveObjects == 0, "the copy and the thrown object are both destroyed");
  try { throw Derived(6); } catch (Base &b) { check(b.v == 6 && b.kind() == 2, "catch (Base &) of a Derived, virtual call"); }
  try { throw 2.5; } catch (int) { check(false, "a double caught as int"); } catch (...) { check(true, "catch (...)"); }
  orderLength = 0;
  try { rethrowing(); } catch (Error &e) { check(e.code == 5, "rethrow (throw;) reaches the outer catch"); }
  check(!strcmp(order, "er") && liveObjects == 0, "rethrow: one object, destroyed once");
  orderLength = 0;
  try { throwFromCatch(); } catch (Error &e) { check(e.code == 9, "a new exception thrown from a catch block"); }
  check(!strcmp(order, "tc") && liveObjects == 0, "the catch block's objects are destroyed when the new exception leaves it");
  int inner = 0;
  try { throwInt(1); } catch (int) { try { throwInt(2); } catch (int v) { inner = v; } }
  check(inner == 2, "a try block inside a catch block");
  int value = 0;
  try { try { throwInt(3); } catch (int v) { value = v; throw; } } catch (int v) { value += v; }
  check(value == 6, "rethrow to an enclosing try block of the same function");
  int sorted[6] = {5, 1, 4, 2, 6, 0}; qsort(sorted, 6, sizeof(int), compareInts);
  check(sorted[0] == 0 && sorted[1] == 1 && sorted[5] == 6, "qsort with the mod's comparator");
  int thrown = 0, numbers[4] = {1, 3, 2, 4};
  try { qsort(numbers, 4, sizeof(int), compareThrows); } catch (int v) { thrown = v; }
  check(thrown == 33, "an exception from a qsort comparator reaches the mod's catch");
  void (*inits[3])(void) = {initOne, 0, initOne}; initCount = 0; _initterm(inits, inits + 3);
  check(initCount == 2, "_initterm calls the initializers");
  void (*bad[2])(void) = {initOne, initThrows}; thrown = 0;
  try { _initterm(bad, bad + 2); } catch (int v) { thrown = v; }
  check(thrown == 77, "an exception from an initializer reaches the mod's catch");
  try { std::_Xout_of_range("invalid string position"); } catch (const std::exception &e) { check(!strcmp(e.what(), "invalid string position"), "std::out_of_range from the runtime, what()"); }
  try { std::_Xlength_error("too long"); } catch (std::exception e) { check(!strcmp(e.what(), "too long"), "a runtime std exception caught by value"); }
  D *d = new D; B2 *b2 = d; B1 *b1 = d;
  check(dynamic_cast<D *>(b2) == d && dynamic_cast<B1 *>(b2) == b1 && dynamic_cast<Other *>(b1) == 0, "dynamic_cast down, across, and to an unrelated class");
  bool badCast = false; try { (void)dynamic_cast<Other &>(*b1); } catch (std::exception &) { badCast = true; }
  check(badCast, "a failed dynamic_cast to a reference throws std::bad_cast"); delete d;
  int finallyRan = 0; thrown = 0;
  try { sehThrough(throwForSeh, &finallyRan); } catch (int v) { thrown = v; }
  check(thrown == 123 && finallyRan == 1, "a __finally block runs while a C++ exception passes");
  check(sehCatch(throwForSeh) == 1, "__except catches a C++ exception");
}
static void runTests(const char *where) {
  liveObjects = 0;
  testPrintf(); testScanf(); testConvert(); testStdio(); testExceptions();
  say("SELFTEST DONE (%s): %d checks, %d failures", where, checks, failures);
}

// Scripts: the tests again on a script thread with waits inside catch blocks, then two that end on purpose.
static void mainScript() {
  checks = failures = 0;
  int got = 0;
  try { scriptWait(0); throwInt(11); } catch (int v) { scriptWait(0); got = v; Tracker waits('w'); scriptWait(0); }
  check(got == 11, "a catch block that waits for the next frame");
  runTests("script");
  for (;;) scriptWait(1000);
}
// These two run while the main script waits in its catch block: they throw plain values (no counted objects).
__declspec(noinline) static void throwPlain(int v) { if (v) throw v; }
static void uncaughtScript() { scriptWait(0); say("SELFTEST: an uncaught exception comes next"); throwPlain(3); }
__declspec(noinline) static void mayNotThrow() noexcept { throwPlain(4); }
static void noexceptScript() { scriptWait(0); say("SELFTEST: a noexcept violation comes next"); mayNotThrow(); }
extern "C" int __stdcall DllMainCRTStartup(void *module, unsigned reason, void *) {
  if (reason != 1) return 1;
  runTests("DllMain");
  scriptRegister(module, mainScript); scriptRegister(module, uncaughtScript); scriptRegister(module, noexceptScript);
  return 1;
}
