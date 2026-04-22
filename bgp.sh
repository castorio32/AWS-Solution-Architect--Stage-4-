#*Note -  Run this after you run frr-install.sh, as you will observe that frr service has started but still bgp is not running. The below is the fix to make bgp service running again
# Stop FRR first
sudo systemctl stop frr

# Check if RPKI module exists
if ls /usr/lib/frr/modules/*rpki* 2>/dev/null; then
    echo "RPKI module found — path issue only"
else
    echo "RPKI module MISSING — removing -M rpki flag"
fi

# Fix 1: Remove -M rpki from bgpd_options if module is missing
sudo sed -i 's/bgpd_options="   -A 127.0.0.1 -M rpki"/bgpd_options="   -A 127.0.0.1"/' \
    /etc/frr/daemons

# Verify the change
grep bgpd /etc/frr/daemons

# Fix 2: Ensure /var/run/frr has correct permissions
sudo chown frr:frr /var/run/frr
sudo chmod 755 /var/run/frr

# Fix 3: Ensure frr.conf is valid (not empty)
cat /etc/frr/frr.conf
# If empty, write a minimal valid config
sudo bash -c 'cat > /etc/frr/frr.conf << EOF
frr version 7.3.1
frr defaults traditional
hostname $(hostname)
log syslog informational
no ipv6 forwarding
!
line vty
!
