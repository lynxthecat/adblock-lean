#!/bin/sh
set -e
# https://stackoverflow.com/questions/28828470/how-to-run-iostat-vmstat-top-sar-till-all-the-background-processes-are-completed
# How to run iostat/vmstat/top/sar till all the background processes are completed?

if [[ $# -ne 1 ]] ; then
	echo 'Usage :<./test_init.sh filename >'
	exit 1
fi

adblock_script="$1"
if [ ! -f ${adblock_script} ]; then
	echo 'Usage: <./test_init.sh adblock_filename.'
	echo 'Not found: $adblock_script .'
	exit 1
else
	sha=$(sha256sum ${adblock_script})
	echo "===== sha256sum of tested script: ${sha}."
fi

pkg_vmstat=`opkg list | grep procps-ng-vmstat`
if [ "$pkg_vmstat" == "" ]; then
	echo "Test requires installation of : procps-ng-vmstat."
	echo "Install with: opkg install procps-ng-vmstat"
	exit 1
else
	echo "Prerequisite package 'procps-ng-vmstat' found."
fi


echo && echo "===== Machine information ====="
dmesg | grep -i "Machine model"
echo && echo "===== Version ====="
cat /proc/version
echo && echo "===== Memory: 'free' command ====="
free
echo && echo "===== Disk: 'df' command ====="
df


echo && echo "===== Pre-Test cleanup steps ====="
echo "TODO"

echo && echo "===== Pre-Test vmstat info ====="
vmstat -t -w 1 10

echo && echo "===== Invoke adblock-lean script ====="
vmstat -t -w 1 &									# run vmstat during test
 /usr/bin/time ./test_run.sh ${adblock_script} &
./test_cleanup.sh
echo && echo "===== Post-Test vmstat info =====" 
vmstat -t -w 1 10








