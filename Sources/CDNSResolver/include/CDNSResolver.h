//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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

#ifndef CDNSRESOLVER_H
#define CDNSRESOLVER_H

#include <stddef.h>
#include <stdint.h>

#define CDNS_STATUS_OK 0
#define CDNS_STATUS_INVALID_ARGUMENT 1
#define CDNS_STATUS_RESOLVER_ERROR 2
#define CDNS_STATUS_NOT_FOUND 3

#define CDNS_ADDRESS_STRIDE 16

int32_t cdns_validate_nameservers(const char *nameservers);

int32_t cdns_send_query(
    const uint8_t *query,
    size_t query_length,
    const char *nameservers,
    uint8_t *response,
    size_t response_capacity,
    size_t *response_length,
    int32_t *resolver_error
);

int32_t cdns_resolve_addresses(
    const char *hostname,
    int32_t family,
    uint8_t *addresses,
    size_t address_capacity,
    size_t *address_count,
    int32_t *resolver_error
);

#endif
