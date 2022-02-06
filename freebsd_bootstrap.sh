#/bin/sh
# scp aebel@192.168.5.20:/home/aebel/code/unix-toolbox/freebsd_bootstrap.sh .
ftpUrl='ftp://ftp.de.freebsd.org/pub/FreeBSD/releases/amd64/13.0-RELEASE'
distDir='/tmp/zroot/var/tmp/freebsd-dist'
packages='base.txz kernel.txz'

drives=''
ashift='13'
pool='zroot'
altroot="/tmp/${pool}"

netif='vtnet0'

ip=`ifconfig -f inet:cidr ${netif} | grep inet | cut -w -f3`
gateway=`netstat -nr | grep default | cut -w -f2`

log_exec() {
	cmd=$1
	echo "--> ${cmd}"
	eval "${cmd}"
}

header() {
	header=$1
	echo
	echo $header
}

scan_drives() {
    scannedDrives=$(find -E /dev -regex '(/dev/ada[0-9]+|/dev/da[0-9]+|/dev/vtbd[0-9]+|/dev/nvd[0-9]+)')

	while(true); do
		drives=''

		for drive in ${scannedDrives}; do
			if [ ! -c $drive ]; then
				echo "WARNING: ${drive} not found!"
			else
				drives=$(echo "${drives} ${drive}" | xargs)
			fi
		done

		read -p "Enter drive(s) [${drives}]: " scannedDrives

		if [ -z "${scannedDrives}" -a ! -z "${drives}" ]; then
			break
		fi
	done
}

partition_drive() {
	drive=$1
	number=$2

	header "Partition ${drive}"

	log_exec "zpool labelclear -f ${drive}"
	log_exec "zpool export -a"
	log_exec "gpart destroy -F ${drive}"
	log_exec "gpart create -s gpt ${drive}"

    # Create Boot Partion
    log_exec "gpart add -s 512k -t freebsd-boot -a 1m ${drive}"

    # Create Swap Partion
    log_exec "gpart add -s 8G -t freebsd-swap -l swap${number} -a 1m ${drive}"

    # Create Main Partion
    log_exec "gpart add -t freebsd-zfs -l disk${number} -a 1m ${drive}"

    # Write Bootcode
    log_exec "gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 ${drive}"
}

scan_poolDevices() {
	scannedPoolDevices=$1

	while(true); do
		poolDevices=$scannedPoolDevices

		read -p "Enter pool devices [${poolDevices}]: " scannedPoolDevices

		if [ -z "${scannedPoolDevices}" -a ! -z "${poolDevices}" ]; then
			break
		fi
	done
}

scan_drives
echo "Drive(s): ${drives}"

#
# WARNING Message
#
while(true); do
	echo "WARNING: All data on selected drive(s) will be lost!"
	read -p "Proceed with installation? (yes/no) " confirm

	if [ "${confirm}" = 'no' ]; then
		exit
	fi

	if [ "${confirm}" = 'yes' ]; then
		break
	fi
done

#
# partion drives
#
i=0
for drive in ${drives}; do
    label="disk${i}"
	partition_drive $drive $i

	labels=$(echo "${labels} ${label}" | xargs)

	i=$((i + 1))
done

#
# Start Installation
#
log_exec "kldload zfs"
log_exec "sysctl vfs.zfs.min_auto_ashift=${ashift}"

for label in ${labels}; do
	poolDevices=$(echo "${poolDevices} /dev/gpt/${label}" | xargs)
done

if [ $(echo ${poolDevices} | tr ' ' "\n" | wc -l) -gt 1 ]; then
	scan_poolDevices "mirror ${poolDevices}"
fi

header 'Create pool'
log_exec "zpool create -o altroot=${altroot} -O compress=zstd -O atime=off -m none -f ${pool} ${poolDevices}"

header 'Create filesystems'
log_exec "zfs create -o mountpoint=none ${pool}/ROOT"
log_exec "zfs create -o mountpoint=/ ${pool}/ROOT/default"
log_exec "zfs create -o mountpoint=/tmp -o exec=on -o setuid=off ${pool}/tmp"
log_exec "zfs create -o mountpoint=/usr -o canmount=off ${pool}/usr"
log_exec "zfs create ${pool}/usr/home"
log_exec "zfs create -o setuid=off ${pool}/usr/ports"
log_exec "zfs create ${pool}/usr/src"
log_exec "zfs create -o mountpoint=/var -o canmount=off ${pool}/var"
log_exec "zfs create -o exec=off -o setuid=off ${pool}/var/audit"
log_exec "zfs create -o exec=off -o setuid=off ${pool}/var/crash"
log_exec "zfs create -o exec=off -o setuid=off ${pool}/var/log"
log_exec "zfs create -o atime=on ${pool}/var/mail"
log_exec "zfs create -o setuid=off ${pool}/var/tmp"

header 'Set mountpoint'
log_exec "zfs set mountpoint=/${pool} ${pool}"
log_exec "zfs set canmount=noauto ${pool}/ROOT/default"

header 'Set bootfs'
log_exec "zpool set bootfs=${pool}/ROOT/default ${pool}"
#log_exec "zpool set cachefile=/var/tmp/zpool.cache tank"

header 'Sync zpool.cache'
log_exec "mkdir -p ${altroot}/boot/zfs ; zpool set cachefile=${altroot}/boot/zfs/zpool.cache ${pool}"

header 'Set permissions for /tmp and /var/tmp'
log_exec "mkdir -p ${altroot}/tmp ; chmod 1777 ${altroot}/tmp"
log_exec "mkdir -p ${altroot}/var/tmp ; chmod 1777 ${altroot}/var/tmp"

header 'Create distDir'
log_exec "mkdir -p ${distDir}"

header 'Fetch Distfiles'
for package in ${packages}; do
	log_exec "( cd ${distDir}; fetch ${ftpUrl}/${package} )"
done

header 'Extract files'
log_exec "( cd ${distDir} ; for file in ${packages} ; do cat \${file} | tar --unlink -xpJf - -C ${altroot} ; done )"

echo "Enter hostname FQDN"
read HOSTNAME

echo "Enter username"
read USERNAME

header 'Create /etc/rc.conf'
cat > ${altroot}/etc/rc.conf << RCCONF
hostname="$HOSTNAME"
zfs_enable="YES"
# Network
ifconfig_${netif}="inet ${ip}"
ifconfig_${netif}="inet6 accept_rtadv"
rtsold_enable="YES"
defaultrouter="${gateway}"
# Services
sendmail_enable="NONE"
sshd_enable="YES"
RCCONF

header 'Create /etc/fstab'
cat > ${altroot}/etc/fstab << FSTAB
# Device                       Mountpoint              FStype  Options         Dump    Pass#
#/dev/gpt/swap0                 none                    swap    sw              0       0
#/dev/gpt/swap1                 none                    swap    sw              0       0
FSTAB

header 'Create /boot/loader.conf'
cat >> ${altroot}/boot/loader.conf << LOADER
kern.geom.label.disk_ident.enable="0"
kern.geom.label.gptid.enable="0"
zfs_load="YES"
vfs.zfs.arc_max="8G"
LOADER

header 'Create /etc/sysctl.conf'
cat >> ${altroot}/etc/sysctl.conf << SYSCTL
vfs.zfs.min_auto_ashift=13
SYSCTL

header 'Create /etc/resolv.conf'
cat > ${altroot}/etc/resolv.conf << RESOLV
nameserver 8.8.8.8
nameserver 9.9.9.9
RESOLV

header 'Create Package Repo'
log_exec "chroot -u root -g wheel ${altroot} mkdir -p /usr/local/etc/pkg/repos"
log_exec "chroot -u root -g wheel ${altroot} mkdir -p /usr/local/etc/ssl/certs"

cat > ${altroot}/etc/ssl/certs/ebel-systems-ca.pem << EBELSYSTEMSCA
-----BEGIN CERTIFICATE-----
MIIFRDCCAyygAwIBAgIIN23zaRR4aA4wDQYJKoZIhvcNAQENBQAwWDELMAkGA1UE
BhMCREUxFTATBgNVBAoTDEViZWwtU3lzdGVtczEYMBYGA1UECxMPRWJlbC1TeXN0
ZW1zIENBMRgwFgYDVQQDEw9FYmVsLVN5c3RlbXMgQ0EwIBcNMjEwNjIzMTExOTAw
WhgPMjA4MjA2MjQwMDAwMDBaMFgxCzAJBgNVBAYTAkRFMRUwEwYDVQQKEwxFYmVs
LVN5c3RlbXMxGDAWBgNVBAsTD0ViZWwtU3lzdGVtcyBDQTEYMBYGA1UEAxMPRWJl
bC1TeXN0ZW1zIENBMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtGV7
5QFJRoEmcLs2zHFxnhvaDMyI76fX3bw36Mt4QSGvMr4L0w0Zapr5z6PZnDuCMV+a
z7uaoSKyX9BQZACtBaem3ByV6oa1TWs6Gx3XO98MiY4J/bUST9+9Wmm1TsqdnHhz
LhOutYA5gnJMsuaZjFF0u97uJrgBK56rNMNgBeKU2DmFLN6KJejBuzPKruMA6T0G
7SnG6EpLkAOv8SvCtFFHbdMVfhX4oFXpzwdCRo2zHEXuZz7E3D7wjbZOUZFm5UIP
MXF7YObpwcy66ae+n/UYmEAmDq1Xh4KeiEUgXBltAWN0br5VQNgXGYQ//HLARRyA
QYh85/6leVfdatFV8M1dIMw7KY2iYfbEbWqo2DmrKqC9ZHGD1ZhTPz1TA0P9H0+k
C43wLT1fnEdvmEyjS/buxuQJWTGuJ6QnWkTFwgaDeahdHUVdWxwagE2QF3V7KiS/
jcL9EX/OSCZe0ZxPMlJLxoL0T4FdQW5NQ7BFCiJx6epsFNqJKVnL8+NDZxDT+bj3
jRxcu3XtWsWt7tdKd0lgkGcOTrhJ47uzeflsXwIDg2DS3G7Czcwj+hB8lxZGCFFB
Nl1jnyIQPm10Ixv4iBBiVlFx5JdynDiwXfqh9OHiGaZHjfoGXTxpfndKW1agjR3P
iV2E9hdlUXRCEqlO156UICspSZ54JxqSW2ud/1cCAwEAAaMQMA4wDAYDVR0TBAUw
AwEB/zANBgkqhkiG9w0BAQ0FAAOCAgEARL2GWx0n25RTEy9fcYte9muvAHtdV4th
AnbXASoPAkII21gTXbXQOvXDPUKSf2qwDB1ncZmDnsar+HzVdT4NscKADb6rfw0z
it/rD9xtYmWEY3KhtKuVPxLQmz2yjv9NWiMSPohcGi5CX0DFHbjmc3FKoxCZkpg7
BFEQuciuxnFJBsonBURY+SqtPHmnXCCIoi2W8ckRrccZGUUfxWb+8mzHv1N4h99K
wbdkyeS4iv8SAYvl/WpE3dXNBlRFbn+xLKKqH26+bmBRaLGGwPyj4cXH5x0UOJJ/
E3+MDYRLnwWR8h+kqPonMXYgmgHSOSDsYUQQc0YVF19cqjIzZgdqK1Vkeq5b9YqI
DaK1h+kdFMhVTKPuVrKWd+BA7us0WveTd3fjnQoPEiz2H3cOsInlVWcild57m8h0
G9InvqYKIkWeZMbL2OoqfOjih/aa3xFn7eUVjTz/n3o4CvA7KlXZfmPwC+orbDTM
VOlHlqo1nk8St9tn/mVIHwzR+KfUg6g9sTV2gRXTNbI/vDiXOM25EBI722lSgtMs
kcL2jUts7K1lnIL+Bfq/tsSkBpQJEE6FWzNGWbiW6YMaUhVxi9L6mFl7VislhQ2L
Ndo0dsp9X3PjTNoXEdj31K4xwee2Bw4iuNO9Ooqbtcf8PrNSU5bXuQJP8ZZWlfyw
5l0plNnD9o8=
-----END CERTIFICATE-----
EBELSYSTEMSCA

log_exec "chroot -u root -g wheel ${altroot} ln -s /etc/ssl/certs/ebel-systems-ca.pem /etc/ssl/certs/7317cef0.0"

cat > ${altroot}/etc/ssl/certs/ebel-systems-ssl.pem << SSLEBELSYSTEMS
-----BEGIN CERTIFICATE-----
MIIFRjCCAy6gAwIBAgIIR63CibwotV4wDQYJKoZIhvcNAQENBQAwWDELMAkGA1UE
BhMCREUxFTATBgNVBAoTDEViZWwtU3lzdGVtczEYMBYGA1UECxMPRWJlbC1TeXN0
ZW1zIENBMRgwFgYDVQQDEw9FYmVsLVN5c3RlbXMgQ0EwIBcNMjEwNjIzMTEyMDAw
WhgPMjA4MjA2MjQwMDAwMDBaMFoxCzAJBgNVBAYTAkRFMRUwEwYDVQQKEwxFYmVs
LVN5c3RlbXMxGTAXBgNVBAsTEEViZWwtU3lzdGVtcyBTU0wxGTAXBgNVBAMTEEVi
ZWwtU3lzdGVtcyBTU0wwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDq
xbqw9XvKc9+evnABWnQh44gZl9lcBAao/aC9/lwmLdBg78a45V0OnQ7NRRX63AXN
n93YUNnmjiK8/g6u9B2S6FHITMaP2pcwge164RAHycshIKovOt0OKUo9UrWKJp7h
TsWSd3Ohy9xuoy0tsBld+oUU/Yz2YRZDABeFzzfp5SX5sKaBgz4Unatt1AbSRL09
8vRUTKH6ZQcOXhjmwPjekn9J9OPaiQh0hVQvtsjRIfpJRtnoac4/Jh0Xd1Qa3bJD
Tz8nPrLHcYJQTBMgCTQQK8oj4pAxbYjPIWikuWldIj20pmxhuAHIwlbIPTS/dJ8K
c03DYK/mKKrBfPHTnen16VekgqO1488OaYVSGAC/xbsY4k2FR+1PLdcloF3IR+lx
d9eQetOQKzvi6A0V3BTp4br8KsC8+heGlWEOkayPoZ1+zpi6RhhnlfG3nFb5wjgS
9RbdCBHcNOb/yi7DsRlWdzDX16VmrRrMm9bi9Lrn3BTm/oK3EuwElHdLb9OqpDea
Po1NxPAifXOIT34EFj8b9JpcrnKf02I+6dhmYJVTaskw6pFG9tqWJ15KJCJsu0ky
V3DAUthMRTSHZZDgq8aaH4ZkKsMFUMIrf+B4uT0snY4yfUmEWEo6kQaGLv8k+CZT
GZ2ce+yaXY66RpUQCRMQkXzdjGyz8tZs5z7yN2vZqwIDAQABoxAwDjAMBgNVHRME
BTADAQH/MA0GCSqGSIb3DQEBDQUAA4ICAQAJdh22yz4Yje5hABXyqkoex1pyCSsD
QHd+lLT4t0kI6dBcZHMY8AIKH6HviVKzn+wSVlI4Ve0AhShk0Y8r4BZCBnA6BSYn
lGXn3x1J3TOPSODFej3v4wUvga3XhLrrRacxtkUn8pgHJ4fnndHWj/PNJIvhiaLV
a2/WSKZ2221GPpe1ieNb8RL2x2Eb6YdNh9qhanAzYWbt+CfLgeQu1doduaWhOVNM
W2n948oSSfBsUlOLqIiCgalU9+YtegHPv3kgnUZvjP2FUAPO2yy32xiktvG1Mlql
sxUgn4BMyFdKoy3xrAu96FJwv3KGOdkch65dstxF8L99Wh3NKFYe9QVXFJx/dheI
jFC+hUtfbjwnCeP7cHCI7jVr7rl39YRDL+UKWHmUtQM6u007yPrGhq0lrED0wiQf
HAn/QlRL6iYDqmfwXtQ40LmJwhvJ6DCEDMloATvU5b18yZNjpyXRNOE249bWPNNY
u5uVvvG9qNMOmwwCnczr8Oq0aQd4Up3Ej0rMqjpOaEG0XULwjJjGLuwZSF51e7Nr
Q7Q2aPO17RUN8/DtJv12itc8hTNMpLf53x4Ksu59VmXCVpMURkZMaU+Ty+0uySZb
3UpVTsEgQH2E8O/H6NX1HaZKTSbvW5JFrpCqEL7sbyIW+dCWXRg5nMxNA3FLLiIS
5gD6d7Na/G0fKA==
-----END CERTIFICATE-----
SSLEBELSYSTEMS

log_exec "chroot -u root -g wheel ${altroot} ln -s /etc/ssl/certs/ebel-systems-ssl.pem /etc/ssl/certs/5fe57e1a.0"

cat > ${altroot}/usr/local/etc/ssl/certs/poudriere.cert << POUDRIERECERT
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA0ss3Nc7EVhgcQE4dqRtt
W653SForY1ZtdlLe78UkflsRoeZEqB968iZYSQFWuEg6YiEiMbAshOHKpe+X/C85
uESfBW/WyWEqhWcEeFe0rnamZOPTjPppXKIEPyZZDPHLDBkMqt8R67TWsCL4bCeF
5zYRniw0s60lq62SD9MfRvc5NxiBd+LB4MLl/5KzfQf50vEP/5swl/DYrawCXbko
xz88f5TdmEEmWyMeiOgPMR0gy+xIN6pWeSLCfX3UR4Q7UCpPCTYxUQQvBhJ7LWAu
QPY95LV6dyiXCHnvAomHaktQ5ukPjcYw90bc3BkTcivKZs/DKiL9YjKQbISZtziO
OvOyriQU/1DBRCQA32kx0VS3DCv/NmUjtUZFaye4aB2MIYJYQxzpFVA2HIUL1+Ax
u7Wf/z+eF7TLfqknmM7AlEt9BYAEMgCQYHQ8GuSjzmqt7QCcgDw4IPxACB3ssgsn
gkQssxNaBOtkp5mxE3RL3vsMjcSZ3EubFvsn8Wya9OTIgAOo54/pJcRxPfLSy+wY
g5DkLrNZRxGKAEcTA5gFiKr/EGhRuQ7aZgrCeaP+zr3JMyKCFGIBGJnlJ0DpOiP6
LSqpijNy85XGwyKezRg+M9tOFKUgg2rMO1BupnNTPCZZZuvlxGf7SIbcvOZLXklK
5MHtmaiNWLwXere1jfeODV8CAwEAAQ==
-----END PUBLIC KEY-----
POUDRIERECERT

cat > ${altroot}/usr/local/etc/pkg/repos/FreeBSD.conf << REPOFREEBSD
FreeBSD: {
        enabled: no
}
REPOFREEBSD

cat > ${altroot}/usr/local/etc/pkg/repos/custom.conf << REPOCUSTOM
custom: {
        url: "https://packages.ebel.systems/packages/130amd64-default-server",
        signature_type: "pubkey",
        pubkey: "/usr/local/etc/ssl/certs/poudriere.cert",
        enabled: yes,
}
REPOCUSTOM

header "Mount devfs on ${altroot}/dev"
log_exec "mount -t devfs devfs ${altroot}/dev"

header "Bootstrap pkg and minimal packages"
log_exec "chroot -u root -g wheel ${altroot} env ASSUME_ALWAYS_YES=YES pkg bootstrap"
log_exec "chroot -u root -g wheel ${altroot} env ASSUME_ALWAYS_YES=YES pkg install puppet7"

header "Add user"
log_exec "chroot -u root -g wheel ${altroot} pw useradd -n $USERNAME -u 1001 -s /bin/tcsh -m -d /home/$USERNAME -G wheel -h 0"

header "Add .ssh directory"
log_exec "chroot -u root -g wheel ${altroot} mkdir -p /home/$USERNAME/.ssh/"

header "Fetch pub keys from Github"
log_exec "fetch https://github.com/$USERNAME.keys --no-verify-peer -o - >> ${altroot}/home/$USERNAME/.ssh/authorized_keys"
log_exec "chroot -u root -g wheel ${altroot} chown -R 1001:1001 /home/$USERNAME/.ssh"

header "Inital Puppet Setup"
log_exec "chroot -u root -g wheel ${altroot} sysrc 'puppet_enable=\"YES\"'"
log_exec "chroot -u root -g wheel ${altroot} /usr/local/bin/puppet config set server 'puppet.ebel.systems' --section main"

header 'Done.'

header "You have been chrooted to ${altroot}, so you can apply any changes here (set hostname, add user, network config etc). Enjoy."
log_exec "chroot ${altroot} /bin/tcsh"
