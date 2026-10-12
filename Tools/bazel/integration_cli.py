#!/usr/bin/env python3
"""Record integration CLI ownership, then preserve its process identity with exec."""

import json
import os
from pathlib import Path
import subprocess
import sys


def main() -> None:
    executable = os.environ['CLITEST_REAL_CLI']
    directory = Path(os.environ['CLITEST_PROCESS_DIRECTORY'])
    pid = os.getpid()
    started = subprocess.check_output(['ps', '-p', str(pid), '-o', 'lstart='],
                                      env=dict(os.environ, TZ='UTC'), text=True, timeout=10).strip()
    record = directory / (str(pid) + '.json')
    temporary = record.with_suffix('.tmp')
    temporary.write_text(json.dumps({'pid': pid, 'started': started, 'executable': executable}) + '\n')
    temporary.replace(record)
    environment = dict(os.environ)
    if environment.get('CLITEST_RUNTIME_PROFILE'):
        environment['LLVM_PROFILE_FILE'] = environment['CLITEST_RUNTIME_PROFILE']
    os.execve(executable, [executable, *sys.argv[1:]], environment)


if __name__ == '__main__':
    main()
