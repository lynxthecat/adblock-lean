# ⚔ adblock-lean

If you like adblock-lean and can benefit from it, then please leave a ⭐ (top right) and become a [stargazer](https://github.com/lynxthecat/adblock-lean/stargazers)! And feel free to post any feedback on the official OpenWrt thread [here](https://forum.openwrt.org/t/adblock-lean-set-up-adblock-using-dnsmasq-blocklist/157076). Thank you for your support.

adblock-lean is **highly optimized for RAM & CPU efficiency** during blocklist downloading & processing, and does not remain running in memory after each execution.  adblock-lean is designed to leverage the [major rewrite of the DNS server and domain handling code](https://thekelleys.org.uk/dnsmasq/CHANGELOG) associated with dnsmasq 2.86, that drastically improves dnsmasq performance and reduces memory foot-print.  This facilitates the use of very large blocklists even for low spec, low performance devices.

The default Hagezi dnsmasq format lists [hagezi](https://github.com/hagezi/dns-blocklists) are recommended to block as many _ads, affiliate, tracking, metrics, telemetry, fake, phishing, malware, scam, coins and other "crap"_ as possible, all while breaking as few websites as possible.  Any other dnsmasq format lists of your choice can also be configured and used.

## Installation on OpenWrt

adblock-lean is written as a service script and is designed to run on a base OpenWrt installation without any dependencies.

```bash
uclient-fetch https://raw.githubusercontent.com/lynxthecat/adblock-lean/main/adblock-lean -O /etc/init.d/adblock-lean
chmod +x /etc/init.d/adblock-lean
service adblock-lean gen_config   # generates default config in /root/adblock-lean/config
uci add_list dhcp.@dnsmasq[0].addnmount='/bin/busybox' && uci commit   # Optional/recommended.  Enables blocklist compression to reduce RAM usage
service adblock-lean enable   # this will allow the script to automatically run on boot
```

A text editor like nano or vi can be used to modify the config file as needed:
```bash
opkg update
opkg install nano
nano /root/adblock-lean/config
```

Whilst adblock-lean does not require any dependencies to run, its performance can be improved by installing `gawk` and `coreutils-sort`:
```bash
opkg update
opkg install gawk coreutils-sort
```

adblock-lean automatically checks for any version updates both at the end of the `start` and `status` routines.
adblock-lean can be updated to the latest version by simply running: 
```bash
service adblock-lean update
```

## Automatically update blocklist at 5am following delay by random number of minutes

Set up the following [Scheduled Task](https://openwrt.org/docs/guide-user/base-system/cron):
```bash
0 5 * * * /etc/init.d/adblock-lean enabled && export RANDOM_DELAY="1" && /etc/init.d/adblock-lean start
```
This tests whether the adblock-lean service is enabled and if so launches the start function, which updates to the new blocklist list. 

The random delay serves to prevent a thundering herd: from an altruistic perspective, amelioerate load on the blocklist server; and from a selfish perspective, increase the prospect that the server is not loaded during the download. 

## Config Updates

During certain updates, adblock-lean will require a configuration update.  adblock-lean will detect any out-of-date configurations and prompt you to automatically update the config, using your existing settings where possible.

A new compatible config can be generated, which will overwrite the previous config fie:
```bash
service adblock-lean gen_config
```

## Features
adblock-lean is written as a service and 'service adblock-lean start' will download and setup dnsmasq with a new blocklist file. Various checks are performed and, in dependence upon the outcome of those checks, the script will either: accept the new blocklist file; fallback to a previous blocklist file if available; or restart dnsmasq with no blocklist file.

adblock-lean includes, inter alia, the following features:

- support for local blocklist and multiple blocklists to be downloaded from urls
- support for local allowlist and multiple allowlists to be downloaded from urls
- check individual blocklist file parts and total blocklist size do not exceeed configurable maximum file sizes
- check for rogue entries in blocklist file parts (e.g. check for redirection to specific IP)
- check good lines in blocklist file exceeds configurable minimum (default: 100,000)
- set up dnsmasq with new blocklist file and save any previous blocklist file as compressed file
- supports blocklist compression by leveraging the new conf-script functionality of dnsmasq
- perform checks on restarted dnsmasq with new blocklist file
- revert to previous blocklist file if checks fail
- if checks on previous blocklist file also fail then revert to not using any blocklist file
- user-configurable script calls on success or failure
- automatically check for any updates and self update functionality



## Config

adblock-lean reads in a config file from `/root/adblock-lean/config`.

A default config can be generated using: `service adblock-lean gen_config`. 

Each configuration option is internally documented with comments in `/root/adblock-lean/config`.

| Variable | Setting                                          |
| -------: | :----------------------------------------------- |
|                     `blocklist_urls` | One or more blocklist URLs to download and process                       |
|                     `allowlist_urls` | One or more allowlist URLs to download and process                       |
|               `local_allowlist_path` | Path to local allowlist (domain will not be blocked)                     |
|               `local_blocklist_path` | Path to local blocklist (domain will be blocked)                         |
| `min_blocklist_file_part_line_count` | Minimum number of lines of individual downloaded blocklist part          |
|    `max_blocklist_file_part_size_KB` | Maximum size of any individual downloaded blocklist part                 |
|         `max_blocklist_file_size_KB` | Maximim size of combined, processed blocklist                            |
|                `min_good_line_count` | Minimum number of good lines in final postprocessed blocklist            |
|                 `compress_blocklist` | Enable (1) or disable (0) blocklist compression once dnsmasq loaded      |
|            `initial_dnsmasq_restart` | Enable (1) or disable (0) initial dnsmasq restart to free up memory      |
|               `max_download_retries` | Maximum number of download retries for allowlist/blocklist parts         |
|            `list_part_failed_action` | Governs failed lists handling: 'SKIP_PARTIAL' or 'STOP'                  |
|                      `custom_script` | Path to custom user scripts to execute on success on failure             |
|                 `boot_start_delay_s` | Start delay in seconds when service is started from system boot          |

For devices with low free memory, consider enabling the `initial_dnsmasq_restart` option to free up memory for use during the memory-intensive blocklist generation process by additionally restarting dnsmasq with no blocklist prior to the generation of the new blocklist. This option is disabled by default to prevent both the associated: dnsmasq downtime; and the temporary running of dnsmasq with no blocklist.

## Selection of blocklist(s) and download and processing parameters

An important factor in selecting blocklist(s) is how much free memory is available for blocklist use. It is the responsibility of the user to ensure that there is sufficient free memory to prevent an out of memory situation.

The parameters described in the config section above relating to the intermediate sizes, good line count and duplicate removal should be set in dependence on the selected blocklist and available memory. These are considered self-explanatory, but if in any doubt please post on the OpenWrt thread at: 

https://forum.openwrt.org/t/adblock-lean-set-up-adblock-using-dnsmasq-blocklist/157076.

Here are some example configuration settings:

- Mini 64mb routers. Aim for <100k entries. Example below: circa 85k entries
```bash
blocklist_urls="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.mini.txt"
min_blocklist_file_part_line_count=1
max_blocklist_file_part_size_KB=4000
max_blocklist_file_size_KB=4000
min_good_line_count=40000
```

- Small 128mb routers. Aim for <300k entries. Example below: circa 250k entries
```bash
blocklist_urls="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/tif.mini.txt"
min_blocklist_file_part_line_count=1
max_blocklist_file_part_size_KB=7000
max_blocklist_file_size_KB=10000
min_good_line_count=100000
```

- Medium 256mb routers. Aim for <600k entries. Example below: circa 350k entries
```bash
blocklist_urls="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/tif.medium.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/popupads.txt"
min_blocklist_file_part_line_count=1
max_blocklist_file_part_size_KB=10000
max_blocklist_file_size_KB=20000
min_good_line_count=200000
```

- Large =>512mb routers. Example below: circa 900k entries
```bash
blocklist_urls="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/pro.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/tif.txt"
min_blocklist_file_part_line_count=1
max_blocklist_file_part_size_KB=30000
max_blocklist_file_size_KB=50000
min_good_line_count=200000
```
An excellent breakdown of highly suitable lists and their merits is provided at:

https://github.com/hagezi/dns-blocklists


## User-configurable calls on success or failure

adblock-lean supports specifying a custom script to define the functions `report_success` and `report_failure` to be called on success or failure (can be used to eg send an email/SMS/msg)

**Example below for free Brevo (formerly sendinblue) email service, but use your favourite smtp/email/SMS etc method.**

- Install mailsend package in OpenWRT
- Sign up for free Brevo account (not affiliated!) - provides 300 free email sends per day
- Edit your config file custom_script path.  Recommended path is '/usr/libexec/abl_custom-script.sh', which the adblock-lean luci app will have permission to access (for when the luci app is ready)
- Create file /usr/libexec/abl_custom-script.sh - specific user details (user variables in CAPITALS below):

```bash
#!/bin/sh

report_success()
{
mailbody="Most recent lines from the log:"$'\n'"$(logread -e adblock-lean | tail -n 35)"
mailsend -port 587 -smtp smtp-relay.sendinblue.com -auth -f FROM@EMAIL.COM -t TO@EMAIL.COM -user BREVO@USERNAME.COM -pass PASSWORD -sub "${1}" -M "${mailbody}"
}

report_failure()
{
mailbody="${1}"$'\n'$'\n'"Most recent lines from the log:"$'\n'"$(logread -e adblock-lean | tail -n 35)"
mailsend -port 587 -smtp smtp-relay.sendinblue.com -auth -f FROM@EMAIL.COM -t TO@EMAIL.COM -user BREVO@USERNAME.COM -pass PASSWORD -sub "Adblock-lean blocklist update failed" -M "${mailbody}"
}
```

- the Brevo password is supplied within their website, not the one created on sign-up.
- If copy-pasting from Windows, avoid copy-pasting Windows-style newlines. To make sure, in Windows use a text editor which supports changing newline style (such as Notepad++) and make sure it is set to Unix (LF), rather than Windows (CR LF).

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


## Preserve service file and config across OpenWrt upgrades

Just add the files:

```bash
/etc/init.d/adblock-lean
/root/adblock-lean
/root/allowlist   # if used with your config
/root/blocklist   # if used with your config
```

to the list of files to backup in the Configuration tab in LuCi here:

http://openwrt.lan/cgi-bin/luci/admin/system/flash

## :stars: Stargazers <a name="stargazers"></a>

[![Star History Chart](https://api.star-history.com/svg?repos=lynxthecat/adblock-lean&type=Date)](https://star-history.com/#lynxthecat/adblock-lean&Date)
