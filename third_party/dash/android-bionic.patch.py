from pathlib import Path
import sys
root = Path(sys.argv[1])
jobs = root / 'src' / 'jobs.c'
text = jobs.read_text()
old = 'waitpid((pid_t)-1, status, flags, NULL)'
new = 'waitpid((pid_t)-1, status, flags)'
if old not in text:
    sys.exit('missing waitpid in ' + str(jobs))
jobs.write_text(text.replace(old, new, 1))
print('patched', jobs)
