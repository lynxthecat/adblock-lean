# adblock-lean

adblock-lean is a super simple and lightweight adblocking solution that leverages the [major rewrite of the DNS server and domain handling code](https://thekelleys.org.uk/dnsmasq/CHANGELOG) associated with dnsmasq 2.86 that drastically improves performance and reduces memory foot-print, facilitating the use of very large blocklists for even older, low performance devices.

adblock-lean was designed primarily for use with the dnsmasq variant of the [oisd blocklist](https://oisd.nl/) used by major adblockers and which is intended to block ads without interfering with normal use.  

adblock-lean is written as a service and 'service adblock-lean start' will download and setup dnsmasq with a new blocklist file. Various checks are performed and, in dependence upon the outcome of those checks, the script will either: accept the new blocklist file; fallback to a previous blocklist file if available; or restart dnsmasq with no blocklist file.

adblock-lean includes, inter alia, the following features:

- attempt to download new blocklist file from configurable blocklist url (default: https://big.oisd.nl/dnsmasq2) using up to 3 retries
- check downloaded blocklist file size does not exceeed configurable maximum blocklist file size (default: 20 MB)
- check for rogue entries in blocklist file (e.g. check for redirection to specific IP rather than 0.0.0.0)
- check good lines in blocklist file exceeds configurable minimum (default: 100,000)
- set up dnsmasq with new blocklist file and save any previous blocklist file as compressed file
- perform checks on restarted dnsmasq with new blocklist file
- revert to previous blocklist file if checks fail
- if checks on previous blocklist file also fail then revert to not using any blocklist file

## Installation on OpenWrt

```bash
wget https://raw.githubusercontent.com/lynxthecat/adblock-lean/main/adblock-lean -O /etc/init.d/adblock-lean
chmod +x /etc/init.d/adblock-lean
service adblock-lean enable
```

## Automatically deploy blocklist on router reboot

Providing the service is enabled, the service script should automatically start on boot. 

## Automatically update blocklist at 5am following delay by random number of minutes

Set up the following [Scheduled Task](https://openwrt.org/docs/guide-user/base-system/cron):

```bash
0 5 * * * /etc/init.d/adblock-lean enabled && export RANDOM_DELAY="1" && /etc/init.d/adblock-lean start
```
This tests whether the adblock-lean service is enabled and if so launches the start function, which updates to the new blocklist list. 

The random delay serves to prevent a thundering herd: from an altruistic perspective, amelioerate load on oisd server; and from a selfish perspective, increase prospect that server is not loaded during the download. 

## Preserve service file across upgrades

Just add the file:

```bash
/etc/init.d/adblock-lean
```

to the list of files to backup in the Configuration tab in LuCi here:

http://openwrt.lan/cgi-bin/luci/admin/system/flash
