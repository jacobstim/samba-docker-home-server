# Modern Samba Active Directory & File Server Docker Container Environment for Home Servers and Small Businesses

There aren't many configurations for running a Samba Active Directory domain controller and a Samba file server in Docker containers. Those that I could find had so many issues that I decided to build my own configuration from scratch.

## Features

- **Modern & secure** configuration based on Samba v4.
- Easily **upgradable** to a new base OS and new Samba versions.
- Bullet-proof **networking** with support for:
  - Forwarding of the AD DNS zone from the main DNS server to the Samba DC.
  - Forwarding from the Samba DC to the main DNS server.
  - Dynamic DNS updates of domain members.
  - Static external IP address (required for domain controllers).
  - Communication between container and host (normally isolated).
- Separate containers for the AD domain controller and the file server as recommended by the Samba Wiki.
- Samba Active Directory can be used as the **central user authentication system** by IAM tools like Authelia for single sign-on (SSO).
- AD domain **provisioning** and member **join scripts**.
- All data is stored outside the containers in bind-mounted Docker volumes so that the containers can be re-built at any time.
- The file server container supports:
  - POSIX ACLs.
  - Windows permissions/ACLs.
    - If used with an unprivileged Docker container, the option `acl_xattr:security_acl_name = user.NTACL` must be set on shares ([docs](https://www.samba.org/samba/docs/current/man-html/vfs_acl_xattr.8.html)).
    - Windows ACLs require the following settings in `smb.conf`:
      - `vfs objects = acl_xattr`
      - `acl_xattr:ignore system acls = yes`
      - `map acl inherit = yes`
  - Access-based enumeration (ABE).
  - Samba recycle bin.

## Documentation

Please see my [series of blog posts](https://helgeklein.com/blog/samba-active-directory-in-a-docker-container-installation-guide/) for instructions. The articles explain all aspects of the configuration in detail.-

## TrueNAS SCALE Specific Configuration

### Macvlan Shim Interface Naming

When running the Samba DC container on TrueNAS SCALE with macvlan networking, the host requires a macvlan shim interface to enable communication between the TrueNAS host and the container (which are normally isolated from each other).

**Important:** The shim interface must be named with a prefix that TrueNAS recognizes as an internal interface, otherwise TrueNAS will include the shim's IP address in DNS registration during Active Directory domain join, possibly causing errors.

Name the shim interface with the prefix `mac` (e.g., `mac-samba`):
```bash
ip link add mac-samba link bond0 type macvlan mode bridge
ip addr add 172.16.0.6/32 dev mac-samba
ip link set mac-samba up
ip route add 172.16.0.5/32 dev mac-samba
```

In this example:
- `172.16.0.5` is the static IP assigned to the Samba DC container
- `172.16.0.6` is any unused IP on your local network, used as the shim address

TrueNAS filters interfaces starting with `mac` from its `interface.ip_in_use` list, preventing the shim IP from being registered in DNS.

To make this persistent across reboots, add the above command as a single line to **System → Advanced → Init/Shutdown Scripts** (type: Post Init):
```bash
ip link add mac-samba link bond0 type macvlan mode bridge && ip addr add 172.16.0.6/32 dev mac-samba && ip link set mac-samba up && ip route add 172.16.0.5/32 dev mac-samba
```

Replace `bond0` with your actual network interface name.

### Reverse DNS Zones

The container's `init-dc.sh` automatically creates two catch-all reverse DNS zones after startup:

- `in-addr.arpa` — for IPv4 PTR records
- `ip6.arpa` — for IPv6 PTR records

These catch-all zones are required for TrueNAS to successfully register its PTR records during the domain join. 

### Domain Join

TrueNAS SCALE contains a bug in its middleware where IPv4 and IPv6 PTR
records are sent in a single `nsupdate` transaction. BIND responds with `NOTZONE`,
causing the domain join to fail.

This has been reported to the TrueNAS team:
[NAS-140548](https://ixsystems.atlassian.net/browse/NAS-140548)

**Workaround: temporarily disable IPv6:**

If you prefer not to patch the middleware (see bug report above), disable IPv6 on the TrueNAS
network interface before joining the domain:
```bash
sysctl -w net.ipv6.conf.bond0.accept_ra=0
ip -6 addr del <ipv6-address>/64 dev bond0
```

After a successful domain join, re-enable IPv6:
```bash
sysctl -w net.ipv6.conf.bond0.accept_ra=1
```

Replace `bond0` with your actual network interface name.