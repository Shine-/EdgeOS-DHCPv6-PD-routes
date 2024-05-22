# DHCPv6-PD Routes for Ubiquiti EdgeOS
If you have ever tried to configure your Ubiquiti EdgeRouter as a DHCPv6-PD **server**, ie. assigning IPv6 prefixes to other, downlink routers, you may have noticed that while the PD assignment will work fine, clients connected to your downlink router will not have any IPv6 connectivity - despite getting assigned a valid IPv6 address by the downlink router.

<details><summary>Example EdgeOS configuration snippet for DHCPv6-PD</summary>

```
interfaces {
      ethernet eth0 {
        address 2001:db8::1/112
        description PD-Downlink
        ipv6 {
            dup-addr-detect-transmits 1
            router-advert {
                cur-hop-limit 64
                link-mtu 0
                managed-flag true
                max-interval 600
                other-config-flag true
                prefix ::/64 {
                    autonomous-flag false
                    on-link-flag true
                    valid-lifetime 2592000
                }
                reachable-time 0
                retrans-timer 0
                send-advert true
            }
        }
        speed auto
    }
}

service {
    dhcpv6-server {
        shared-network-name PD-Downlink {
            name-server 2001:db8::1111
            subnet 2001:db8::/64 {
                address-range {
                    start 2001:db8::2 {
                        stop 2001:db8::fff
                    }
                }
                prefix-delegation {
                    start 2001:db8:0:100:: {
                        stop 2001:db8:0:ff00:: {
                            prefix-length 56
                        }
                    }
                }
            }
        }
    }
}
```
</details>

The reason for this is the DHCP server used by EdgeOS, ISC-DHCPd, which is simply incapable of modifying the routing table. Therefore, all routes need to be added or removed manually, which, in my opinion, completely defeats the dynamic approach called "DHCP"...

[This](pdroutes.sh) script tries to automate the route addition for new leases and route deletion for expired leases.

It comes with a few caveats, namely it can't use the preferred way of Link-Local routes (ISC-DHCPd doesn't log the Link-Local address of a DHCPv6 client), and it's impossible - at least on an EdgeRouter - to automatically invoke the script on DHCPv6 events like "lease" or "expire" (the particular ISC-DHCPd version used by EdgeOS doesn't support that yet for *DHCPv6*, only for DHCPv4). For more information, see the comments inside the script.

# Prerequisites
You will likely require a static or semi-static IPv6 uplink configuration, to build a static DHCPv6-PD downlink configuration like in the example above. At least I haven't succeeded in making EdgeOS use a dynamic (e.g. DHCPv6-PD) uplink configuration to build its downlink DHCPv6 configuration. Let me know if I'm mistaken...

# Usage
* Configure your Edgerouter as a DHCPv6-PD server on any downlink interface(s)
* Connect downlink routers to your EdgeRouter that are configured for uplink DHCPv6-PD (e.g. any modern WiFi router)
* Copy the script to your EdgeRouter and run it

It will read the ISC-DHCPd leases file and add routes for all PDs that it can find a destination hop for. If you run the script again, it will also delete any obsolete routes to destinations whose lease(s) have expired.

The script will print its progress and some debug information on screen, and log the same to `/tmp/delegated.log`. There are two debug levels (`-v` and `-vv`) that will generate more output, mainly in regards to parsing the ISC-DHCPd leases file. `-vv` will try to decode and print out all known DUIDs from the leases file, not just the active leases (attention, slowdown!). This is especially useful to have additional test cases for decoding the abysmal ISC-DHCP DUID format to something more sane.

You may want to run the script automatically after the EdgeRouter reboots (after EdgeOS restores the DHCPv6 leases file from backup) by copying it to `/config/scripts/post-config.d`, and also add the script to the hourly cron-jobs in `/etc/cron.hourly`. Note that in this case, it may take **up to an hour** for the script to pick up new/expired DHCPv6 leases and add/remove the relevant routes. So you might even want to create an own cron-job that runs more often.

If you find a way to make EdgeOS run the script trigger-based, e.g. on new or expiring DHCPv6 leases, let me know!

It shouldn't be hard to adapt the script to other (non-EdgeOS) systems that are using ISC-DHCPd for DHCPv6, as these will most likely suffer from the same problem. The script should be able to run with little to no modification in `bash` and not too cut-down `ash` (BusyBox) variants.

# License / Legal
I'm releasing this script into the Public Domain. It's completely free as in "use, distribute and modify as much as you like, but don't blame me if it won't fit your needs".

I assert that all code in this script is my own. Any code derived from other works that may have been used in earlier, unreleased versions of this script has been removed and/or replaced by my own code prior to the first public release of this script.

# Bug reports and suggestions
I've been using this script and its predecessors for many months now in my lab environment. The script has gone through several minor and major modifications and rewrites, some due to lack of knowledge about how ISC-DHCPd works, some due to unexpected behavior from certain DHCPv6 clients, and last but not least also due to stupidity on my side. By now, I consider the script "working rather well in my lab", but it may still show flaws once used in the wild...

Feel free to contact me if you find any bugs or have fixes or additions to share. You may also simply fork this repository and proceed development with your own version of the script - whatever fits you best!

I might stop using EdgeOS sooner or later, since it seems to have been abandoned by Ubiquiti anyway. In addition, ISC-DHCPd is EoL'd by now, so it will disappear from active use over time. But as long as I'm still using EdgeOS, I'm open for suggestions concerning this script!
