#!/usr/bin/env python3
"""Build the original API documentation from Bazel symbol graphs without SwiftPM compilation."""

import argparse
import json
from pathlib import Path
import re
import shutil
import tempfile

from fork_benchmark import BAZEL, ROOT, STORAGE, Runner, digest, install_signal_handlers
from runtime_benchmark import build_environment, checked


def build(evidence: Path) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    runner = Runner(evidence, STORAGE)
    result = {'passed': False, 'failures': []}
    try:
        row = runner.run('docs', 'fork', 'symbols', 0,
                         [str(ROOT / 'Tools/bazel/run.sh'), 'build', '//:api-symbol-graphs'], ROOT, 1800)
        if row['status']:
            raise RuntimeError('API symbol extraction failed')
        bazel = [str(BAZEL), '--output_user_root=' + str(STORAGE / 'output')]
        environment = build_environment()
        execution = Path(checked(bazel + ['info', 'execution_root'], cwd=ROOT, env=environment))
        files = checked(bazel + ['cquery', '//:api-symbol-graphs', '--output=files'], cwd=ROOT, env=environment).splitlines()
        symbols = execution / next(path for path in files if path.endswith('.symbolgraphs'))
        # Reuse the original documented module list, so newly added native docs cannot silently disappear.
        modules = re.findall(r'opts\+=\("--target" "([^"]+)"\)', (ROOT / 'scripts/make-docs.sh').read_text())
        if not modules:
            raise RuntimeError('Original documentation recipe contains no modules')
        result['modules'] = modules
        result['symbols'] = {path.name: digest(path) for path in symbols.glob('*.json')}
        with tempfile.TemporaryDirectory(prefix='api-docs-', dir=STORAGE / 'tmp') as temporary:
            work = Path(temporary)
            archives = []
            for module in modules:
                graph = symbols / (module + '.symbols.json')
                if not graph.is_file() or not json.loads(graph.read_text()).get('symbols'):
                    raise RuntimeError('Missing or empty API symbol graph: ' + module)
                inputs = work / module
                inputs.mkdir()
                for path in symbols.glob(module + '*.symbols.json'):
                    if path.name == graph.name or path.name.startswith(module + '@'):
                        shutil.copy2(path, inputs / path.name)
                archive = work / (module + '.doccarchive')
                row = runner.run('docs', 'fork', module, 0,
                                 ['xcrun', 'docc', 'convert', '--additional-symbol-graph-dir', str(inputs),
                                  '--output-path', str(archive), '--fallback-display-name', module,
                                  '--fallback-bundle-identifier', 'io.github.stephenlclarke.' + module,
                                  '--transform-for-static-hosting',
                                  '--hosting-base-path', 'container', '--experimental-documentation-coverage'], ROOT, 120)
                if row['status']:
                    raise RuntimeError('API documentation conversion failed: ' + module)
                archives.append(str(archive))
            row = runner.run('docs', 'fork', 'merge', 0,
                             ['xcrun', 'docc', 'merge', *archives, '--output-path', str(evidence / 'container.doccarchive')], ROOT, 120)
            if row['status']:
                raise RuntimeError('Combined documentation failed')
        result['passed'] = True
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        (evidence / 'documentation.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', required=True, type=Path)
    build(parser.parse_args().evidence)
