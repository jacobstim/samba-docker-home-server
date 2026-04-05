#!/bin/bash
SCRIPT_PATH=$(dirname "$0")
source "$SCRIPT_PATH"/vars.sh
PROVISION_SCRIPT=samba-provision.sh
if [ -f "$CONFIG_FILE" ]; then
   cp -f /var/lib/samba/private/krb5.conf "$KERBEROS_CONFIG_FILE"
   rm -f "$DEFAULT_CONFIG_FILE"
   ln -s "$CONFIG_FILE" "$DEFAULT_CONFIG_FILE"

   # Configure BIND9
   cat > /etc/bind/named.conf.options << NAMEDEOF
options {
    directory "/var/cache/bind";
    auth-nxdomain yes;
    empty-zones-enable no;
    tkey-gssapi-keytab "/var/lib/samba/bind-dns/dns.keytab";
    minimal-responses yes;
    forwarders { ${DNSFORWARDER}; };
    allow-query { any; };
    allow-recursion { any; };
};
logging {
    channel default_log {
        file "/var/log/named/named.log" versions 3 size 5m;
        severity dynamic;
        print-time yes;
        print-severity yes;
        print-category yes;
    };
    channel samba_dlz {
        file "/var/log/named/samba_dlz.log" versions 3 size 5m;
        severity debug 10;
        print-time yes;
        print-severity yes;
        print-category yes;
    };
    category default { default_log; };
    category general { default_log; };
    category queries { default_log; };
    category network { default_log; };
    category notify { default_log; };
    category update { default_log; };
    category dnssec { default_log; };
    category database { samba_dlz; };
};
NAMEDEOF

   # Include Samba DLZ zones
   grep -q "bind-dns/named.conf" /etc/bind/named.conf || \
       echo 'include "/var/lib/samba/bind-dns/named.conf";' >> /etc/bind/named.conf

   # Detect BIND major version and uncomment correct DLZ library
   BIND_MINOR=$(named -v 2>&1 | grep -oP 'BIND 9\.\K[0-9]+')
   DLZ_LIB="/usr/lib/x86_64-linux-gnu/samba/bind9/dlz_bind9_${BIND_MINOR}.so"

   if [ -f "$DLZ_LIB" ]; then
       sed -i "s|.*database \"dlopen.*dlz_bind9_${BIND_MINOR}.so\";|    database \"dlopen ${DLZ_LIB}\";|" /var/lib/samba/bind-dns/named.conf
   else
       echo "WARNING: No DLZ library found for BIND 9.${BIND_MINOR}, looking for latest available..."
       LATEST_DLZ=$(ls /usr/lib/x86_64-linux-gnu/samba/bind9/dlz_bind9_*.so 2>/dev/null | sort -V | tail -1)
       if [ -n "$LATEST_DLZ" ]; then
           LATEST_VER=$(echo "$LATEST_DLZ" | grep -oP 'dlz_bind9_\K[0-9]+')
           echo "Using dlz_bind9_${LATEST_VER}.so as fallback"
           sed -i "s|.*database \"dlopen.*dlz_bind9_${LATEST_VER}.so\";|    database \"dlopen ${LATEST_DLZ}\";|" /var/lib/samba/bind-dns/named.conf
       else
           echo "ERROR: No DLZ library found!"
           exit 1
       fi
   fi

   # Fix permissions for bind
   mkdir -p /run/named
   chown bind:bind /run/named
   mkdir -p /var/log/named
   chown -R bind:bind /var/log/named
   chmod 755 /var/log/named   
   chown -R root:bind /var/lib/samba/bind-dns/ 2>/dev/null || true
   chmod 770 /var/lib/samba/bind-dns/ 2>/dev/null || true
   chmod 640 /var/lib/samba/bind-dns/dns.keytab 2>/dev/null || true

   # Start BIND9
   named -u bind

   # Start reverse DNS zone creation in background after Samba is ready
   (
       sleep 10
       REVERSE_ZONE=$(echo ${DC_IP} | cut -d. -f1).in-addr.arpa
       PTR_RECORD=$(echo ${DC_IP} | cut -d. -f4).$(echo ${DC_IP} | cut -d. -f3).$(echo ${DC_IP} | cut -d. -f2)
       # Only create zone if it doesn't exist yet
       if ! samba-tool dns zonelist ${DC_IP} -U Administrator -P 2>/dev/null | grep -q "${REVERSE_ZONE}"; then
           samba-tool dns zonecreate ${DC_IP} ${REVERSE_ZONE} -U Administrator -P
           samba-tool dns add ${DC_IP} ${REVERSE_ZONE} ${PTR_RECORD} PTR ${DC_NAME}.${DOMAIN_FQDN} -U Administrator -P
           # Restart BIND so DLZ picks up the new zone
           pkill named
           sleep 2
           named -u bind
       fi
   ) &
   exec samba --interactive --no-process-group

else
   echo "No Samba config file found at: $CONFIG_FILE"
   echo "Please exec into the container and provision Samba by running the following commands:"
   echo "   docker exec -it samba-dc bash"
   echo "   $SCRIPT_PATH/$PROVISION_SCRIPT"
   sleep infinity
fi