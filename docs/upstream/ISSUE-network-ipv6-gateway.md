# [Request]: Configure an IPv6 gateway for a custom vmnet network

## Feature or enhancement request details

The macOS `container network create` path can configure an IPv6 subnet, but it
could not preserve a caller-selected IPv6 gateway. It always selected the first
address in the vmnet prefix and the custom vmnet interface did not carry IPv6
address or gateway values to the guest setup path.

This prevents a generic macOS client from representing an IPv6 IPAM gateway
while still using vmnet's existing IPv6 prefix configuration. The guest agent
already has generic IPv6 address and default-route support, so the missing work
is narrowly scoped to passing that information through the existing network
configuration, status, attachment, and custom-vmnet interface layers.

Expected behavior:

* `container network create --subnet-v6 PREFIX --gateway-v6 ADDRESS` accepts a
  valid, in-prefix IPv6 gateway.
* The vmnet prefix receives that gateway, network inspection reports it, and
  the primary guest interface receives the matching IPv6 default route.
* Omitted gateways retain the existing first-address default.
* Invalid, zoned, unspecified, or out-of-prefix gateways fail before a network
  helper is started.

The signed fork commits are `fe272b22c133bd82e319d3c91863fe11abe708a0` in
`containerization` and `c194d29` in `container`.

## Scope and non-goals

This is macOS vmnet behavior only. It does not introduce Docker or Compose
syntax into product code, does not add embedded DNS, and does not add Windows
or Linux-host behavior.

## Code of Conduct

- [x] I agree to follow this project's Code of Conduct.
