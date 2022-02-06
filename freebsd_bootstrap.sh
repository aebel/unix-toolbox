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
log_exec "chroot -u root -g wheel ${altroot} puppet config set server 'puppet.ebel.systems' --section main"
log_exec "chroot -u root -g wheel ${altroot} sysrc 'puppet_enable="YES"'"

header 'Done.'

header "You have been chrooted to ${altroot}, so you can apply any changes here (set hostname, add user, network config etc). Enjoy."
log_exec "chroot ${altroot} /bin/tcsh"
