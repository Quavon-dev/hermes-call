"""Client addresses behind reverse proxies, shared by the relay and the push gateway."""

import ipaddress

Network = ipaddress.IPv4Network | ipaddress.IPv6Network


def _address(value: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address | None:
    try:
        address = ipaddress.ip_address(value.strip())
    except ValueError:
        return None
    if address.version == 6 and address.ipv4_mapped is not None:
        return address.ipv4_mapped
    return address


def is_trusted(value: str, trusted: tuple[Network, ...]) -> bool:
    """Loopback (a proxy on the same host) is always trusted, plus the configured networks."""
    address = _address(value)
    return address is not None and (address.is_loopback or any(address in net for net in trusted))


def client_ip(remote: str, forwarded: str, trust_proxy: bool, trusted: tuple[Network, ...]) -> str:
    """The first address, from the right, that is not one of our proxies.

    Each proxy appends the address it saw, so entries left of the first untrusted one can be forged
    by the client. A malformed entry ends the walk at the last address we could vouch for.
    """
    if not trust_proxy or not forwarded or not is_trusted(remote, trusted):
        return remote
    current = remote
    for entry in reversed(forwarded.split(",")):
        address = _address(entry)
        if address is None:
            return current
        current = str(address)
        if not is_trusted(current, trusted):
            return current
    return current


def parse_networks(values: object) -> tuple[Network, ...]:
    if not isinstance(values, list):
        raise ValueError("trusted_proxies must be a list")
    return tuple(ipaddress.ip_network(str(net)) for net in values)


def key(ip: str, prefix: int = 64, v4_prefix: int = 32) -> str:
    """Rate-limit key: the IPv4 address (or its /`v4_prefix`), or the IPv6 /`prefix` it belongs to."""
    address = _address(ip)
    if address is None:
        return ip
    if address.version == 6:
        return str(ipaddress.ip_network(f"{address}/{prefix}", strict=False))
    if v4_prefix < 32:
        return str(ipaddress.ip_network(f"{address}/{v4_prefix}", strict=False))
    return str(address)
