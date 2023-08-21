#!/usr/bin/env bash

# Run in a chroot context

set -e
set -x

hostname="${HOSTNAME}"
username="${USERNAME}"
github_keys="${GITHUB_KEYS}"
git_user_name="${GIT_USER_NAME}"
git_user_email="${GIT_USER_EMAIL}"
remove_builtin_user="${REMOVE_BUILTIN_USER}"
pi4_alt_fstab="${PI4_ALT_FSTAB}"
use_microboot="${USE_MICROBOOT}"
cm4_usb="${CM4_USB}"
lock_root_account="${LOCK_ROOT_ACCOUNT}"
enable_mac_hostname="${ENABLE_MAC_HOSTNAME}"
install_paru="${INSTALL_PARU}"
paru_packages="${PARU_PACKAGES}"
silent_systemd_upgrade="${SILENT_SYSTEMD_UPGRADE}"


# Recomended in https://wiki.archlinux.org/index.php/Chroot#Using_chroot
# Doesn't seem to do much
source /etc/profile
# Debug info
#env

# First boot install step: https://archlinuxarm.org/platforms/armv8/broadcom/raspberry-pi-3
pacman-key --init &> /dev/null
pacman-key --populate archlinuxarm &> /dev/null

# Enable network connection
if [[ -L /etc/resolv.conf ]]; then
  mv /etc/resolv.conf /etc/resolv.conf.bk;
fi
echo 'nameserver 8.8.8.8' > /etc/resolv.conf;

if [[ "$silent_systemd_upgrade" ]] ; then
  echo 'systemd upgrade workaround requested...'
  # Upgrade everything but systemd
  pacman -Syu --noconfirm --needed --ignore=systemd
  # Silently upgrade systemd, suppress output to stderr
  pacman -Syu --noconfirm --needed systemd &> /dev/null
else
  pacman -Syu --noconfirm --needed
fi

if [ "$use_microboot" = "false" ] ; then
  echo 'Microboot support not requested, installing Pi kernel/firmware/bootloader...'
  pacman -R linux-aarch64 uboot-raspberrypi --noconfirm &> /dev/null
  pacman -S linux-rpi raspberrypi-bootloader firmware-raspberrypi raspberrypi-firmware --noconfirm --needed &> /dev/null
else
  echo 'Microboot support was requested.'
  echo 'linux-aarch64 & uboot-raspberrypi are provided by default. Continuing...'

# Set up localization https://wiki.archlinux.org/index.php/Installation_guide#Localization
sed -i 's/#en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/g' /etc/locale.gen
locale-gen
echo 'LANG=en_GB.UTF-8' > /etc/locale.conf
echo 'LC_ALL=en_GB.UTF-8' >> /etc/locale.conf

# Etckeeper init
pacman -S git etckeeper glibc --noconfirm --needed

export HOME=/root
git config --global user.email "${git_user_email}"
git config --global user.name "${git_user_name}"

etckeeper init

cd /etc
git add -A
git commit -m 'initial commit'

systemctl enable etckeeper.timer
systemctl start etckeeper.timer

# set up resize firstrun script
mv /tmp/resizerootfs.service /etc/systemd/system
chmod +x /tmp/resizerootfs
mv /tmp/resizerootfs /usr/sbin/
systemctl enable resizerootfs.service

if [ "$enable_mac_hostname" = "true" ] ; then
  # set up mac-host firstrun script
  mv /tmp/mac-host.service /etc/systemd/system
  chmod +x /tmp/mac-host
  mv /tmp/mac-host /usr/sbin/
  systemctl enable mac-host.service
fi

# Set Hostname
# Normally we use hostnamectl, but that doesn't work in chroot
#hostnamectl set-hostname raspi3
echo "${hostname}" > /etc/hostname

# Install stuff
pacman -S vim htop parted sudo --noconfirm --needed

# Sometimes the network file is missing for some unknown reason
if [ ! -f "/etc/systemd/network/en.network" ] ; then
  echo 'Fixing eth -> en network file'
  touch /etc/systemd/network/en.network
  cat >/etc/systemd/network/en.network <<EOL
[Match]
Name=en*

[Network]
DHCP=yes
DNSSEC=no
EOL

fi

# Set up systemd-resolved  (mDNS)
mkdir -p /etc/systemd/resolved.conf.d
echo '[Resolve]' > /etc/systemd/resolved.conf.d/mdns.conf
echo 'MulticastDNS=yes' >> /etc/systemd/resolved.conf.d/mdns.conf
mkdir -p /etc/systemd/network/en.network.d
echo '[Network]' > /etc/systemd/network/en.network.d/mdns.conf
echo  'MulticastDNS=yes' >> /etc/systemd/network/en.network.d/mdns.conf

systemctl enable systemd-resolved.service

# disable password auth
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
systemctl restart sshd

# enable color in pacman
sed -i 's/#Color/Color/g' /etc/pacman.conf

# create user
useradd -m "${username}"
usermod -aG wheel "${username}"
usermod -aG video "${username}"

# Setup user ssh keys
mkdir /home/"${username}"/.ssh
touch "/home/${username}/.ssh/authorized_keys"
curl "${github_keys}" > "/home/${username}/.ssh/authorized_keys"
chown -R "${username}:${username}" "/home/${username}/.ssh"
chmod go-w "/home/${username}"
chmod 700 "/home/${username}/.ssh"
chmod 600 "/home/${username}/.ssh/authorized_keys"


if [ "$remove_builtin_user" = "true" ] ; then
  userdel -r alarm
else
  # Add alarm to wheel so that it can use sudo
  usermod -aG wheel "alarm"
fi

if [ "$lock_root_account" = "true" ] ; then
  # disable root login root:root
  # https://wiki.archlinux.org/index.php/Sudo#Disable_root_login
  passwd -l root
fi

# Set up no-password sudo
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel

# copy the throttle script
mv /tmp/throttle.sh "/home/${username}/throttle.sh"
chmod +x "/home/${username}/throttle.sh"

if [ "$pi4_alt_fstab" = "true" ] ; then
  echo 'setting up pi4 fstab'
  cat /etc/fstab
  sed -i 's/mmcblk0/mmcblk1/g' /etc/fstab
  cat /etc/fstab
fi

if [ "$cm4_usb" = "true" ] ; then
  echo '' >> /boot/config.txt
  echo '[cm4]' >> /boot/config.txt
  echo 'dtoverlay=dwc2,dr_mode=host' >> /boot/config.txt
fi

if [ "$install_paru" = "true" ] ; then
  echo "Building and installing Paru..."
  sudo pacman -Sy --needed base-devel --noconfirm &> /dev/null
  git clone https://aur.archlinux.org/paru.git
  cd paru
  makepkg -sic
fi

if [ "$install_paru" = "true" ] && [ -n "$paru_packages" ] ; then
  echo "Installing additional packages..."
  paru -Sy "${paru_packages}" --noconfirm &> /dev/null
fi

# restore original resolve.conf
if [[ -L /etc/resolv.conf.bk ]]; then
  mv /etc/resolv.conf.bk /etc/resolv.conf;
fi
