// SEH scopes for the runtime self-test (GTA-188): __try/__finally and __try/__except around a C++ throw, compiled
// as C so clang emits __C_specific_handler scope tables.
int sehThrough(void (*fn)(void), int *finallyRan) {
  __try { fn(); }
  __finally { *finallyRan = 1; }
  return 0;
}
int sehCatch(void (*fn)(void)) {
  __try { fn(); }
  __except (1) { return 1; }
  return 0;
}
