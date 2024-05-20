# Add downlink IPv6 routes for DHCPv6-PD leases on Ubiquiti EdgeOS (ISC-DHCPd)
# Script version: 2024-05-15

# Ubiquiti EdgeRouters with EdgeOS can be configured to delegate IPv6 prefixes
# via DHCPv6 (IA-PD via DHCPv6-PD), in addition to assigning single IPv6
# addresses (IA-NA) to DHCPv6 clients. However, when delegating prefixes,
# EdgeOS won't add any routes towards the downlink routers that it delegated
# prefixes to. This leaves the downlink IPv6 connectivity nonfunctional. These
# downlink routes have to be maintained manually, which defeats the dynamic
# approach of DHCPv6-PD.
#
# This script will try to automate maintenance of the required routes, by
# reading the ISC-DHCPd leases file and trying to add the required downlink
# routes, resp. deleting previous routes for PD leases that have expired.
#
# Known quirks:
# - Link-local routing is not supported, because ISC-DHCPd doesn't log the
#   link-local address of a client that requested a DHCPv6 lease.
# - Clients that only request a PD lease and no NA lease aren't supported.
# - Clients that use a different DUID to request their NA vs. their PD lease
#   aren't supported, but may be fuzzy-matched if their behavior is known.
#   Currently implemented for recent Linux- and VxWorks-based TP-Link WiFi
#   routers.
# - The script needs to be run manually or on a schedule, because the
#   particular ISC-DHCPd version used in EdgeOS doesn't support invoking
#   external programs on DHCPv6 events.
# - Neither current or old routes, nor the logs of this script are stored
#   persistently. This is on purpose. The script is supposed to be re-run after
#   each EdgeRouter reboot in order to recover downlink IPv6 connectivity.
#
# This script is tested on EdgeOS 1.10.11 and 2.0.9. It may or may not be
# usable with other EdgeOS versions or other ISC-DHCPd equipped systems.

# This script is Public Domain. You may freely use, modify and distribute it
# in whole or in part, for any purpose, with or without crediting me.

# No expressed or implied warranties of any kind. This script may or may not
# serve any purpose. It's provided solely for educational and experimental use.

# Please find the latest version of this script at:
# https://github.com/Shine-/EdgeOS-DHCPv6-PD-routes


# Set up logging and log rotation
exec 3>&1 1> >(tee -a /tmp/delegated.log) 2>&1
[ -f /tmp/delegated.log.bak ] || touch /tmp/delegated.log.bak
rotate=$(($(date +%s) - $(date -r /tmp/delegated.log.bak +%s)))
echo "---" `date +%Y-%m-%d' '%H:%M:%S` "--- Log file backup is $rotate seconds old."
[ "$rotate" -gt 86400 -a -f /tmp/delegated.log ] && {
	echo - Rotating logs and restarting.
	mv /tmp/delegated.log /tmp/delegated.log.bak
	# Stop logging to old file and restart script
	exec $0 "$@" 1>&3 3>&-
}

echo "---" `date +%Y-%m-%d' '%H:%M:%S` "--- Starting setup/cleanup of routes for delegated prefixes"
# Set up the arrays and hash lists we need
declare -A NEXTHOP; declare -A ADDRESS
declare -a LEASES; declare -a ROUTES; declare -a DELEGATED
# Pull all active leases from the ISC-DHCPd leases file using AWK. ISC-DHCPd stores the DHCPv6 DUID as an escaped string,
# which we need to fix up a bit, in order to prevent malfunction of this script, and for proper unescaping later.
readarray -t LEASES < <(
awk 'BEGIN { RS="\n\nia-"; FS=";\n"; }
/^na|^pd/ {
	# since we are splitting at quotes, replace any actual escaped quote with its octal equivalent
	gsub(/\\\"/,"\\042",$1); split($1,DUID,"\"")
	for(i=2;i<=NF;i++) { if ($i ~ /^  iaprefix|^  iaaddr/) { split($i,ADDR," ") } }
	#if ($2 ~ /^  iaprefix|^  iaaddr/) { split($2,ADDR," ") } # possibly even shorten like this
	if (ADDR[6] == "active") {
		# a space character in DUID hurts us, use its octal equivalent instead
		gsub(" ","\\040",DUID[2])
		# octal character codes are 3-digits, any 4th digit is an actual number - escape it to its ASCII code
		DUID[2] = gensub(/(\\[0-9]{3})([0-9])/,"\\1\\\\x3\\2","g",DUID[2])
		printf "%s %s %s\n",DUID[1],ADDR[2],DUID[2]
	}
	delete DUID; delete ADDR
} ' "/var/run/dhcpdv6.leases"
)
#declare -p LEASES
[ ${#LEASES[@]} -ne 0 ] && {
	# Now let's build a list of routes from the leases we parsed
	echo "- We have the following active leases:"
	for item in "${LEASES[@]}"; do 
		set -- $item
#		echo "Item: $item"
#		echo "IA-${1^^} $2 delegated to $3"
		# Convert ISC-DHCPd DUID format (escaped string) to hex, skipping the first byte due to TP-Link brokenness.
		# Explanation: on TP-Link devices, the DUID used for requesting PD resp. NA may differ in the 1st byte (either x+1 or x-1)
		# As the first byte designates the DUID type only (e.g. DUID-LLT or DUID-EN), skipping it shouldn't hurt other clients.
		#D=$(printf '%b' "$3" | hexdump -s 1 -ve '1/1 "%02x"') # Attn: this is causing invalid seek operation errors in hexdump
		D=$(printf '%b' "$3" | hexdump -ve '1/1 "%02x"'); D=${D:2}
#		echo "DUID $3 == $D"
		[ "$1" = "pd" ] && { echo "Prefix $2 delegated to DUID $D"; }
		[ "$1" = "na" ] && { echo "Address $2 leased to DUID $D"; }
		[ "$1" = "na" ] && { ADDRESS["$D"]="$2"; }
		[ "$1" = "pd" ] && { NEXTHOP["$2"]="$D"; }
	done
#	echo "- We have active prefix delegations to the following devices:"
#	printf '%s\n' "${NEXTHOP[@]}"
#	echo "- To which we're delegating the following prefixes:"
#	printf '%s\n' "${!NEXTHOP[@]}"
	echo "- We currently need the following routes:"
	for prefix in ${!NEXTHOP[@]}; do
		VIA="${ADDRESS["${NEXTHOP["$prefix"]}"]}"
		[ -n "$VIA" ] && {
			ROUTE="$prefix via $VIA"; ROUTES+=("$ROUTE")
			echo "$ROUTE"
		} || echo "# $prefix (ignoring, no DHCPv6 lease found for DUID ${NEXTHOP["$prefix"]})"
	done
	echo "- Database of routes for prefixes we've delegated before:"
	[ -f "/tmp/delegated.db" ] && { readarray -t DELEGATED < /tmp/delegated.db; } || echo "<< empty >>"
	for item in "${DELEGATED[@]}"; do echo $item; done
	echo "- Checking for routes we don't need anymore (deleting as necessary):"
	for item in "${DELEGATED[@]}"; do
		itemx="\<${item}\>"
		[[ ${ROUTES[@]} =~ $itemx ]] && { echo "# $item (still delegating)"; } || {
			echo "Deleting route: $item"
			ip -6 r del $item
		}
	done
	echo "- Checking for missing routes (adding as necessary):"
	for ROUTE in "${ROUTES[@]}"; do
		[ -n "$(ip -6 r | grep "$ROUTE")" ] && { echo "# $ROUTE (already present)"; } || {
			echo "Adding route: $ROUTE"
			ip -6 r add $ROUTE
		}
	done
	echo "- Writing current routes for delegated prefixes to database:"
	{ for item in "${ROUTES[@]}"; do echo $item; done; } > /tmp/delegated.db
	for item in "${ROUTES[@]}"; do echo $item; done
}
echo "---" `date +%Y-%m-%d' '%H:%M:%S` "--- Finished setup/cleanup of routes for delegated prefixes"
