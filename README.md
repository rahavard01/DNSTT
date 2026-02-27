# DNSTT Emergency Tunnel — IR (ENTRY) -> DNS Tunnel -> FR (EXIT) for V2Ray/Xray

این پروژه برای شرایط اضطراری فیلترینگ ساخته شده:
کاربر فقط با **V2Ray/وی‌تورای** به **IP ایران** وصل می‌شود، اما سرور ایران ترافیک را از طریق **DNSTT (DNS Tunnel)** به سرور خارج منتقل می‌کند.

> DNSTT خودش TUN/SOCKS نمی‌دهد و یک اتصال TCP forward شبیه netcat است؛ برای اینکه مثل پراکسی کار کند، روی سرور خارج یک SOCKS5 واقعی پشت DNSTT قرار می‌دهیم. :contentReference[oaicite:3]{index=3}

---

## معماری

- **User (V2Ray client / V2RayN / v2rayNG / ...)** → فقط به `IR_PUBLIC_IP:PORT` وصل می‌شود
- **IR / ENTRY**
  - Xray/V2Ray inbound می‌گیرد
  - outbound را به `127.0.0.1:1080` (لوکال) می‌فرستد
  - روی IR یک `dnstt-client` اجرا می‌شود و پورت `127.0.0.1:1080` را فراهم می‌کند
- **FR / EXIT**
  - `dnstt-server` روی UDP اجرا می‌شود و با NAT، پورت 53 به آن هدایت می‌شود
  - پشت آن یک SOCKS5 server (microsocks) روی `127.0.0.1:8000` اجرا می‌شود

---

## پیش‌نیازها

- Ubuntu/Debian روی هر دو سرور
- دسترسی root/sudo
- یک دامنه که بتوانید NS آن را تنظیم کنید
- UDP/53 روی سرور خارج باید قابل دریافت باشد (Authoritative DNS)
- روی سرور ایران باید بتوانید به یک Resolver (DoH/DoT/UDP) دسترسی داشته باشید

DNSTT برای کار کردن نیاز دارد سرور خارج **Authoritative** یک ساب‌دامنه باشد و Recursive Resolver وسط، Query ها را به آن فوروارد کند. :contentReference[oaicite:4]{index=4}

---

Setup روی FR (سرور خارج / EXIT)

روی FR:

sudo dnstt

گزینه:

2) Setup FR (EXIT server)

اسکریپت:

dnstt را build می‌کند

microsocks را نصب/اجرا می‌کند

کلیدهای server را می‌سازد

dnstt-server را به‌صورت systemd راه‌اندازی می‌کند

NAT برای UDP/53 -> UDP/5300 می‌گذارد

در پایان یک TOKEN می‌دهد

✅ TOKEN را کپی کنید.

Setup روی IR (سرور ایران / ENTRY)

روی IR:

sudo dnstt

گزینه:

3) Setup IR (ENTRY server)

سپس:

TOKEN را Paste می‌کنید

Mode را انتخاب می‌کنید:

doh (پیشنهادی برای شرایط سخت)

dot

udp

Resolver را وارد می‌کنید (مثلاً DoH URL)

local port را تعیین می‌کنید (پیش‌فرض 1080)

بعد از پایان:

روی IR یک پورت لوکال دارید: 127.0.0.1:1080

اتصال به Xray/V2Ray روی IR (برای اینکه کاربر فقط وی‌تورای بزند)

روی سرور ایران، در کانفیگ Xray/V2Ray شما:

Outbound را SOCKS5 بگذارید به:

Address: 127.0.0.1

Port: 1080

از این به بعد:
کاربر به IP ایران وصل می‌شود، و خروجی ایران از DNSTT رد می‌شود.

Status / Restart / Logs

منو:

sudo dnstt

یا دستورها:

sudo dnstt.sh status
sudo dnstt.sh restart

لاگ‌ها:

/var/log/dnstt/dnstt-fr.log

/var/log/dnstt/dnstt-ir.log

Uninstall
sudo dnstt.sh uninstall

---

## 1-line Install (از GitHub)

روی هر دو سرور (IR و FR):

```bash
curl -fsSL https://raw.githubusercontent.com/rahavard01/DNSTT/main/dnstt.sh | sudo bash -s -- install
