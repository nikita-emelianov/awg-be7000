# [AWG](https://github.com/amnezia-vpn/) for Xiaomi Router BE7000

Firmware Version used: `1.1.16`.\
This forwards all traffic from the guest network to the AmneziaWG
server.

1.  Save your AmneziaWG server config in **AmneziaWG native format** as
    `amnezia_for_awg.conf`

2.  SSH to router:

-   https://github.com/openwrt-xiaomi/xmir-patcher
-   xmir-patcher on macOS strictly requires Python 3.12 to run

To enable easy SSH access, update or create your SSH config file
(`~/.ssh/config`):

``` ssh
# Router
Host 192.168.31.1
HostKeyAlgorithms +ssh-rsa
PubkeyAcceptedAlgorithms +ssh-rsa
StrictHostKeyChecking no
UserKnownHostsFile /dev/null
LogLevel ERROR
```

Connect:

``` bash
ssh root@192.168.31.1
```

3.  On the router, create `/data/usr/app/awg` and place
    `amnezia_for_awg.conf` inside.

You can use `scp` from your local machine.\
Note: remove empty I2--I5 from the config to make it work.

``` bash
scp -O /path/to/amnezia_for_awg.conf root@192.168.31.1:/data/usr/app/awg/
```

4.  On the router, execute:

``` bash
curl -L -o awg_setup.sh https://raw.githubusercontent.com/nikita-emelianov/awg-be7000/refs/heads/main/awg_setup.sh
chmod +x awg_setup.sh
./awg_setup.sh
```

Note:

While running `./awg_setup.sh` you may see the error:

    Failed with exit code 1 from /etc/firewall.d/qca-nss-ecm

This does not break the AWG setup. It comes from a system script
triggered during firewall reload.

------------------------------------------------------------------------

If you ever want to uninstall AWG or start over with a fresh
configuration, run:

    awg_clear_firewall_settings.sh

------------------------------------------------------------------------

## Building sources (macOS)

### 1. amneziawg-go

https://github.com/amnezia-vpn/amneziawg-go

``` bash
git clone https://github.com/amnezia-vpn/amneziawg-go
cd amneziawg-go

# important for router architecture
GOOS=linux GOARCH=arm64 make
```

Place the built `amneziawg-go` binary into the repo.

------------------------------------------------------------------------

### 2. amneziawg-tools

https://github.com/amnezia-vpn/amneziawg-tools

``` bash
git clone https://github.com/amnezia-vpn/amneziawg-tools
cd amneziawg-tools/src
```

I tried many approaches --- only Docker worked reliably:

``` bash
docker run -it --rm -v "$(pwd)":/build ubuntu:22.04

apt update
apt install -y build-essential gcc-aarch64-linux-gnu

cd /build
make CC=aarch64-linux-gnu-gcc LDFLAGS="-static"
```

Place the resulting `wg` binary into the repo.
