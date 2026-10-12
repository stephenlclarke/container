#!/usr/bin/env python3
"""Check original formatting, licenses and regenerated protocols without a SwiftPM host build."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

from builder_artifact import source_pin
from fork_benchmark import BAZEL, PAIRS, ROOT, STORAGE, Runner, archive, digest, install_signal_handlers
from release_artifact import run_command
from runtime_benchmark import build_environment


def run(evidence: Path) -> None:
    evidence.mkdir(parents=True, exist_ok=False)
    runner = Runner(evidence, STORAGE)
    result = {'passed': False, 'failures': []}
    try:
        run_command(runner, 'license-tool', ['bash', 'scripts/install-hawkeye.sh'])
        hawkeye = ROOT / '.local/bin/hawkeye'
        version = subprocess.check_output([str(hawkeye), '--version'], text=True, timeout=10)
        if 'version: 6.5.1\n' not in version:
            raise RuntimeError('Maintenance requires the repository-pinned hawkeye 6.5.1')
        run_command(runner, 'format-licenses', ['make', 'check', 'HAWKEYE=' + str(hawkeye)])
        protoc = ROOT / '.local/bin/protoc@26.1/protoc'
        run_command(runner, 'protoc', ['make', str(protoc)])
        version = subprocess.check_output([str(protoc), '--version'], text=True, timeout=10).strip()
        if version != 'libprotoc 26.1':
            raise RuntimeError('Unexpected protoc version: ' + version)
        targets = ['@swiftpkg_swift_protobuf//:protoc-gen-swift.rspm',
                   '@swiftpkg_grpc_swift_protobuf//:protoc-gen-grpc-swift-2.rspm']
        run_command(runner, 'protocol-generators', [str(ROOT / 'Tools/bazel/run.sh'), 'build', *targets], 900)
        bazel = [str(BAZEL), '--output_user_root=' + str(STORAGE / 'output')]
        env = build_environment()
        execution = Path(subprocess.check_output(bazel + ['info', 'execution_root'], cwd=ROOT, env=env,
                                                text=True, timeout=60).strip())
        files = subprocess.check_output(bazel + ['cquery', 'set(' + ' '.join(targets) + ')', '--output=files'],
                                        cwd=ROOT, env=env, text=True, timeout=60).splitlines()
        products = {Path(p).name.removesuffix('.rspm.__impl'): execution / p
                    for p in files if p.endswith('.rspm.__impl')}
        source = evidence / 'builder-source'
        revision = source_pin()
        archive(PAIRS['container-builder-shim']['repo'], revision, source, ['pkg/api/Builder.proto'])
        generated = evidence / 'generated'
        generated.mkdir()
        run_command(runner, 'generate-protocols', [str(protoc), str(source / 'pkg/api/Builder.proto'),
                    '--proto_path=' + str(source / 'pkg/api'),
                    '--plugin=protoc-gen-grpc-swift=' + str(products['protoc-gen-grpc-swift-2']),
                    '--plugin=protoc-gen-swift=' + str(products['protoc-gen-swift']),
                    '--grpc-swift_out=' + str(generated), '--grpc-swift_opt=Visibility=Public',
                    '--swift_out=' + str(generated), '--swift_opt=Visibility=Public'])
        config = (ROOT / 'licenserc.toml').read_text().replace("attrs = 'enable'", "attrs = 'disable'")
        config = config.replace("ignore = 'enable'", "ignore = 'disable'")
        (generated / 'licenserc.toml').write_text(config)
        (generated / 'scripts').mkdir()
        for name in ('license-header.txt', 'container-header-style.toml'):
            shutil.copy2(ROOT / 'scripts' / name, generated / 'scripts' / name)
        row = runner.run('maintenance', 'fork', 'protocol-licenses', 0,
                         [str(hawkeye), 'format', '--fail-if-unknown', '--fail-if-updated', 'false'], generated, 60)
        if row['status']:
            raise RuntimeError('Generated protocol license check failed')
        outputs = sorted(generated.glob('*.swift'))
        if len(outputs) != 2:
            raise RuntimeError('Expected the two Builder protocol outputs')
        changed = []
        for path in outputs:
            original = (ROOT / 'Sources/ContainerBuild' / path.name).read_text()
            # The isolated generation directory has no historical Git years.
            # Preserve only that already-validated header line; compare all code.
            copyright_line = re.search(r'^// Copyright .+$', original, re.M)
            text = re.sub(r'^// Copyright .+$', lambda _: copyright_line[0], path.read_text(), count=1, flags=re.M)
            path.write_text(text)
            if text != original:
                changed.append(path.name)
        if changed:
            raise RuntimeError('Generated protocols differ: ' + ', '.join(changed))
        result.update(passed=True, builder_source=revision,
                      tools={str(p): digest(p) for p in [hawkeye, protoc, *products.values()]},
                      generated={p.name: digest(p) for p in outputs})
    except BaseException as error:
        result['failures'].append(str(error))
        raise
    finally:
        (evidence / 'maintenance.json').write_text(json.dumps(result, indent=2) + '\n')


def main() -> None:
    install_signal_handlers()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    run(parser.parse_args().evidence)


if __name__ == '__main__':
    main()
