# [AWG](https://github.com/amnezia-vpn/) for Xiaomi Router BE7000

**Firmware version used:** `1.1.16`\
This setup forwards all traffic from the **guest network** to the
AmneziaWG server.

------------------------------------------------------------------------

## 1. Prepare AmneziaWG config

Save your AmneziaWG server config in **AmneziaWG native format** as:

    amnezia_for_awg.conf

> ⚠️ Important: Remove empty `I2–I5` fields from the config, otherwise
> it will not work.

------------------------------------------------------------------------

## 2. SSH into the router

Use **xmir-patcher**:

👉 https://github.com/openwrt-xiaomi/xmir-patcher

**Note for macOS:**

-   `xmir-patcher` strictly requires **Python 3.12**

### Optional: simplify SSH access

Update or create your SSH config at `~/.ssh/config`:

``` ssh
# Router
Host 192.168.31.1
HostKeyAlgorithms +ssh-rsa
PubkeyAcceptedAlgorithms +ssh-rsa
StrictHostKeyChecking no
UserKnownHostsFile /dev/null
LogLevel ERROR
```

### Connect to router

``` bash
ssh root@192.168.31.1
```

------------------------------------------------------------------------

## 3. Upload config to router

On the router, create directory:

``` bash
/data/usr/app/awg
```

Upload the config from your local machine:

``` bash
scp -O /path/to/amnezia_for_awg.conf root@192.168.31.1:/data/usr/app/awg/
```

------------------------------------------------------------------------

## 4. Run AWG setup

On the router:

``` bash
curl -L -o awg_setup.sh https://raw.githubusercontent.com/nikita-emelianov/awg-be7000/refs/heads/main/awg_setup.sh
chmod +x awg_setup.sh
./awg_setup.sh
```

### Known warning

During execution you may see:

    Failed with exit code 1 from /etc/firewall.d/qca-nss-ecm

✅ This **does NOT break** the AWG setup.\
It comes from a system script triggered during firewall reload.

------------------------------------------------------------------------

## Uninstall / reset AWG

To completely reset firewall changes and start fresh, run:

    awg_clear_firewall_settings.sh

------------------------------------------------------------------------

# Building binaries (macOS)

------------------------------------------------------------------------

## 1. Build amneziawg-go

Repository:

👉 https://github.com/amnezia-vpn/amneziawg-go

``` bash
git clone https://github.com/amnezia-vpn/amneziawg-go
cd amneziawg-go

# IMPORTANT: router requires arm64 build
GOOS=linux GOARCH=arm64 make
```

Place the resulting `amneziawg-go` binary into your repo.

------------------------------------------------------------------------

## 2. Build amneziawg-tools

Repository:

👉 https://github.com/amnezia-vpn/amneziawg-tools

``` bash
git clone https://github.com/amnezia-vpn/amneziawg-tools
cd amneziawg-tools/src
```

### Build via Docker (recommended)

After multiple attempts, Docker proved to be the only reliable method.

``` bash
docker run -it --rm -v "$(pwd)":/build ubuntu:22.04

apt update
apt install -y build-essential gcc-aarch64-linux-gnu

cd /build
make CC=aarch64-linux-gnu-gcc LDFLAGS="-static"
```

Place the resulting `wg` binary into your repo.

------------------------------------------------------------------------
