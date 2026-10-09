#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
## Copyright © 2026 container project authors.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##   https://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##===----------------------------------------------------------------------===##

"""Admit finite, byte-bound verifier and test-only recipe transitions."""

import hashlib
import json
from pathlib import Path
import re

IMPORTER = 'Tools/bazel/artifacts/native_layers.py'
CONSUMER = 'Tools/bazel/artifacts/native_consumer.py'
OLD = {
    IMPORTER: 'fb7d2a828b5d11316288bfb1ec8a1b1908e5f32aafb4912fb2635ed3aa669630',
    CONSUMER: '3dc681d3e736e83f74e0ddea6cd54b30e9f688d23df9ec30447c243cc0e51200',
}
NEW = {
    IMPORTER: 'e18b15255c4032a1d2b8592394ad2b6bf556100d3cf31f19f77d6709f961015c',
    CONSUMER: '84f0358f54801b7448f4fe81435cbf0b8ed0efe18aac6954a121e32ac2381ebe',
}
HOST_FIXTURE = 'Tools/bazel/async-http-client-host-tests.patch'
HOST_FIXTURE_OLD = '9d437e372b38bca686d7839b48566442bdd41239e1b300010567b0861a328282'
HOST_FIXTURE_NEW = '38bc850cf28df21d01a656eada236f434081233d1b8a4ab0407d9ae17d50e70f'
SHA = re.compile(r'[0-9a-f]{64}\Z')


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def admit(producer: object, current: object, root: Path) -> dict:
    selected = root / 'Tools/bazel/artifacts/recipe_compatibility.py'
    loaded = Path(__file__)
    if (selected.is_symlink() or not selected.is_file() or loaded.is_symlink()
            or digest(selected.read_bytes()) != digest(loaded.read_bytes())):
        raise ValueError('native recipe compatibility policy differs from selected source')
    policy_sha = digest(loaded.read_bytes())
    if (not isinstance(producer, dict) or not isinstance(current, dict)
            or set(producer) != set(current) or not {IMPORTER, CONSUMER}.issubset(producer)
            or any(not isinstance(key, str) or not isinstance(producer[key], str)
                   or not SHA.fullmatch(producer[key]) or not isinstance(current[key], str)
                   or not SHA.fullmatch(current[key]) for key in producer)):
        raise ValueError('published native recipe inventory is incomplete or malformed')
    changed = {key for key in producer if producer[key] != current[key]}
    remaining = set(changed)
    modes = []
    verifier_pair = {IMPORTER, CONSUMER}
    if verifier_pair.issubset(remaining) and all(
            producer[key] == OLD[key] and current[key] == NEW[key] for key in verifier_pair):
        remaining -= verifier_pair
        modes.append('known-consumer-verifier-update')
    # This reviewed patch changes two macOS test setups only. All production
    # inputs, published archive/proof hashes and lower-chain identities stay exact.
    if (HOST_FIXTURE in remaining and producer[HOST_FIXTURE] == HOST_FIXTURE_OLD
            and current[HOST_FIXTURE] == HOST_FIXTURE_NEW):
        remaining.remove(HOST_FIXTURE)
        modes.append('known-host-timeout-fixture-update')
    if remaining:
        raise ValueError('published native recipe differs from authenticated consumer update')
    mode = '+'.join(modes) if modes else 'exact'
    canonical = lambda value: json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
    return {'schema': 1, 'mode': mode,
            'producerRecipeSHA256': digest(canonical(producer)),
            'currentRecipeSHA256': digest(canonical(current)),
            'policySHA256': policy_sha,
            'changedFiles': sorted(changed)}
