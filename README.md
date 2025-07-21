# [AWG](https://github.com/amnezia-vpn/) for Xiaomi Router BE7000
firmware Version 1.1.16
forwards all traffic from the guest network to the AmneziaWG server

1. Save the config in _AmneziaWG native format_ as `amnezia_for_awg.conf`
2. [SSH](https://github.com/openwrt-xiaomi/xmir-patcher), create a `/data/usr/app/awg` directory, put `amnezia_for_awg.conf`
3. On the router execute the following command: `curl -L -o awg_setup.sh https://raw.githubusercontent.com/nikita-emelianov/awg-be7000/refs/heads/main/awg_setup.sh`
4. run `chmod +x awg_setup.sh`
5. run `./awg_setup.sh`
