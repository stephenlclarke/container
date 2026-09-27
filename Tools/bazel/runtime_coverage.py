#!/usr/bin/env python3
"""Collect runtime line coverage without leaving profiling binaries in the release slot."""

import json
from pathlib import Path
import re
import shutil
import tempfile

from coverage import export_reports, line_counts, merge_lcov, run_command, source_files
from fork_benchmark import ROOT, STORAGE, digest
from runtime_benchmark import INSTALLS, PLUGINS, RuntimeRunner, checked, own, stage, stop_owned


def require_idle(installation: Path) -> None:
    if any(path.startswith(str(installation) + '/') for path in checked(['ps', '-axo', 'comm=']).splitlines()):
        raise RuntimeError('Private installation still has active processes; refusing replacement')


def verify_binaries(installation: Path, expected: dict[str, str]) -> None:
    for relative, sha in expected.items():
        if digest(installation / relative) != sha:
            raise RuntimeError('Prepared runtime binary changed: ' + relative)


def validate_runtime_coverage(text: str, full_suite: bool) -> dict[str, int]:
    required = ['Sources/APIServer/']
    if full_suite:
        required.append('Sources/Services/RuntimeLinux/Server/')
    counts = line_counts(text)
    modules = {prefix: sum(hits > 0 for source, lines in counts.items() if source.startswith(prefix)
                           for hits in lines.values()) for prefix in required}
    if not all(modules.values()):
        raise RuntimeError('Runtime coverage omitted exercised service counters: ' + str(modules))
    return modules


class RuntimeCoverage:
    """The caller holds benchmark.lock and stops its CLI children before finish()."""

    def __init__(self, runner: RuntimeRunner, full_suite: bool) -> None:
        self.runner = runner
        self.evidence = runner.evidence / 'coverage'
        self.evidence.mkdir()
        self.profiles = self.evidence / 'profiles'
        self.profiles.mkdir()
        self.environment = {'LLVM_PROFILE_FILE': str(self.profiles / '%p-%m%c.profraw')}
        self.installation = INSTALLS / 'fork/install'
        self.original = json.loads((runner.evidence / 'fork-fingerprint.json').read_text())
        self.backup: Path | None = None
        self.layer_reports: list[Path] = []
        self.result = dict(passed=False, full_suite=full_suite, failures=[], source_files=source_files(),
                           original_binaries=self.original['binaries'], restored=False)

    def persist(self) -> None:
        (self.evidence / 'coverage.json').write_text(json.dumps(self.result, indent=2) + '\n')

    def prepare(self) -> None:
        revision = checked(['git', 'rev-parse', 'HEAD'], cwd=ROOT)
        self.result['revision'] = revision
        self.runner.env['GIT_COMMIT'] = revision
        self.persist()
        run_command(self.runner, 'build-instrumented-runtime',
                    [str(ROOT / 'Tools/bazel/run.sh'), 'build', '//:container', '--config=runtime-coverage',
                     '--repo_env=GIT_COMMIT=' + revision], 1800)
        stop_owned('fork')
        own(self.installation, 'fork')
        require_idle(self.installation)
        verify_binaries(self.installation, self.original['binaries'])
        temporary = Path(tempfile.mkdtemp(prefix='coverage-install-', dir=self.installation.parent))
        self.result['recovery_directory'] = str(temporary)
        self.persist()
        backup = temporary / 'previous'
        self.installation.rename(backup)
        self.backup = backup
        stage('fork', ROOT, STORAGE / 'output', self.runner.evidence,
              configuration='runtime-coverage', profile_file=str(self.evidence / 'probe-%p-%m%c.profraw'))
        fingerprint = self.runner.evidence / 'fork-fingerprint.json'
        shutil.copy2(fingerprint, self.evidence / fingerprint.name)
        metadata = json.loads(fingerprint.read_text())
        binaries = self.evidence / 'binaries'
        binaries.mkdir()
        names = {'container', 'container-apiserver', 'container-engine', *PLUGINS}
        for relative in metadata['binaries']:
            if Path(relative).name in names:
                shutil.copy2(self.installation / relative, binaries / Path(relative).name)
        if {p.name for p in binaries.iterdir()} != names:
            raise RuntimeError('Instrumented runtime omitted Swift executables')
        self.result['binaries'] = {p.name: digest(p) for p in sorted(binaries.iterdir())}
        self.runner.runtime_environment = self.environment
        self.persist()

    def retain_layer(self, log: Path, layer: str) -> None:
        match = re.search(r'LCOV coverage report is located at (.+)$', log.read_text(), re.M)
        if not match:
            raise RuntimeError('Bazel omitted integration coverage for ' + layer)
        destination = self.evidence / (layer.lower() + '.lcov')
        # Preserve each report now; Bazel overwrites the aggregate on the next layer.
        shutil.copyfile(Path(match[1]), destination)
        if not re.search(r'^DA:[1-9][0-9]*,[1-9][0-9]*(?:,.*)?$', destination.read_text(), re.M):
            raise RuntimeError('Integration layer produced no executed coverage lines: ' + layer)
        self.layer_reports.append(destination)

    def export(self) -> None:
        profiles = sorted(self.profiles.glob('*.profraw'))
        if not profiles or not self.layer_reports:
            raise RuntimeError('Runtime profiles or integration layer coverage are missing')
        if source_files() != self.result['source_files']:
            raise RuntimeError('Sources changed while collecting integration coverage')
        self.result['raw_profiles'] = {p.name: digest(p) for p in profiles}
        merged = self.evidence / 'runtime.profdata'
        inputs = self.evidence / 'profile-inputs.txt'
        inputs.write_text('\n'.join(map(str, profiles)) + '\n')
        run_command(self.runner, 'merge-runtime-profiles', ['xcrun', 'llvm-profdata', 'merge', '-sparse',
                    '--failure-mode=any', '--input-files=' + str(inputs), '-o', str(merged)], 300)
        binaries = self.evidence / 'binaries'
        objects = []
        for name in sorted(self.result['binaries']):
            if name != 'container':
                objects += ['-object', str(binaries / name)]
        log = run_command(self.runner, 'export-runtime-coverage', ['xcrun', 'llvm-cov', 'export',
                          '-format=lcov', '-instr-profile=' + str(merged), str(binaries / 'container'), *objects], 300)
        runtime = self.evidence / 'runtime.lcov'
        shutil.copyfile(log, runtime)
        self.result['covered_service_lines'] = validate_runtime_coverage(runtime.read_text(), self.result['full_suite'])
        text = merge_lcov([runtime.read_text() + ''.join(p.read_text() for p in self.layer_reports)])
        self.result.update(export_reports(self.runner, self.evidence, text))
        self.result.update(profdata_sha256=digest(merged),
                           layers={p.name: digest(p) for p in self.layer_reports},
                           scope='Container Swift CLI integration and host runtime line coverage; guest and Go service results are separate')
        if source_files() != self.result['source_files']:
            raise RuntimeError('Sources changed while exporting integration coverage')

    def finish(self, tests_passed: bool) -> None:
        """Restore the original even if profile conversion fails; retain unsafe recovery."""
        try:
            if self.backup is not None:
                stop_owned('fork')
                require_idle(self.installation)
                try:
                    if tests_passed:
                        self.export()
                finally:
                    # Never replace binaries still mapped by a surviving process.
                    require_idle(self.installation)
                    if self.installation.exists():
                        own(self.installation, 'fork')
                        shutil.rmtree(self.installation)
                    self.backup.rename(self.installation)
                    temporary = self.backup.parent
                    self.backup = None
                    verify_binaries(self.installation, self.original['binaries'])
                    temporary.rmdir()
                    self.result.pop('recovery_directory', None)
                    self.result['restored'] = True
            self.result['passed'] = tests_passed and self.result['restored']
        except BaseException as error:
            self.result['passed'] = False
            self.result['failures'].append(str(error))
            raise
        finally:
            self.runner.runtime_environment = {}
            self.persist()
