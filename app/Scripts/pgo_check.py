"""Does the PGO profile still match the code? (GTA-216)

A profile-guided build (PG_PGO_PROFILE) leaves one warning per source file whose functions changed since the profile
was made: "profile data may be out of date: of N functions, M have mismatched data that will be ignored". A stale
profile does no harm to correctness, but the changed functions lose the optimization, and the order file no longer
names the hot code. This sums the warnings of a build log and fails when more than PG_PGO_MAX_MISMATCH percent
(default 3) of the profiled functions changed: refresh the profile then (Scripts/pgo.sh gen, train, merge on the
code being released; RELEASE-CHECKLIST.md).

    python3 Scripts/pgo_check.py Build/xcodebuild.log
"""
import os, re, subprocess, sys
text = open(sys.argv[1], errors='replace').read()
files = {}
for m in re.finditer(r'(\S+\.(?:c|m|mm|cc|cpp)):\d+:\d+: warning: profile data may be out of date: of (\d+) functions?, (\d+) (?:has|have) mismatched data', text):
    files[m.group(1)] = (int(m.group(2)), int(m.group(3)))
changed = sum(m for _, m in files.values())
# Files whose functions all match print nothing, so the share is of every function in the profile.
total = 0
profile = os.environ.get('PG_PGO_PROFILE')
if profile:
    show = subprocess.run(['xcrun', 'llvm-profdata', 'show', profile], capture_output=True, text=True).stdout
    m = re.search(r'Total functions: (\d+)', show)
    total = int(m.group(1)) if m else 0
if not total: total = sum(n for n, _ in files.values())
limit = float(os.environ.get('PG_PGO_MAX_MISMATCH', '3'))
if 'fprofile-instr-use' not in text:
    print('PGO check: the build log shows no profile use'); sys.exit(1)
share = changed * 100 / total if total else 0
worst = sorted(files.items(), key=lambda kv: -kv[1][1])[:5]
print(f'PGO check: {changed} of {total} profiled functions changed since the profile was made ({share:.1f}%, limit {limit}%) in {len(files)} files'
      + (f'; most in {", ".join(f"{os.path.basename(f)} {m}" for f, (n, m) in worst)}' if worst else ''))
if share > limit:
    print('PGO check: STOP. The profile no longer matches the code. Refresh it (Scripts/pgo.sh gen, train, merge) or build without PG_PGO_PROFILE.')
    sys.exit(1)
