#The script below is taken from Adrian course and I have just tweeked the script as I was facing errors, dont forget to run chmod +x frr-install.sh brfore running this script. This script also has remove commands too as if you are fixing or reinstalling the lib it would remove broken ones and reinstall into correct directories.
#!/bin/bash
set -e

echo "=== Step 1: System update ==="
sudo apt-get update && sudo apt-get upgrade -y

echo "=== Step 2: Install dependencies ==="
sudo apt-get install -y \
   git autoconf automake libtool make libreadline-dev texinfo \
   pkg-config libpam0g-dev libjson-c-dev bison flex python3-pytest \
   libc-ares-dev python3-dev libsystemd-dev python3-sphinx \
   install-info build-essential libsnmp-dev perl libcap-dev \
   libpcre3-dev libelf-dev libpcre2-dev cmake python3

echo "=== Step 3: Build libyang v1.0.184 ==="
sudo rm -rf /tmp/libyang
cd /tmp
git clone https://github.com/CESNET/libyang.git
cd libyang
git checkout v1.0.184
mkdir build && cd build
cmake -DENABLE_LYD_PRIV=ON \
      -DCMAKE_INSTALL_PREFIX:PATH=/usr \
      -DCMAKE_BUILD_TYPE:String="Release" ..
make
sudo make install
sudo ldconfig

echo "=== Step 4: Install Protobuf and ZeroMQ ==="
sudo apt-get install -y protobuf-c-compiler libprotobuf-c-dev libzmq5 libzmq3-dev

echo "=== Step 5: Build rtrlib v0.6.3 ==="
sudo apt-get install -y libssh-dev
sudo rm -rf /tmp/rtrlib
cd /tmp
git clone https://github.com/rtrlib/rtrlib.git
cd rtrlib
git checkout v0.6.3        # ← Must cd into rtrlib BEFORE checkout
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make
sudo make install
sudo ldconfig

# Verify correct version installed
echo "RTRlib installed:"
ls /usr/local/lib/librtr.so.*   # Must show 0.6.x NOT 0.8.x

echo "=== Step 6: Create FRR user and groups ==="
sudo groupadd -r -g 92 frr    2>/dev/null || true
sudo groupadd -r -g 85 frrvty 2>/dev/null || true
sudo adduser --system --ingroup frr --home /var/run/frr/ \
   --gecos "FRR suite" --shell /sbin/nologin frr 2>/dev/null || true
sudo usermod -a -G frrvty frr

echo "=== Step 7: Clone FRR 7.3.1 ==="
sudo rm -rf /tmp/frr
cd /tmp
git clone https://github.com/frrouting/frr.git frr
cd frr
git checkout frr-7.3.1
./bootstrap.sh

echo "=== Step 8: Patch bgp_bfd.c to fix Clippy parsing ==="
# Clippy cannot parse #if/#else/#endif directives INSIDE a DEFUN macro argument.
# Fix: replace the entire conditional block with just DEFUN(
# (valid for this lab since HAVE_BFDD=0 means DEFUN was chosen anyway)
python3 << 'PYEOF'
import re

filepath = '/tmp/frr/bgpd/bgp_bfd.c'

with open(filepath, 'r') as f:
    content = f.read()

# Pattern that breaks Clippy:
#   #if HAVE_BFDD > 0
#   DEFUN_HIDDEN(
#   #else
#   DEFUN(
#   #endif /* HAVE_BFDD */
# Fix: replace the whole block with just DEFUN(

before = content.count('DEFUN_HIDDEN(')

content = re.sub(
    r'#if HAVE_BFDD > 0\nDEFUN_HIDDEN\(\n#else\nDEFUN\(\n#endif /\* HAVE_BFDD \*/',
    'DEFUN(',
    content
)

after = content.count('DEFUN_HIDDEN(')
fixed = before - after
print(f"Fixed {fixed} Clippy-incompatible DEFUN blocks in bgp_bfd.c")

if fixed == 0:
    print("WARNING: Pattern not found - check bgp_bfd.c manually")
else:
    print("Patch applied successfully - Clippy can now parse bgp_bfd.c")

with open(filepath, 'w') as f:
    f.write(content)
PYEOF

echo "=== Step 9: Configure FRR ==="
./configure \
    --prefix=/usr \
    --includedir=/usr/include \
    --enable-exampledir=/usr/share/doc/frr/examples \
    --bindir=/usr/bin \
    --sbindir=/usr/lib/frr \
    --libdir=/usr/lib/frr \
    --libexecdir=/usr/lib/frr \
    --localstatedir=/var/run/frr \
    --sysconfdir=/etc/frr \
    --with-moduledir=/usr/lib/frr/modules \
    --enable-configfile-mask=0640 \
    --enable-logfile-mask=0640 \
    --enable-snmp=agentx \
    --enable-multipath=64 \
    --enable-user=frr \
    --enable-group=frr \
    --enable-vty-group=frrvty \
    --enable-systemd=yes \
    --enable-rpki=yes \
    --with-pkg-git-version \
    --with-pkg-extra-version=-chriselsen

echo "=== Step 10: Build and install FRR (normal make, no hacks) ==="
make
sudo make install

echo "=== Step 11: Install config files ==="
sudo install -m 775 -o frr -g frr    -d /var/log/frr
sudo install -m 775 -o frr -g frrvty -d /etc/frr
sudo install -m 640 -o frr -g frrvty tools/etc/frr/vtysh.conf   /etc/frr/vtysh.conf
sudo install -m 640 -o frr -g frr    tools/etc/frr/frr.conf     /etc/frr/frr.conf
sudo install -m 640 -o frr -g frr    tools/etc/frr/daemons.conf /etc/frr/daemons.conf
sudo install -m 640 -o frr -g frr    tools/etc/frr/daemons      /etc/frr/daemons
sudo install -m 644 tools/frr.service /etc/systemd/system/frr.service
sudo systemctl enable frr

echo "=== Step 12: Sysctl - enable IP forwarding ==="
sudo sed -i "/net.ipv4.ip_forward=1/ cnet.ipv4.ip_forward=1" /etc/sysctl.conf
sudo sed -i "/net.ipv6.conf.all.forwarding=1/ cnet.ipv6.conf.all.forwarding=1" /etc/sysctl.conf
sudo sysctl -p

echo "=== Step 13: Enable BGP daemon with RPKI ==="
sudo sed -i "/bgpd=no/ cbgpd=yes" /etc/frr/daemons
sudo sed -i \
  's/bgpd_options="   -A 127.0.0.1"/bgpd_options="   -A 127.0.0.1 -M rpki"/' \
  /etc/frr/daemons

echo "=== Step 14: Set permissions and start FRR ==="
sudo chmod 740 /var/run/frr
sudo systemctl start frr
sudo systemctl status frr

echo ""
echo "=== Installation complete! ==="
echo "Verify with: vtysh -c 'show version'"
