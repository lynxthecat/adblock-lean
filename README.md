# ⚔ adblock-lean

If you like adblock-lean and can benefit from it, then please leave a ⭐ (top right) and become a [stargazer](https://github.com/lynxthecat/adblock-lean/stargazers)! And feel free to post any feedback on the official OpenWrt thread [here](https://forum.openwrt.org/t/adblock-lean-set-up-adblock-using-dnsmasq-blocklist/157076). Thank you for your support.

adblock-lean is a super simple and lightweight adblocking solution that leverages the [major rewrite of the DNS server and domain handling code](https://thekelleys.org.uk/dnsmasq/CHANGELOG) associated with dnsmasq 2.86 that drastically improves performance and reduces memory foot-print, facilitating the use of very large blocklists for even older, low performance devices.

adblock-lean was originally designed primarily for use with the dnsmasq variants of the popular [hagezi](https://github.com/hagezi/dns-blocklists) and [oisd](https://oisd.nl/) blocklists used by major adblockers and which are intended to block ads without interfering with normal use.  

adblock-lean is written as a service and 'service adblock-lean start' will download and setup dnsmasq with a new blocklist file. Various checks are performed and, in dependence upon the outcome of those checks, the script will either: accept the new blocklist file; fallback to a previous blocklist file if available; or restart dnsmasq with no blocklist file.

adblock-lean includes, inter alia, the following features:

- support for local blocklist and one or more blocklists to be downloaded from urls
- suport for local allowlist
- check individual blocklist file parts and total blocklist size do not exceeed configurable maximum file sizes
- generate blocklist file from local blocklist and allowlist and the one or more downloaded blocklist file part(s)
- check for rogue entries in blocklist file parts (e.g. check for redirection to specific IP)
- check good lines in blocklist file exceeds configurable minimum (default: 100,000)
- set up dnsmasq with new blocklist file and save any previous blocklist file as compressed file
- supports blocklist compression by leveraging the new conf-script functionality of dnsmasq
- perform checks on restarted dnsmasq with new blocklist file
- revert to previous blocklist file if checks fail
- if checks on previous blocklist file also fail then revert to not using any blocklist file
- user-configurable calls on success or failure
- automatically check for any updates and self update functionality

## Installation on OpenWrt

adblock-lean is written as a service script and is designed to run on a base OpenWrt installation without any dependencies.

Example installation steps:

```bash
wget https://raw.githubusercontent.com/lynxthecat/adblock-lean/main/adblock-lean -O /etc/init.d/adblock-lean
chmod +x /etc/init.d/adblock-lean
service adblock-lean gen_config # generates default config in /root/adblock-lean/config
vi /root/adblock-lean/config # modify default config as required
uci add_list dhcp.@dnsmasq[0].addnmount='/bin/busybox' && uci commit # to enable use of compressed blocklist
service adblock-lean enable
```

Whilst adblock-lean does not require any dependencies to run, its performance can be improved by installing `gawk` and `coreutils-sort`:

```bash
opkg update
opkg install gawk coreutils-sort
```

## Config

adblock-lean reads in a config file from /root/adblock-lean/config.

A default config can be generated using: `service adblock-lean gen_config`.

Each configuration option is internally documented with comments in /root/adblock-lean/config.

| Variable | Setting                                          |
| -------: | :----------------------------------------------- |
|                     `blocklist_urls` | One or more blocklist URLs to download and process                   |
|               `local_allowlist_path` | Path to local allowlist (domain will not be blocked)                 |
|               `local_blocklist_path` | Path to local blocklist (domain will be blocked)                     |
| `min_blocklist_file_part_line_count` | Minimum number of lines of individual downloaded blocklist part      |
|    `max_blocklist_file_part_size_KB` | Maximum size of any individual downloaded blocklist part             |
|         `max_blocklist_file_size_KB` | Maximim size of combined, processed blocklist                        |
|                `min_good_line_count` | Minimum number of good lines in final postprocessed blocklist        |
|                 `compress_blocklist` | Enable (1) or disable (0) blocklist compression once dnsmasq loaded  |
|            `initial_dnsmasq_restart` | Enable (1) or disable (0) initial dnsmasq restart to free up memory  |
|               `rogue_element_action` | Governs rogue element handling: 'SKIP_PARTIAL', 'STOP' or 'IGNORE'   |
|             `download_failed_action` | Governs failed download handling: 'SKIP_PARTIAL' or 'STOP'           |
|                     `report_failure` | Used for performing user-defined action(s) on failure                |
|                    `report_successs` | Used for performing user-defined action(s) on success                |
|                 `boot_start_delay_s` | Start delay in seconds when service is started from system boot      |

For devices with low free memory, consider enabling the `initial_dnsmasq_restart` option to free up memory for use during the memory-intensive blocklist generation process by additionally restarting dnsmasq with no blocklist prior to the generation of the new blocklist. This option is disabled by default to prevent both the associated: dnsmasq downtime; and the temporary running of dnsmasq with no blocklist.

## Selection of blocklist(s)

An important factor in selecting blocklist(s) is how much free memory is available for blocklist use. It is the responsibility of the user to ensure that there is sufficient free memory to prevent an out of memory situation.

Here are two examples for low and high memory devices.

Example blocklist selection for low memory devices:

```
blocklist_urls="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/light.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/native.winoffice.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/native.apple.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/native.amazon.txt"
```

Example blocklist selection for high memory devices:

```
blocklist_urls="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/tif.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/tif-ips.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/native.winoffice.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/native.apple.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/native.amazon.txt"
```

An excellent breakdown of highly suitable lists and their merits is provided at:

https://github.com/hagezi/dns-blocklists

## Selection of blocklist download and processing parameters

The parameters described in the config section above relating to the intermediate sizes, good line count and duplicate removal should be set in dependence on the selected blocklist and available memory. These are considered self-explanatory, but if in any doubt please post on the OpenWrt thread at: 

https://forum.openwrt.org/t/adblock-lean-set-up-adblock-using-dnsmasq-blocklist/157076.

## Automatically deploy blocklist on router reboot

Providing the service is enabled, the service script should automatically start on boot. 

## Automatically update blocklist at 5am following delay by random number of minutes

Set up the following [Scheduled Task](https://openwrt.org/docs/guide-user/base-system/cron):

```bash
0 5 * * * /etc/init.d/adblock-lean enabled && export RANDOM_DELAY="1" && /etc/init.d/adblock-lean start
```
This tests whether the adblock-lean service is enabled and if so launches the start function, which updates to the new blocklist list. 

The random delay serves to prevent a thundering herd: from an altruistic perspective, amelioerate load on the blocklist server; and from a selfish perspective, increase the prospect that the server is not loaded during the download. 

## User-configurable calls on success or failure

adblock-lean supports user-configurable calls on success or failure. 

The following config paramters:
```
report_failure="" 	 
report_success=""
```

Are evaluated on success or failure, and the variables: ${success_msg} and ${failure_msg} can be employed in the calls. 

**Example below for Brevo (formerly sendinblue), but use your favourite smtp/email (or SMS) method.**

- install mailsend package in OpenWRT
- sign up for free Brevo account (not affiliated!) - provides 300 free email sends per day
- edit /root/adblock-lean/config lines with Brevo specific user details (user variables in CAPITALS below):
  ```bash
  report_failure="mailbody=\$(logread -e adblock-lean | tail -n 35); mailsend -port 587 -smtp smtp-relay.sendinblue.com -auth -f FROM@EMAIL.com -t TO@EMAIL.com -user SENDINBLUE@USERNAME.com -pass PASSWORD -sub \"\$failure_msg\" -M \"\$mailbody\""
  report_success="mailbody=\$(logread -e adblock-lean | tail -n 35); mailsend -port 587 -smtp smtp-relay.sendinblue.com -auth -f FROM@EMAIL.com -t TO@EMAIL.com -user SENDINBLUE@USERNAME.com -pass PASSWORD -sub \"\$success_msg\" -M \"\$mailbody\""
  ```
- the Brevo password is supplied within their website, not the one created on sign-up.
- with each adblock-lean start call an email with a header such as "New blocklist installed with good line count: 248074." should be sent on success or a failure message sent on failure

## Checking status of adblock-lean

The status of a running adblock-lean instance can be obtained by running:

```bash
service adblock-lean status
```

Example output:

```bash
root@OpenWrt-1:~# service adblock-lean status
Checking dnsmasq instance.
The dnsmasq check passed and the presently installed blocklist has good line count: 736225.
adblock-lean appears to be active.
Generating dnsmasq stats.
dnsmasq stats available for reading using 'logread'.
The locally installed adblock-lean is the latest version.
```

## Keeping adblock-lean up-to-date

adblock-lean automatically checks for any version updates both at the end of the `start` and `status` routines.

adblock-lean can be updated to the latest version by simply running: 

```bash
service adblock-lean update
```

## Preserve service file and config across OpenWrt upgrades

Just add the files:

```bash
/root/adblock-lean
/etc/init.d/adblock-lean
```

to the list of files to backup in the Configuration tab in LuCi here:

http://openwrt.lan/cgi-bin/luci/admin/system/flash

## :stars: Stargazers <a name="stargazers"></a>

[![Star History Chart](https://api.star-history.com/svg?repos=lynxthecat/adblock-lean&type=Date)](https://star-history.com/#lynxthecat/adblock-lean&Date)
