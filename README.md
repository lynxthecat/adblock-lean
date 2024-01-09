# adblock-lean

adblock-lean is a super simple and lightweight adblocking solution that leverages the [major rewrite of the DNS server and domain handling code](https://thekelleys.org.uk/dnsmasq/CHANGELOG) associated with dnsmasq 2.86 that drastically improves performance and reduces memory foot-print, facilitating the use of very large blocklists for even older, low performance devices.

adblock-lean was designed primarily for use with the dnsmasq variants of the popular [hagezi](https://github.com/hagezi/dns-blocklists) and [oisd](https://oisd.nl/) blocklists used by major adblockers and which are intended to block ads without interfering with normal use.  

adblock-lean is written as a service and 'service adblock-lean start' will download and setup dnsmasq with a new blocklist file. Various checks are performed and, in dependence upon the outcome of those checks, the script will either: accept the new blocklist file; fallback to a previous blocklist file if available; or restart dnsmasq with no blocklist file.

adblock-lean includes, inter alia, the following features:

- support for local blocklist and one or more blocklists to be downloaded from urls
- suport for local allowlist
- check individual blocklist file parts and total blocklist size do not exceeed configurable maximum file sizes
- generate blocklist file from local blocklist and allowlist and the one or more downloaded blocklist file part(s)
- check for rogue entries in blocklist file (e.g. check for redirection to specific IP)
- check good lines in blocklist file exceeds configurable minimum (default: 100,000)
- set up dnsmasq with new blocklist file and save any previous blocklist file as compressed file
- perform checks on restarted dnsmasq with new blocklist file
- revert to previous blocklist file if checks fail
- if checks on previous blocklist file also fail then revert to not using any blocklist file
- user-configurable calls on success or failure

## Installation on OpenWrt

```bash
wget https://raw.githubusercontent.com/lynxthecat/adblock-lean/main/adblock-lean -O /etc/init.d/adblock-lean
chmod +x /etc/init.d/adblock-lean
service adblock-lean gen_config # generates default config in /root/adblock-lean/config
vi /root/adblock-lean/config # modify default config as required
service adblock-lean enable
```

## Config

adblock-lean reads in a config file from /root/adblock-lean/config.

A default config can be generated using: `service adblock-lean gen_config`.

Each configuration option is internally documented with comments in /root/adblock-lean/config.

| Variable | Setting                                          |
| -------: | :----------------------------------------------- |
|                   `blocklist_urls` | One or more blocklist URLs to download and process                      |
|             `local_allowlist_path` | Path to local allowlist (domain will not be blocked)                    |
|             `local_blocklist_path` | Path to local blocklist (domain will be blocked)                        |
|  `max_blocklist_file_part_size_KB` | Maximum size of any individual downloaded blocklist part                |
|  `min_blocklist_file_part_size_KB` | Minimum size of any individual downloaded blocklist part                |
|       `max_blocklist_file_size_KB` | Maximim size of combined, preprocessed blocklist                        |
|              `min_good_line_count` | Minimum number of good lines in final postprocessed blocklist           |
|                `remove_duplicates` | Governs whether duplicates are removed: 'ALWAYS', 'DEFAULT' or 'NEVER)' |
|                   `report_failure` | Used for performing user-defined action(s) on failure                   |
|                  `report_successs` | Used for performing user-defined action(s) on success                   |

Concerning `remove_duplicates`, the default behaviour 'DEFAULT' is to only check for, and remove, duplicates when multiple blocklist URLs are specified. 'ALWAYS' results in always checking for, and removing, duplicates, even if just one blocklist URL is specified. Checking for duplicates consumes extra memory during the processing phase, so it should be ensured that sufficient spare memory exists. For lower memory routers or for those that do not care about duplicates, this value can be set to 'NEVER'.   

## Selection of blocklist(s)

An important factor in selecting blocklist(s) is how much free memory is available for blocklist use. It is the responsibility of the user to ensure that there is sufficient free memory to prevent an out of memory situation.

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
- edit /root/adblock-lean/config lines with Brevo specific user details (user variables in CAPITALS below): report_failure="mailsend -port 587 -smtp smtp-relay.sendinblue.com -auth -f FROM@EMAIL.COM -t TO@EMAIL.COM -user BREVOUSERNAME@EMAIL.COM -pass BREVOPASSWORD -sub "$failure_msg" -M " "" report_success="mailsend -port 587 -smtp smtp-relay.sendinblue.com -auth -f FROM@EMAIL.COM -t TO@EMAIL.COM -user BREVOUSERNAME@EMAIL.COM -pass BREVOPASSWORD -sub "$success_msg" -M " ""
- the Brevo password is supplied within their website, not the one created on sign-up.
- with each adblock-lean start call an email with a header such as "New blocklist installed with good line count: 248074." should be sent on success or a failure message sent on failure

## Preserve service file and config across upgrades

Just add the files:

```bash
/root/adblock-lean
/etc/init.d/adblock-lean
```

to the list of files to backup in the Configuration tab in LuCi here:

http://openwrt.lan/cgi-bin/luci/admin/system/flash
