# Bash Uptime Monitor / Pi Monitor

This is a simple bash script uptime monitor designed for simplicity and efficiency. It runs on a Raspberry Pi 2, which is why its internal name is Pi Monitor, and that's what's used in the filenames. I realised it might be useful to others, so I'm sharing it, and given it a more meaningful name on GitHub.

## Basic behaviour

I didn't want or need minute-by-minute checking for the kind of sites on my server. Every 15 minutes for the important sites is enough. Once per hour for everything less likely to fail independently, or generally less important. On a failure, it rechecks after a configurable delay (5 minutes by default) and only emails you if the service is still down at that point. A single blip that resolves itself before the recheck never triggers an email, but is still logged.

## Dependencies

### Required binaries

`bash`, `flock`, `curl`, `grep`, `cut`, `mv`, `date`, `timeout` - all standard on Debian/Raspbian.

### More unusual one

`/usr/sbin/sendmail` - not installed by default, but required to send email alerts. You'll need a mail transfer agent (e.g. `msmtp`, `postfix`, `exim4`) configured separately to provide this. If it's missing or misconfigured, the script won't error loudly - failed sends are logged to `failures.log` as `MAIL_FAIL`, so check there if alerts seem to have stopped arriving.

## User agent

It uses a custom user agent, `CodewordMonitor/1.0`, to allow whitelisting and avoid common blacklisting setups. Raspberry Pis and bare `curl`/bash user agents are both somewhat likely to get flagged by default firewall rules or bot protection.

## Disk writes

This script is designed to keep disk writes to an absolute minimum, only logging failures and updating status on changes. Along with other best practices, this allows it to run well on an older Pi with an SD for storage.

## Test mode

Run the script with `test` as the first argument to check everything without waiting for a scheduled run:

```
./pi-monitor.sh test
```

This checks every entry in both `CRITICAL_CHECKS` and `HOURLY_CHECKS`, and always emails you a pass/fail summary - even if everything passes. To test just one list:

```
./pi-monitor.sh test critical
./pi-monitor.sh test hourly
```

## Installation

### Script and environment file

1. Create the install folder:
   ```
   sudo mkdir -p /opt/pi-monitor
   ```
2. Copy `pi-monitor.sh` and `pi-monitor.env.example` from this repo into `/opt/pi-monitor` on your server, renaming the example env file to `pi-monitor.env`.
3. Make the script executable:
   ```
   sudo chmod +x /opt/pi-monitor/pi-monitor.sh
   ```
4. Edit `/opt/pi-monitor/pi-monitor.env` to match your setup. Please see the example provided.
5. If `sendmail` isn't already set up on this machine, sort that out before continuing - see Dependencies above.
6. Test your setup:
   ```
   cd /opt/pi-monitor
   ./pi-monitor.sh test
   ```
   You should receive a single email with a pass/fail summary for every check you configured and the overall result.

## Activating the service

1. Copy the unit files from this repo's `/etc/systemd/system/` folder to `/etc/systemd/system/` on your server:
2. Reload systemd so it picks up the new unit files:
   ```
   sudo systemctl daemon-reload
   ```
3. Enable and start both timers (not the services directly - the timers are what schedule the recurring runs):
   ```
   sudo systemctl enable --now pi-monitor.timer
   sudo systemctl enable --now pi-monitor-hourly.timer
   ```
4. The timers won't necessarily fire immediately. Depending on timing, the first scheduled run could be minutes away. To confirm everything works without waiting for them to fire, trigger each service manually now:
   ```
   sudo systemctl start pi-monitor.service
   sudo systemctl start pi-monitor-hourly.service
   ```
5. Confirm both timers are scheduled:
   ```
   systemctl list-timers --all | grep pi-monitor
   ```
   You should see two lines, one for each timer, each showing a "next" run time and a "last" run time (from the manual trigger above).
6. Check the status of each service:
   ```
   sudo systemctl status pi-monitor.service
   sudo systemctl status pi-monitor-hourly.service
   ```
   Since these are `Type=oneshot` services, they're expected to show `inactive (dead)` shortly after running - that is normal and not an error. You're looking for `status=0/SUCCESS` on the last run, on the `Main PID` line about halfway through. It will look something like this example, showing the hourly result:
   ```
   ○ pi-monitor-hourly.service - Pi Monitor (hourly)
        Loaded: loaded (/etc/systemd/system/pi-monitor-hourly.service; static)
        Active: inactive (dead) since Sun 2026-06-21 18:43:54 BST; 17min ago
    Invocation: d145f7b754554280a10602293bf987bc
   TriggeredBy: ● pi-monitor-hourly.timer
       Process: 6898 ExecStart=/opt/pi-monitor/pi-monitor.sh hourly (code=exited, status=0/SUCCESS)
      Main PID: 6898 (code=exited, status=0/SUCCESS)
           CPU: 7.141s
   Jun 21 18:43:41 yourserver systemd[1]: Starting pi-monitor-hourly.service - Pi Monitor (hourly)...
   Jun 21 18:43:54 yourserver systemd[1]: Deactivated successfully.
   Jun 21 18:43:54 yourserver systemd[1]: Finished pi-monitor-hourly.service - Pi Monitor (hourly).
   Jun 21 18:43:54 yourserver systemd[1]: Consumed 7.141s CPU time.
   ```
   If you see `status=1/FAILURE` or similar instead, check `journalctl -u pi-monitor-hourly.service` and `/opt/pi-monitor/failures.log` for details.
