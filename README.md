# ⚔ adblock-lean

adblock-lean provides powerful and ultra-efficient adblocking on OpenWrt. It is  **highly optimized for RAM & CPU efficiency** during blocklist download & processing, and does not remain running in memory after execution.  adblock-lean is designed to leverage the [major rewrite of the DNS server and domain handling code](https://thekelleys.org.uk/dnsmasq/CHANGELOG) associated with dnsmasq 2.86, which drastically improves dnsmasq performance and reduces memory footprint. This facilitates the use of very large blocklists even for low spec, low performance devices.

If you like adblock-lean and can benefit from it, then please leave a ⭐ (top right) and become a [stargazer](https://github.com/lynxthecat/adblock-lean/stargazers)! And feel free to post any feedback on the official OpenWrt thread [here](https://forum.openwrt.org/t/adblock-lean-set-up-adblock-using-dnsmasq-blocklist/157076). Thank you for your support.

## Features

adblock-lean includes the following features:

- support multiple blocklist files downloaded from user-specified urls
- support local blocklist
- same for downloaded and local allowlists
- support whitelist mode
- removal of domains found in the allowlist from the blocklist files
- combining all downloaded and local lists into one final blocklist file
- check that each individual blocklist and allowlist file does not exceed configurable maximum size
- check that the total blocklist size does not exceeed configurable maximum file size
- check for rogue entries in blocklist file parts (e.g. check for redirection to specific IP)
- check that line count in blocklist file does not exceed configurable minimum (default: 100,000)
- save a compressed copy of the previous blocklist file, then load the new combined blocklist file into dnsmasq
- supports blocklist compression by leveraging the new conf-script functionality of dnsmasq
- perform checks on restarted dnsmasq with new blocklist file
- revert to previous blocklist file if checks fail
- if checks on previous blocklist file also fail then revert to not using any blocklist file
- implements optional calls to user-configurable script on success or failure (for example to send an email report)
- automatically check for application updates and self update functionality
- config keys and values validation and optional automatic config repair when problems are detected
- automated interactive setup

## Installation on OpenWrt

Connect to your OpenWrt router [via SSH](https://openwrt.org/docs/guide-quick-start/sshadministration) and then follow the guide below.

To download adblock-lean, use the following command:
```bash
uclient-fetch https://raw.githubusercontent.com/lynxthecat/adblock-lean/main/adblock-lean -O /etc/init.d/adblock-lean
```

adblock-lean includes automated interactive setup which makes it easy to get going. If you prefer manual setup, skip the following section.

### Automated interactive setup

```bash
sh /etc/init.d/adblock-lean setup
```

This will ask you several questions and make all important changes automatically, based on your replies.

### Manual setup
```bash
chmod +x /etc/init.d/adblock-lean # Makes the script executable
service adblock-lean gen_config   # Generates default config in /root/adblock-lean/config and sets up blocklist updates

# This will allow adblock-lean to automatically run on boot
service adblock-lean enable

# Optional/recommended. Makes list processing significantly faster (doesn't affect DNS resolution speed). gawk including dependencies may consume around 1MB. If flash space is an issue, consider skipping gawk installation.
opkg update
opkg install gawk sed coreutils-sort
```

The above command `service adblock-lean gen_config` should have automatically determined the dnsmasq instance to attach to, or asked you which instance you prefer (in case you have multiple instances). So unless you have a really good reason, ignore the following section.

_<details><summary>If you need to manually configure the dnsmasq instance adblock-lean attaches to </summary>_

1) Check which `config dnsmasq` sections are defined in `/etc/config/dhcp`.
2) If only one `config dnsmasq` section exists then you are only running 1 dnsmasq instance. Note and write down: instance index is 0; instance name (it's either `cfg01411c` if the name is not specified or the optional word right after `config dnsmasq`); if `option confdir` is set, note and write down the value. If it is not set then the default conf-dir is `/tmp/dnsmasq.cfg01411c.d` in OpenWrt 24.10 and later (including current snapshots), or `/tmp/dnsmasq.d` in older OpenWrt versions.
3) If you have multiple `config dnsmasq` sections then multiple dnsmasq instances are running on your device. Then you should know which dnsmasq instance you want adblocking to work on. Use the command `/etc/init.d/dnsmasq info` to get a list of all running instances as json. Find the relevant dnsmasq instance. Note: instance index (1st instance has index 0, further instances increment the index by 1); instance name (example: `cfg01411c`); which network interfaces the relevant instance serves (likely listed in the 'netdev' section). In the `"command"` section of the json, look for a path in `/var/etc/`, write down the path. Check the contents of the file at that path and look for `conf_dir=`. This is the conf-dir this instance is using - note and write it down.
4) In the adblock-lean config file: specify instance name in option `DNSMASQ_INSTANCE` (example: `DNSMASQ_INSTANCE="cfg01411c"`); specify instance index in option `DNSMASQ_INDEX` (example: `DNSMASQ_INDEX="0"`), specify instance conf-dir in option `DNSMASQ_CONF_D` (example: `DNSMASQ_CONF_D="/tmp/dnsmasq.d"`).

</details>

Optional/recommended: enable blocklist compression to reduce RAM usage. To achieve this, add the line
```
	list addnmount '/bin/busybox'
```
to the relevant dnsmasq section (under `config dnsmasq`) of file `/etc/config/dhcp`.

If only one `config dnsmasq` section exists then that's the section to add the line to. If you have multiple `config dnsmasq` sections, this means that multiple dnsmasq instances are running on your device. Then you should know which dnsmasq instance you want adblocking to work on - add the line to that section. Verify that same dnsmasq instance index is configured in `/etc/adblock-lean/config` (1st instance corresponds to the 1st `config dnsmasq` section and has index 0, further instances increment the index by 1).

Now run the command `service dnsmasq restart`.

## Usage

adblock-lean is written as a service and `service adblock-lean start` will process any local blocklist/allowlist, download blocklist/allowlist parts, generate a new merged blocklist file and set up dnsmasq with it. Various checks are performed and, depending on the outcome of those checks, the script will either: accept the new blocklist file; reject the blocklist file if it didn't pass the checks and fallback to a previous blocklist file if available; or as a last resort restart dnsmasq with no blocklist file.

Additional available commands:
- `stop`: stops any running adblock-lean instances, unloads the blocklist and removes it from memory
- `restart`: runs the `stop`, then `start` commands
- `pause`: unloads the blocklist and creates a compressed copy of it
- `resume`: decompresses the blocklist and loads it into dnsmasq
- `update`: pulls an update for adblock-lean from Github (if available) and installs the updated version
- `uninstall`: removes the adblock-lean service and optionally adblock-lean settings, and undoes any other changes adblock-lean made to the system
- `gen_config`: generate default config based on one of the pre-defined presets
- `setup`: run automated setup for adblock-lean
- `status`: check dnsmasq and entries count of the active blocklist.
            If adblock-lean is doing something in the background, `status` will print which operation is currently performed.
- `gen_stats`: generate dnsmasq stats (prints to system log)
- `print_log`: print most recent session log
- `upd_cron_job`: create cron job for adblock-lean with schedule set in the config option 'cron_schedule'.
                  if config option set to 'disable', remove existing cron job if any
- `select_dnsmasq_instance`: analyze dnsmasq instances and set required options in the adblock-lean config

## Basic configuration
The config file for adblock-lean is located in `/etc/adblock-lean/config`.

A new compatible config can be generated automatically, which will overwrite the previous config fie:
```bash
service adblock-lean gen_config
```

The `setup` command is available after installation as well:
```bash
service adblock-lean setup # runs the interactive setup routine
```

For manual configuration, a text editor like nano or vi can be used to modify the config file:
```bash
opkg update
opkg install nano
nano /etc/adblock-lean/config
```

### Automatic blocklist updates
Automatic blocklist updates can be enabled via a cron job. When enabled, adblock-lean will run according to schedule specified in the config file, with a delay of random number of minutes (0-60).

The random delay serves to prevent a thundering herd: from an altruistic perspective, amelioerate load on the blocklist server; and from a selfish perspective, increase the prospect that the server is not loaded during the download. 

To enable automatic blocklist updates or to change the update schedule, look for the option `cron_schedule=` in the config file and define your preferred cron schedule:
```
cron_schedule="<your_cron_schedule>"
```
Example: `cron_schedule="0 5 * * *"` for daily updates at 5 am

Currently adblock-lean does not validate the schedule you set in config, so make sure that your custom schedule complies to the crontab syntax.

To disable automatic blocklist updates, change the value for the `cron_schedule` option to `disable`:
```
cron_schedule="disable"
```

**Important:** After changing the schedule in the config, run the following command to have adblock-lean create/update/remove the cron job:
`service adblock-lean upd_cron_job`

## Supported formats

**USER NOTICE:**  Current versions September 19, 2024 and onwards switch to using raw formatted blocklists by default (the default lists are still Hagezi).  Dnsmasq formatted lists are still supported.  Raw lists have the benefit of smaller file size dowload, improvements in processing speed and reduced ram usage.  On the first run after updating, adblock-lean will prompt you (y/n) to automatically change URLs for Hagezi & OISD lists from dnsmasq format to raw format.  For other lists, you can choose to find a raw formatted list or continue using dnsmasq formatted lists.  You can always use ```service adblock-lean gen_config``` to generate a fresh configuration file if required.

The default Hagezi lists [hagezi](https://github.com/hagezi/dns-blocklists) are recommended to block as many _ads, affiliate, tracking, metrics, telemetry, fake, phishing, malware, scam, coins and other "crap"_ as possible, all while breaking as few websites as possible.

Hagezi **raw domains-formatted lists** can be found [here](https://github.com/hagezi/dns-blocklists/tree/main/wildcard). **NOTE** that the file names of correct lists have the `-onlydomains` suffix.
Visual example of raw ```blocklist_urls``` [Hagezi light raw](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt).  
Visual example of dnsmasq formmatted ```dnsmasq_blocklist_urls``` [Hagezi light dnsmasq](https://raw.githubusercontent.com/hagezi/dns-blocklists/main/dnsmasq/light.txt).

oisd raw domains-formatted lists can be found [here](https://oisd.nl/setup/adblock-lean). **NOTE** that the correct lists are **only** the ones named `domainswild2` (note the `2`).
oisd dnsmasq-formatted lists can be found at the same URL, except you would be looking for lists named `dnsmasq2`.

Any other raw or dnsmasq format lists of your choice can also be configured and used.

## Advanced configuration

adblock-lean reads in a config file from `/etc/adblock-lean/config`

Default config can be generated using: `service adblock-lean gen_config`.

Each configuration option is internally documented with comments in `/etc/adblock-lean/config`. Short version:

| Option                              | Description                                                                                   |
| :-----------------------------------| :-------------------------------------------------------------------------------------------- |
|`whitelist_mode`                     | Block all domains except domains in the allowlists and their subdomains. 1/0 to enable/disable|
|`blocklist_urls`                     | One or more raw blocklist URLs to download and process                                        |
|`blocklist_ipv4_urls`                | One or more raw ipv4 blocklist URLs to download and process                                   |
|`allowlist_urls`                     | One or more raw allowlist URLs to download and process                                        |
|`dnsmasq_blocklist_urls`             | One or more dnsmasq format blocklist URLs to download and process                             |
|`dnsmasq_blocklist_ipv4_urls`        | One or more dnsmasq format ipv4 blocklist URLs to download and process                        |
|`dnsmasq_allowlist_urls`             | One or more dnsmasq format allowlist URLs to download and process                             |
|`local_allowlist_path`               | Path to local allowlist (included domains will not be blocked)                                |
|`local_blocklist_path`               | Path to local blocklist (included domains will be blocked)                                    |
|`test_domains`                       | Domains used to test DNS resolution after loading the final blocklist                         |
|`list_part_failed_action`            | Governs failed lists handling: 'SKIP' or 'STOP'                                               |
|`max_download_retries`               | Maximum number of download retries for allowlist/blocklist parts                              |
|`min_good_line_count`                | Minimum number of good lines in final postprocessed blocklist                                 |
|`min_blocklist_part_line_count`      | Minimum number of lines of individual downloaded blocklist part                               |
|`min_blocklist_ipv4_part_line_count` | Minimum number of lines of individual downloaded ipv4 blocklist part                          |
|`min_allowlist_part_line_count`      | Minimum number of lines of individual downloaded allowlist part                               |
|`max_file_part_size_KB`              | Maximum size in KB of any individual downloaded blocklist part                                |
|`max_blocklist_file_size_KB`         | Maximim size in KB of combined, processed blocklist                                           |
|`deduplication`                      | Whether to perform sorting and deduplication of entries                                       |
|`use_compression`                    | Compress while processing, and final blocklists. Reduces memory usage. 1/0 to enable/disable  |
|`initial_dnsmasq_restart`            | Initial dnsmasq restart to free up memory. 1/0 to enable/disable                              |
|`boot_start_delay_s`                 | Start delay in seconds when service is started from system boot                               |
|`custom_script`                      | Path to custom user script to execute on success on failure                                   |
|`cron_schedule`                      | Crontab schedule for automatic blocklist updates or `disable`                                 |

For devices with low free memory, consider enabling the `initial_dnsmasq_restart` option to free up memory for use during the memory-intensive blocklist generation process by additionally restarting dnsmasq with no blocklist prior to the generation of the new blocklist. This option is disabled by default to prevent both the associated: dnsmasq downtime; and the temporary running of dnsmasq with no blocklist.

## Selection of blocklists and associated parameters

An important factor in selecting blocklist(s) is how much free memory is available for blocklist use. It is the responsibility of the user to ensure that there is sufficient free memory to prevent an out of memory situation.

The parameters described in the config section above relating to the intermediate sizes, blocklist line count and deduplication should be set according to the selected blocklists and available memory. These are considered self-explanatory, but if in any doubt please post on the OpenWrt thread at: 

https://forum.openwrt.org/t/adblock-lean-set-up-adblock-using-dnsmasq-blocklist/157076.

adblock-lean includes 4 pre-defined presets (mini, small, medium, large), each one intended for devices with a certain total memory capacity. When running `adblock-lean setup` or `adblock-lean gen_config`, you can select one of these presets and have the corresponding config options automatically set.

The pre-defined presets are:

- **Mini**: for devices with 64MB of RAM. Aim for <100k entries. This preset includes circa 85k entries
```bash
blocklist_urls="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.mini-onlydomains.txt"
max_file_part_size_KB="2000"
max_blocklist_file_size_KB="2000"
min_good_line_count="20000"
```

- **Small**: for devices with 128MB of RAM. Aim for <300k entries. This preset includes circa 250k entries
```bash
blocklist_urls="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro-onlydomains.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.mini-onlydomains.txt"
max_file_part_size_KB="4000"
max_blocklist_file_size_KB="6000"
min_good_line_count="80000"
```

- **Medium**: for devices with 256MB of RAM. Aim for <600k entries. This preset includes circa 450k entries
```bash
blocklist_urls="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro-onlydomains.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.medium-onlydomains.txt"
max_file_part_size_KB="8000"
max_blocklist_file_size_KB="10000"
min_good_line_count="150000"
```

- **Large**: for devices with 512MB of RAM. This preset includes circa 1M entries
```bash
blocklist_urls="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro-onlydomains.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif-onlydomains.txt"
max_file_part_size_KB="19000"
max_blocklist_file_size_KB="24000"
min_good_line_count="330000"

```
- **Large-Relaxed**: for devices with 1024MB of RAM or more. This preset includes circa 1M entries and same default blocklist URLs as 'Large' but the `max` values are more relaxed and allow for larger fluctuations in downloaded blocklist sizes.
```bash
blocklist_urls="https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro-onlydomains.txt https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif-onlydomains.txt"
max_file_part_size_KB="39000"
max_blocklist_file_size_KB="48000"
min_good_line_count="330000"
```

An excellent breakdown of highly suitable lists and their merits is provided at:

https://github.com/hagezi/dns-blocklists

## Whitelist mode
This mode can be used to implement parental control or similar functionality while also adblocking inside the allowed domains. It can be enabled by setting the config option `whitelist_mode` to `1`. In this mode all domain names will be blocked, except for domains (and their subdomains) included in local and/or downloaded allowlists. In this mode, if blocklists are used in addition to allowlists, addresses which are included in the blocklists and which are subdomains of allowed domains - will be blocked as well.

For example, if the an allowlist has this entry: `google.com` and a blocklist has this entry: `ads.google.com`, and `whitelist_mode` is set to `1`, then `ads.google.com` will be blocked, while `google.com` and `mail.google.com` (and any other subdomain of `google.com` which is not included in the blocklist) will work.

Note that in this mode, the test domains (specified via the option `test_domains`) will be automatically added to the allowlist in order for the checks to pass. You can use empty string in that option - this will bypass that check and block the default domains (google.com, microsoft.com, amazon.com). Alternatively, you can specify preferred test domains instead of the default ones.

Also note that in this mode by default the Github domains will be blocked, so the automatic adblock-lean version update functionality will not work - unless you add `raw.githubusercontent.com` to the allowlist.

The resulting blocklist generated in whitelist mode will be typically much smaller than otherwise, so you may need to reduce the value of the `min_good_line_count` option in order for the list to be accepted by adblock-lean.

## User-configurable calls on success or failure

adblock-lean supports specifying a custom script which defines the functions `report_success` and `report_failure` to be called on success or failure (can be used to eg send an email/SMS/msg)

**Example below for free Brevo (formerly sendinblue) email service, but use your favourite smtp/email/SMS etc method.**

- Install mailsend package in OpenWRT
- Sign up for free Brevo account (not affiliated!) - provides 300 free email sends per day
- Edit your config file custom_script path.  Recommended path is '/usr/libexec/abl_custom-script.sh', which the adblock-lean luci app will have permission to access (for when the luci app is ready)
- Create file `/usr/libexec/abl_custom-script.sh` - specific user details (user variables in CAPITALS below):

```bash
#!/bin/sh

report_success()
{
mailbody="${1}"
mailsend -port 587 -smtp smtp-relay.brevo.com -auth -f FROM@EMAIL.COM -t TO@EMAIL.COM -user BREVO@USERNAME.COM -pass PASSWORD -sub "Adblock-lean blocklist update success" -M "${mailbody}"
}

report_failure()
{
mailbody="${1}"
mailsend -port 587 -smtp smtp-relay.brevo.com -auth -f FROM@EMAIL.COM -t TO@EMAIL.COM -user BREVO@USERNAME.COM -pass PASSWORD -sub "Adblock-lean blocklist update failed" -M "${mailbody}"
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

```
root@OpenWrt:~# service adblock-lean status
Checking dnsmasq instance.
The dnsmasq check passed and the presently installed blocklist has good line count: 736225.
adblock-lean appears to be active.
Generating dnsmasq stats.
dnsmasq stats available for reading using 'logread'.
The locally installed adblock-lean is the latest version.
```

## Testing advert blocking

Verify adverts are removed from newspaper sites and e.g. https://www.speedtest.net/. 

This test can also be helpful: https://d3ward.github.io/toolz/adblock

## Preserve service file and config across OpenWrt upgrades

Just add the files:

```bash
/etc/init.d/adblock-lean
/etc/adblock-lean/
/etc/adblock-lean/config
/etc/adblock-lean/allowlist   # if used with your config
/etc/adblock-lean/blocklist   # if used with your config
```

to the list of files to backup in the Configuration tab in LuCi here:

http://openwrt.lan/cgi-bin/luci/admin/system/flash

After completing sysupgrade, run the interactive setup again to re-enable adblock-lean:
`sh /etc/init.d/adblock-lean setup`. To preserve your old config, answer `e` when asked this question:
`Generate [n]ew config or use [e]xisting config?`


## adblock-lean version updates

adblock-lean automatically checks for version updates at the end of the `start` and `status` routines and prints a message if an update is available.

adblock-lean can be updated to the latest version by simply running:
```bash
service adblock-lean update
```

During certain updates, adblock-lean will require a configuration update. adblock-lean will detect any out-of-date configurations and prompt you to automatically update the config, using your existing settings where possible.

If automatic config update fails for any reason, a new compatible config can be generated, which will overwrite the previous config fie:
```bash
service adblock-lean gen_config
```

After updating adblock-lean, run the command:
```bash
service adblock-lean start
```

## Uninstalling

To uninstall adblock-lean, run:
`service adblock-lean uninstall`
or
`sh /etc/init.d/adblock-lean uninstall`

## :stars: Stargazers <a name="stargazers"></a>

[![Star History Chart](https://api.star-history.com/svg?repos=lynxthecat/adblock-lean&type=Date)](https://star-history.com/#lynxthecat/adblock-lean&Date)
