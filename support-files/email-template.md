Salaam,

Before you do anything, first check your current public IP assigned by your local ISP and write it down. After the VPN is active, this IP should no longer be visible to the websites on the internet — they will see the VPN server's IP instead.

You can use:

* https://www.whatismyip.com/ (in your browser)
* `curl -4 ifconfig.me` (on the command line)

## Installation and configuration:

1. Save the attached `.conf` file at a secure place on your computer. Then, rename the file to a smaller name such as `wg-yourname.conf`.
2. Download and install WireGuard from https://wireguard.com/install
3. Open the WireGuard application on your computer, and import the tunnel configuration using the file you saved (and renamed) in step 1.
4. Click **Activate**.

## Verification / validation:

* After the tunnel is active, visit the two URLs provided below to check if they show the public IP of the VPN server instead of the IP assigned to you from your ISP. All traffic from your computer must now show up as originating from the VPN server including  - **very important** - the DNS traffic. 
* Search the ipleak.net web-page. There should be no mention of your country or city or your isp, etc. **This is important to verify.**

* https://www.whatismyip.com/
* https://ipleak.net

Regards,
Kamran
