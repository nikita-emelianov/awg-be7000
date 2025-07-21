# [AWG](https://github.com/amnezia-vpn/) for Xiaomi Router BE7000

Firmware Version used: `1.1.16`. This forwards all traffic from the guest network to the AmneziaWG server.

1.  Save your AmneziaWG server config in **AmneziaWG native format** as `amnezia_for_awg.conf`.

2.  [**SSH**](https://github.com/openwrt-xiaomi/xmir-patcher) to router:

* update or create your SSH config file (`~/.ssh/config`):

```
# Router
Host 192.168.31.1
HostKeyAlgorithms +ssh-rsa
PubkeyAcceptedAlgorithms +ssh-rsa
StrictHostKeyChecking no
UserKnownHostsFile /dev/null
LogLevel ERROR
```

* Connect: `ssh root@192.168.31.1`

3.  On the router, create `/data/usr/app/awg` and place `amnezia_for_awg.conf` inside. You can use `scp` from your local machine:

```bash
scp /path/to/amnezia_for_awg.conf root@192.168.31.1:/data/usr/app/awg/
```

4.  On the router, execute the following commands:

```bash
curl -L -o awg_setup.sh https://raw.githubusercontent.com/nikita-emelianov/awg-be7000/main/awg_setup.sh
chmod +x awg_setup.sh
./awg_setup.sh
```

note:
while running `./awg_setup.sh` you'll see error `Failed with exit code 1 from /etc/firewall.d/qca-nss-ecm` but it doesn't break your awg setup as it comes from a system script (/etc/firewall.d/qca-nss-ecm) that's called when firewall reloads.

-----

if you ever want to uninstall awg or start over with a fresh awg configuration, you'd run `clear_firewall_settings.sh` script
