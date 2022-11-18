# adblock-oisd
Set up adblock using the highly popular [oisd dnsmasq file](https://oisd.nl/) used by major adblockers and which is intended to block ads without interfering with normal use. 

adblock-oisd is written as a service and 'service adblock-oisd start' will download and setup dnsmasq with a new oisd.txt file. Various checks are performed and, in dependence upon the outcome of those checks, the script will either: accept the new oisd.txt file; fallback to a previous oisd.txt file if available; or restart dnsmasq with no oisd.txt.

In more detail, the start() function of the service performs the following steps:

- attempt to download new oisd.txt file from: https://dnsmasq.oisd.nl (up to 3 retries) to /tmp/oisd.txt
- check oisd.txt file size is < 20000 KB and otherwise return without further processing
- cut out all entries in oisd.txt using the sed filter: '\|^address=/[[:alnum:]]|!d;\|/#$|!d'
- if previous /tmp/dnsmasq.d/oisd.txt exists then temporarily save it to /tmp/oisd.txt.gz
- move the new oisd.txt to /tmp/dnsmasq.d/oisd.txt
- restart dnsmasq
- perform checks and if checks pass then indicate success on logger, remove /tmp/oisd.txt.gz and return without further processing
- if checks fail then extract /tmp/oisd.txt.gz back out to /tmp/dnsmasq.d/oisd.txt and restart dnsmasq
- perform checks again and if they pass then indicate success on logger, remove /tmp/oisd.txt.gz and return without further processing
- if checks fail again then remove /tmp/oisd.txt.gz and /tmp/dnsmasq.d/oisd.txt and restart dnsmasq and indicate adblock-oisd stopped


## Installation on OpenWrt

```bash
wget https://raw.githubusercontent.com/lynxthecat/adblock-oisd/adblock-oisd -O /etc/init.d/adblock-oisd
chmod +x /etc/init.d/adblock-oisd
service enable adblock-oisd
```

## Automatically Update OISD list at 5am Every Day

Set up the following [Scheduled Task](https://openwrt.org/docs/guide-user/base-system/cron):

```bash
0 5 * * * service adblock-oisd enabled; [[ $? -eq 1 ]] && service adblock-oisd start
```
This tests whether the adblock-oisd service is enabled and if so launches the start function, which updates the OISD list. 
