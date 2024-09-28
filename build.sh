#!/bin/bash

set -xe
# 不进行交互安装
export DEBIAN_FRONTEND=noninteractive
BUILD_TYPE="$1"
ROOTFS="rootfs"
TARGET_DEVICE=raspberrypi
ARCH="arm64"
DISKIMG="deepin-$TARGET_DEVICE.img"
IMAGE_SIZE=$( [ "$BUILD_TYPE" == "desktop" ] && echo 12288 || echo 12288 )
COMPONENTS="main,commercial community"
readarray -t REPOS < ./profiles/sources.list
PACKAGES=`cat ./profiles/packages.txt | grep -v "^-" | xargs | sed -e 's/ /,/g'`

# 在 x86 上构建，需要开qemu
sudo apt update -y
sudo apt-get install -y qemu-user-static binfmt-support mmdebstrap arch-test usrmerge usr-is-merged qemu-system-misc systemd-container fdisk dosfstools
sudo systemctl restart systemd-binfmt


if [ ! -d "$ROOTFS" ]; then
    mkdir -p $ROOTFS
    # 创建根文件系统
    sudo mmdebstrap \
        --hook-dir=/usr/share/mmdebstrap/hooks/merged-usr \
        --skip=check/empty \
        --include=$PACKAGES \
        --components="main,commercial,community" \
        --architectures=${ARCH} \
        beige \
        $ROOTFS \
        "${REPOS[@]}"
fi


sudo echo "deepin-$TARGET_DEVICE" | sudo tee $ROOTFS/etc/hostname > /dev/null

# 创建磁盘文件
dd if=/dev/zero of=$DISKIMG bs=1M count=$IMAGE_SIZE
sudo fdisk deepin-raspberrypi.img << EOF
n
p
1

+300M
t
c
n
p
2


w
EOF

# 格式化
LOOP=$(sudo losetup -Pf --show $DISKIMG)
sudo mkfs.fat -F32 "${LOOP}p1"
sudo mkfs.ext4 "${LOOP}p2" # 根分区 (/)

TMP=`mktemp -d`
sudo mount "${LOOP}p2" $TMP
sudo cp -a $ROOTFS/* $TMP

sudo mount "${LOOP}p1" $TMP/boot
# 在物理设备上需要添加 cmdline.txt 定义 Linux内核启动时的命令行参数
PTUUID=$(sudo blkid $LOOP | awk -F'PTUUID="' '{print $2}' | awk -F'"' '{print $1}')
echo "console=serial0,115200 console=tty1 root=PARTUUID=$PTUUID-02 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait quiet init=/usr/lib/raspi-config/init_resize.sh" | sudo tee $TMP/boot/cmdline.txt

# 拷贝引导加载程序/GPU 固件等, 从 https://github.com/raspberrypi/firmware/tree/master/boot 官方仓库中拷贝，另外放入了 cmdline.txt 和 config.txt 配置
sudo cp -r boot/* $TMP/boot
sudo cp -a modules $TMP/lib

# 编辑分区表
PTUUID=$(sudo blkid $LOOP | awk -F'PTUUID="' '{print $2}' | awk -F'"' '{print $1}')
sudo tee $TMP/etc/fstab << EOF
proc            /proc           proc    defaults          0       0
PARTUUID=$PTUUID-01  /boot           vfat    defaults          0       2
PARTUUID=$PTUUID-02  /               ext4    defaults,noatime  0       1
EOF

sudo mount --bind /dev $TMP/dev
sudo mount -t proc chproc $TMP/proc
sudo mount -t sysfs chsys $TMP/sys
sudo mount -t tmpfs -o "size=99%" tmpfs $TMP/tmp
sudo mount -t tmpfs -o "size=99%" tmpfs $TMP/var/tmp

function run_command_in_chroot()
{
    rootfs="$1"
    command="$2"
    sudo chroot "$rootfs" /usr/bin/env bash -e -o pipefail -c "$command"
}

sudo rm -f $TMP/etc/resolv.conf
sudo cp /etc/resolv.conf $TMP/etc/resolv.conf
# 安装树莓派的 raspi-config
mkdir -p $TMP/etc/apt/sources.list.d
echo "deb [trusted=yes] http://archive.raspberrypi.org/debian/ bookworm main" | sudo tee $TMP/etc/apt/sources.list.d/raspberrypi.list
run_command_in_chroot "$TMP" "export DEBIAN_FRONTEND=noninteractive && \
    apt update -y && apt install -y raspi-config"

sudo rm $TMP/etc/apt/sources.list.d/raspberrypi.list

run_command_in_chroot "$TMP" "sed -i -E 's/#[[:space:]]?(en_US.UTF-8[[:space:]]+UTF-8)/\1/g' /etc/locale.gen
sed -i -E 's/#[[:space:]]?(zh_CN.UTF-8[[:space:]]+UTF-8)/\1/g' /etc/locale.gen
"

run_command_in_chroot "$TMP" "useradd -m -g users deepin && usermod -a -G sudo deepin
chsh -s /bin/bash deepin

echo deepin:deepin | chpasswd"
# 删除 root 的密码
sudo sed -i 's/^root:[^:]*:/root::/' $TMP/etc/shadow

run_command_in_chroot "$TMP" "locale-gen"

if [[ "$BUILD_TYPE" == "desktop" ]];
then
    run_command_in_chroot $TMP "export DEBIAN_FRONTEND=noninteractive &&  apt update -y && apt install -y \
        deepin-desktop-environment-core \
        deepin-desktop-environment-base \
        deepin-desktop-environment-cli \
        deepin-desktop-environment-extras \
        firefox"
fi

# 清理缓存
run_command_in_chroot "$TMP" "apt clean
rm -rf /var/cache/apt/archives/*"

sudo umount -l $TMP

sudo e2fsck -f "${LOOP}p2"
sudo resize2fs "${LOOP}p2"

sudo losetup -D $LOOP
sudo rm -rf $TMP
