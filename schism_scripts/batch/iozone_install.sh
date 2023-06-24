#!/bin/env bash
# download and compile iozone
wget https://www.iozone.org/src/current/iozone3_506.tar
tar xvf iozone3_506.tar
cd iozone3_506/src/current/
make linux-ia64
# run test on server /dev/nvme0 mount
#sudo ./iozone -aR  /mnt/resource/nfs -f /mnt/resource/nfs/testfile -b nvme01.xls
# run test on client
#sudo ./iozone -azcR -U /shared/data -f /shared/data/testfile -b nfsclient2.xls > nfsclient2.log
#