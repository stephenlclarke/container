//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#ifndef CZ_VERSION
#define CZ_VERSION "latest"
#endif

#ifndef GIT_COMMIT
#define GIT_COMMIT "unspecified"
#endif

#ifndef RELEASE_VERSION
#define RELEASE_VERSION "0.0.0"
#endif

#ifndef CONTAINER_SOURCE
#define CONTAINER_SOURCE "apple/container"
#endif

#ifndef CONTAINERIZATION_SOURCE
#define CONTAINERIZATION_SOURCE "apple/containerization"
#endif

#ifndef CONTAINERIZATION_REF
#define CONTAINERIZATION_REF CZ_VERSION
#endif

#ifndef BUILDER_SHIM_VERSION
#define BUILDER_SHIM_VERSION "0.0.0"
#endif

#ifndef BUILDER_SHIM_REPOSITORY
#define BUILDER_SHIM_REPOSITORY "ghcr.io/apple/container-builder-shim/builder"
#endif

#ifndef BUILDER_SHIM_DIGEST
#define BUILDER_SHIM_DIGEST ""
#endif

const char* get_git_commit();

const char* get_release_version();

const char* get_container_source();

const char* get_containerization_source();

const char* get_containerization_ref();

const char* get_swift_containerization_version();

const char* get_container_builder_shim_version();

const char* get_container_builder_shim_repository();

const char* get_container_builder_shim_digest();
