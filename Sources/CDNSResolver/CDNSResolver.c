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

#include "CDNSResolver.h"

#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include <net/if.h>
#include <netdb.h>
#include <resolv.h>
#include <stdlib.h>
#include <string.h>

static int32_t cdns_parse_scope(const char *scope, uint32_t *scope_id) {
    char *end = NULL;
    unsigned long numeric = strtoul(scope, &end, 10);
    if (scope[0] != '\0' && end != NULL && end[0] == '\0') {
        if (numeric > UINT32_MAX) {
            return CDNS_STATUS_INVALID_ARGUMENT;
        }
        *scope_id = (uint32_t)numeric;
        return CDNS_STATUS_OK;
    }

    unsigned int index = if_nametoindex(scope);
    if (index == 0) {
        return CDNS_STATUS_INVALID_ARGUMENT;
    }
    *scope_id = index;
    return CDNS_STATUS_OK;
}

static int32_t cdns_parse_nameservers(
    const char *value,
    union res_sockaddr_union servers[MAXNS],
    int *server_count
) {
    *server_count = 0;
    if (value == NULL || value[0] == '\0') {
        return CDNS_STATUS_OK;
    }

    char *copy = strdup(value);
    if (copy == NULL) {
        return CDNS_STATUS_RESOLVER_ERROR;
    }

    int32_t status = CDNS_STATUS_OK;
    char *cursor = copy;
    char *server = NULL;
    while ((server = strsep(&cursor, ",")) != NULL) {
        if (server[0] == '\0' || *server_count == MAXNS) {
            status = CDNS_STATUS_INVALID_ARGUMENT;
            break;
        }

        union res_sockaddr_union *entry = &servers[*server_count];
        memset(entry, 0, sizeof(*entry));
        if (inet_pton(AF_INET, server, &entry->sin.sin_addr) == 1) {
            entry->sin.sin_len = sizeof(entry->sin);
            entry->sin.sin_family = AF_INET;
            entry->sin.sin_port = htons(NS_DEFAULTPORT);
        } else {
            char *scope = strchr(server, '%');
            if (scope != NULL) {
                *scope = '\0';
                scope++;
            }
            if (inet_pton(AF_INET6, server, &entry->sin6.sin6_addr) != 1) {
                status = CDNS_STATUS_INVALID_ARGUMENT;
                break;
            }
            entry->sin6.sin6_len = sizeof(entry->sin6);
            entry->sin6.sin6_family = AF_INET6;
            entry->sin6.sin6_port = htons(NS_DEFAULTPORT);
            if (scope != NULL) {
                status = cdns_parse_scope(scope, &entry->sin6.sin6_scope_id);
                if (status != CDNS_STATUS_OK) {
                    break;
                }
            }
        }
        (*server_count)++;
    }

    free(copy);
    return status;
}

int32_t cdns_validate_nameservers(const char *nameservers) {
    union res_sockaddr_union servers[MAXNS];
    int server_count = 0;
    return cdns_parse_nameservers(nameservers, servers, &server_count);
}

int32_t cdns_send_query(
    const uint8_t *query,
    size_t query_length,
    const char *nameservers,
    uint8_t *response,
    size_t response_capacity,
    size_t *response_length,
    int32_t *resolver_error
) {
    if (query == NULL || query_length == 0 || query_length > INT_MAX ||
        response == NULL || response_capacity == 0 || response_capacity > INT_MAX ||
        response_length == NULL || resolver_error == NULL) {
        return CDNS_STATUS_INVALID_ARGUMENT;
    }

    *response_length = 0;
    *resolver_error = 0;

    struct __res_state state;
    memset(&state, 0, sizeof(state));
    if (res_ninit(&state) != 0) {
        *resolver_error = errno;
        return CDNS_STATUS_RESOLVER_ERROR;
    }

    state.retrans = 1;
    state.retry = 1;

    union res_sockaddr_union servers[MAXNS];
    int server_count = 0;
    int32_t parse_status = cdns_parse_nameservers(nameservers, servers, &server_count);
    if (parse_status != CDNS_STATUS_OK) {
        res_nclose(&state);
        return parse_status;
    }
    if (server_count > 0) {
        res_setservers(&state, servers, server_count);
    }

    int length = res_nsend(
        &state,
        query,
        (int)query_length,
        response,
        (int)response_capacity
    );
    if (length < 0 || (size_t)length > response_capacity) {
        *resolver_error = state.res_h_errno != 0 ? state.res_h_errno : errno;
        res_nclose(&state);
        return CDNS_STATUS_RESOLVER_ERROR;
    }

    *response_length = (size_t)length;
    res_nclose(&state);
    return CDNS_STATUS_OK;
}

int32_t cdns_resolve_addresses(
    const char *hostname,
    int32_t family,
    uint8_t *addresses,
    size_t address_capacity,
    size_t *address_count,
    int32_t *resolver_error
) {
    if (hostname == NULL || hostname[0] == '\0' ||
        (family != AF_INET && family != AF_INET6) ||
        addresses == NULL || address_capacity < CDNS_ADDRESS_STRIDE ||
        address_count == NULL || resolver_error == NULL) {
        return CDNS_STATUS_INVALID_ARGUMENT;
    }

    *address_count = 0;
    *resolver_error = 0;

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = family;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    struct addrinfo *results = NULL;
    int error = getaddrinfo(hostname, NULL, &hints, &results);
    if (error != 0) {
        *resolver_error = error;
        if (error == EAI_NONAME
#ifdef EAI_NODATA
            || error == EAI_NODATA
#endif
        ) {
            return CDNS_STATUS_NOT_FOUND;
        }
        return CDNS_STATUS_RESOLVER_ERROR;
    }

    size_t maximum_addresses = address_capacity / CDNS_ADDRESS_STRIDE;
    for (struct addrinfo *result = results;
         result != NULL && *address_count < maximum_addresses;
         result = result->ai_next) {
        const uint8_t *source = NULL;
        size_t source_length = 0;
        if (family == AF_INET && result->ai_family == AF_INET) {
            const struct sockaddr_in *address = (const struct sockaddr_in *)result->ai_addr;
            source = (const uint8_t *)&address->sin_addr;
            source_length = sizeof(address->sin_addr);
        } else if (family == AF_INET6 && result->ai_family == AF_INET6) {
            const struct sockaddr_in6 *address = (const struct sockaddr_in6 *)result->ai_addr;
            source = (const uint8_t *)&address->sin6_addr;
            source_length = sizeof(address->sin6_addr);
        } else {
            continue;
        }

        int duplicate = 0;
        for (size_t index = 0; index < *address_count; index++) {
            const uint8_t *existing = addresses + (index * CDNS_ADDRESS_STRIDE);
            if (memcmp(existing, source, source_length) == 0) {
                duplicate = 1;
                break;
            }
        }
        if (duplicate) {
            continue;
        }

        uint8_t *destination = addresses + (*address_count * CDNS_ADDRESS_STRIDE);
        memset(destination, 0, CDNS_ADDRESS_STRIDE);
        memcpy(destination, source, source_length);
        (*address_count)++;
    }

    freeaddrinfo(results);
    return *address_count == 0 ? CDNS_STATUS_NOT_FOUND : CDNS_STATUS_OK;
}
