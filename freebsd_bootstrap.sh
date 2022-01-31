#/bin/sh

drives=''

log_exec() {
	cmd=$1
	echo "--> ${cmd}"
	eval "${cmd}"
}

scan_drives() {
    scannedDrives=$(find -E /dev -regex '(/dev/ada[0-9]+|/dev/da[0-9]+|dev/vtblk[0-9]+|/dev/vtbd[0-9]+|/dev/nvd[0-9]+)')

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
	label=$2

	header "Partition ${drive}"

	log_exec "zpool labelclear -f ${drive}"
	log_exec "gpart destroy -F ${drive}"
	log_exec "gpart create -s gpt ${drive}"

    log_exec "gpart add -s 512k -t freebsd-boot -a 8k ${drive}"
    log_exec "gpart add -t freebsd-zfs -l ${label} -a 8k ${drive}"

	if [ "${ashift}" = '12' ]; then
		if [ "${bootType}" = 'legacy' ]; then
			log_exec "gpart add -s 512k -t freebsd-boot -a 4k ${drive}"
		else
	        log_exec "gpart add -s 2m -t efi -a 4k ${drive}"
	    fi

	    if [ "${poolSize}" = 'fulldisk' ]; then
			log_exec "gpart add -t freebsd-zfs -l ${label} -a 4k ${drive}"
		else
			log_exec "gpart add -s ${poolSize} -t freebsd-zfs -l ${label} -a 4k ${drive}"
		fi
	else
		if [ "${bootType}" = 'legacy' ]; then
			log_exec "gpart add -s 512k -t freebsd-boot ${drive}"
		else
	        log_exec "gpart add -s 2m -t efi ${drive}"
	    fi

	    if [ "${poolSize}" = 'fulldisk' ]; then
			llog_exec "gpart add -t freebsd-zfs -l ${label} ${drive}"
		else
			log_exec "gpart add -s ${poolSize} -t freebsd-zfs -l ${label} ${drive}"
		fi
	fi

	if [ "${bootType}" = 'legacy' ]; then
		log_exec "gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 ${drive}"
	else
	    log_exec "dd if=/boot/boot1.efifat of=${drive}p1 bs=1m"
	fi
}

scan_drives
echo "Drive(s): ${drives}"

#
# partion drives
#
i=0
for drive in ${drives}; do
	label="disk${i}"
	partition_drive $drive $label

	labels=$(echo "${labels} ${label}" | xargs)

	i=$((i + 1))
done

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
