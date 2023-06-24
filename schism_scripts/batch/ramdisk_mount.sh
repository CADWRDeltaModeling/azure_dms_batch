sudo mkdir /mnt/ramdisk
sudo mount -t tmpfs -o size=128g tmpfs /mnt/ramdisk
sudo chown _azbatch /mnt/ramdisk
sudo chmod 777 /mnt/ramdisk
