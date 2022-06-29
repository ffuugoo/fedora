#!/bin/zsh

set -euo pipefail -o nullglob -o globdots


declare self=$0
declare root=${self:A:h}

declare config=$root/config
declare dconf=$root/dconf

declare install=$root/install.txt
declare remove=$root/remove.txt


declare -A fstab=(
	[EFI]=/dev/sda1
	[BOOT]=/dev/sda2
	[ROOT]=/dev/sda3
	[HOME]=/dev/sda3
)


declare user=ffuugoo

declare ssh_config=/etc/ssh/ssh_config
declare sshd_config=/etc/ssh/sshd_config
declare samba_shares=/var/lib/samba/shares
declare accounts_service=/var/lib/AccountsService

declare home=/home/$user


declare -A owner=(
	[$samba_shares]=root:sambashare
	[$home]="-R $user:$user"
)

declare -A perms=(
	[/etc/sudoers]=400
	[$ssh_config]=644
	[$ssh_config.d]=755
	[$ssh_config.d/]=644
	[$sshd_config]=600
	[$sshd_config.d]=700
	[$sshd_config.d/]=600
	[$samba_shares]=1770
	[$accounts_service/icons]=775
	[$accounts_service/icons/]=664
	[$accounts_service/users]=700
	[$accounts_service/users/]=600
	[$home/Desktop]=555
	[$home/.public]=555
)


# Samsung 850 EVO 120 GB - 114473 MiB
#
# EFI - 256 MiB
# boot - 512 MiB
# root - 102 GiB
#
# swap - 9256 MiB

function partition-samsung-850-evo-120 {
	declare dev=$1

	declare min=1
	declare max=114473

	- parted -s -a optimal $dev \
		mklabel gpt \
		mkpart  -  $((min))MiB  $((min += 256))MiB \
		mkpart  -  $((min))MiB  $((min += 512))MiB \
		mkpart  -  $((min))MiB  $((min += 102 * 1024))MiB \
		mkpart  -  $((min))MiB  $((max))MiB \
		set 1 boot on \
		unit GiB \
		print
}

function mkfs-samsung-850-evo-120 {
	declare sda=${1:-/dev/sda}
	declare sdb=${2:-/dev/sdb}
	declare mnt=${3:-/mnt}

	- mkfs.vfat -F32 ${sda}1
	- mkfs.ext4 ${sdb}2

	- mkfs.btrfs -m raid0 -d raid0 ${sda}3 ${sdb}3

	- mount ${sda}3 $mnt
	- cd $mnt
		- btrfs subvolume create root
		- btrfs subvolume set-default /root .

		- btrfs subvolume create boot

		- btrfs subvolume create home
	- cd -
	- umount $mnt

	mkswap-samsung-850-evo-120 ${sda}4 ${sdb}4
}

function mkswap-samsung-850-evo-120 {
	declare sda=${1:-/dev/sda4}
	declare sdb=${2:-/dev/sdb4}

	- pvcreate ${sda} ${sdb}
	- vgcreate swap ${sda} ${sdb}
	- lvcreate swap -n swap -l 100%FREE --type raid0
	- mkswap /dev/mapper/swap-swap
}


function packages {
	dnf-enable-rpmfusion
	dnf-install-list
	dnf-mark-list
	dnf-remove-list
	- dnf upgrade
	- dnf autoremove
	- dnf clean all
}

function dnf-enable-rpmfusion {
	declare release ; release="$(rpm -E %fedora)"

	- dnf install \
		https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$release.noarch.rpm \
		https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$release.noarch.rpm

	- dnf install \
		rpmfusion-free-release-tainted \
		rpmfusion-nonfree-release-tainted
}

function dnf-install-list {
	- dnf --setopt=install_weak_deps=False install $(filter-comments ${@:-$install})
}

function dnf-mark-list {
	- dnf mark install $(filter-comments ${@:-$install}) || :
}

function dnf-remove-list {
	- dnf remove $(filter-comments ${@:-$remove})
}

function filter-comments {
	sed -E -e 's/#.*$//g' -e '/^\s*$/d' $@
}


function configs {
	remove-root-files
	remove-user-files

	sync-configs

	fstab
	authselect
	target
	gdm

	sambashare

	ownership
	permissions

	user
}

function remove-root-files {
	- rm -rf /root/*
}

function remove-user-files {
	- rm -rf $home/*
}

function sync-configs {
	- cp -r $config/* /
}

function fstab {
	for label in ${(k)fstab}
	do
		- sed -E -i "s/<$label>\s*/$(printf %-38s "$(lsblk -n -o UUID $fstab[$label])")/" /etc/fstab
	done
}

function authselect {
	- command authselect select custom/basic \
		with-faillock \
		with-silent-lastlog \
		without-nullok \
		with-mdns4 \
		with-mdns6
}

function target {
	- systemctl set-default graphical
}

function gdm {
	- command dconf update
}

function sambashare {
	- groupadd -r sambashare
}

function ownership {
	for key in ${(k)owner}
	do
		if declare items=( ${~key//%\//\/*} ) && (( ${#items} ))
		then
			- chown ${=owner[$key]} $items
		fi
	done
}

function permissions {
	for key in ${(k)perms}
	do
		if declare items=( ${~key//%\//\/*} ) && (( ${#items} ))
		then
			- chmod ${=perms[$key]} $items
		fi
	done
}

function user {
	- usermod $user -a -G sambashare -s /bin/zsh
}


function boot {
	initramfs
	grub
}

function initramfs {
	- dracut -f
}

function grub {
	- grub2-mkconfig -o /boot/grub2/grub.cfg
}


function user-configs {
	the-dot
	dconf
}

function the-dot {
	if [[ ! -d ~/.the-dot ]]
	then
		git clone https://github.com/ffuugoo/the-dot.git ~/.the-dot
	fi

	if [[ ! -e ~/.zshrc ]]
	then
		~/.the-dot/the-dot.sh
	fi
}

function dconf {
	if declare configs=( ${@:-$dconf/*} ) && (( ${#configs} ))
	then
		- cat $configs | - command dconf load /
	fi
}


function - {
	${TEST+echo} $@
}


if [[ $ZSH_EVAL_CONTEXT == toplevel ]] && (( $# == 0 ))
then
	packages
	configs
	boot
else
	$@
fi
