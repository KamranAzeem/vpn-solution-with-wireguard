Salaam,

Attached is the config file for you to set up a VPN tunnel on your computer. Before you activate it, first check your current public IP assigned by your local ISP and write it down. After the VPN is active, this IP should no longer be visible to the websites on the internet — they will see the VPN server's IP instead.

You can use:

* https://www.whatismyip.com/ (in your browser)
* `curl -4 ifconfig.me` (on the command line)

## Installation and configuration:

1. Save the attached `.conf` file at a secure place on your computer.
2. Download and install WireGuard from https://wireguard.com/install
3. Open the WireGuard application on your computer, and import the tunnel configuration using the file you saved in step 1.
4. Click **Activate**.

Server endpoint: __SERVER_ENDPOINT__:__SERVER_PORT__
Your VPN IP: __CLIENT_IP__

## Verification / validation:

After the tunnel is active, visit the following URLs to check if they show the public IP of the VPN server instead of the IP assigned to you from your ISP:

* https://www.whatismyip.com/
* https://ipleak.net

There should be no mention of your country, city, or ISP on ipleak.net.

Regards,
Kamran
