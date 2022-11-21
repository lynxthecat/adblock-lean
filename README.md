# adblock-oisd
Set up adblock using the highly popular [oisd dnsmasq file](https://oisd.nl/) used by major adblockers and which is intended to block ads without interfering with normal use. 

adblock-oisd is written as a service and 'service adblock-oisd start' will download and setup dnsmasq with a new oisd.txt file. Various checks are performed and, in dependence upon the outcome of those checks, the script will either: accept the new oisd.txt file; fallback to a previous oisd.txt file if available; or restart dnsmasq with no oisd.txt.

adblock-oisd includes, inter alia, the following features:

- attempt to download new oisd.txt file from: https://dnsmasq.oisd.nl (up to 3 retries) to /tmp/oisd.txt
- check downloaded oisd.txt size does not exceeed 20 MB
- first pass check for rogue entries on oisd.txt (e.g. check for redirection to specific IP rather than 0.0.0.0)
- second pass filter on oisd.txt to filter out malformed, but non-rogue, entries
- set up dnsmasq with new oisd.txt and save any previous oisd.txt as compressed file
- perform checks on restarted dnsmasq with new oisd.txt
- revert to previous oisd.txt if checks fail
- if checks on previous oisd.txt also fail then revert to not using any oisd.txt

## Installation on OpenWrt

```bash
wget https://raw.githubusercontent.com/lynxthecat/adblock-oisd/adblock-oisd -O /etc/init.d/adblock-oisd
chmod +x /etc/init.d/adblock-oisd
service enable adblock-oisd
```

## Automatically Deploy OISD list on router reboot

Edit rc.local (in LuCi navigate to System->Startup) to include the line:

```bash
0 5 * * * /etc/init.d/adblock-oisd enabled && /etc/init.d/adblock-oisd start
```

## Automatically Update OISD list at 5am Every Day

Set up the following [Scheduled Task](https://openwrt.org/docs/guide-user/base-system/cron):

```bash
0 5 * * * /etc/init.d/adblock-oisd enabled && /etc/init.d/adblock-oisd start
```
This tests whether the adblock-oisd service is enabled and if so launches the start function, which updates to the new OISD list. 
