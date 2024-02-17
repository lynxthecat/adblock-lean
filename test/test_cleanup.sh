#!/bin/sh
#kill_script.sh
#pid=`pgrep -o -x test_run.sh`
out="a"
while true
do
    #out=`ps --ppid $pid | grep time`
	out=`pgrep -o -x test_run.sh`
    sleep 1 
    #echo "!!!!! PS output: $out."
    if [ -z "$out" ]; 
    then 
        break;
    fi
done
kill $(pidof vmstat) > /dev/null 2>&1 