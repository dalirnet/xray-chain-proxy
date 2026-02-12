# دستورات

## راه‌اندازی

### `setup gateway`

نصب و پیکربندی به عنوان نود خروجی.

```bash
./xcp.sh setup gateway
```

![Setup Gateway](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/setup-gateway.gif)

### `setup edge`

نصب و پیکربندی به عنوان نود ورودی.

```bash
./xcp.sh setup edge
```

![Setup Edge](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/setup-edge.gif)

## کنترل سرویس

### `start`

```bash
./xcp.sh start
```

### `stop`

```bash
./xcp.sh stop
```

### `restart`

```bash
./xcp.sh restart
```

### `status`

```bash
./xcp.sh status
```

وضعیت اجرا و نسخه Xray را نمایش می‌دهد.

![Status](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/status.gif)

## مدیریت کاربران

### `user ls`

لیست همه کاربران با رمز عبور و URI.

```bash
./xcp.sh user ls
```

خروجی:

```
Server: 5.6.7.8
Ports: SS:443 | HTTP:80 | SOCKS5:1080

Accounts:

1) edge
   Password: xxxxxxxx
   SS URI: ss://...
```

### `user add`

افزودن کاربر جدید.

```bash
./xcp.sh user add
```

- نام کاربری: شناسه یکتا
- رمز عبور: خالی بگذارید برای تولید خودکار

اگر `qrencode` نصب باشد، QR کد نمایش می‌دهد.

![User Add](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/user-add.gif)

### `user rm`

حذف کاربر.

```bash
./xcp.sh user rm
```

## مانیتورینگ

### `stats`

آمار ترافیک هر کاربر.

```bash
./xcp.sh stats
```

![Stats](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/stats.gif)

خروجی:

```
Users:
  edge: ↑1.2 MB ↓15.3 MB
  user1: ↑500 KB ↓2.1 MB

System:
  Inbound:  ↑1.7 MB ↓17.4 MB
  Outbound: ↑17.4 MB ↓1.7 MB
```

### `logs`

مشاهده لاگ‌ها.

```bash
# ۵۰ خط آخر (پیش‌فرض)
./xcp.sh logs

# ۱۰۰ خط آخر
./xcp.sh logs 100

# دنبال کردن لحظه‌ای
./xcp.sh logs -f
```

### `test`

تست اتصال پروکسی و سرعت.

```bash
./xcp.sh test
```

![Test](https://raw.githubusercontent.com/dalirnet/xray-chain-proxy/main/showcase/gif/test.gif)

## پیکربندی

### `config ls`

نمایش تنظیمات فعلی.

```bash
./xcp.sh config ls
```

خروجی:

```
Config:

  Type:       edge
  Version:    2.0.0
  SS Port:    443
  HTTP Port:  80
  SOCKS Port: 1080
  Log level:  error
  Gateway:    1.2.3.4:443
```

### `config set`

تغییر تنظیمات.

```bash
./xcp.sh config set
```

گزینه‌ها:

1. `loglevel` - سطح لاگ (none/warning/info/debug)
2. `port` - تغییر پورت‌ها

## قوانین مسیریابی

### `rule ls`

لیست همه قوانین مسیریابی سفارشی.

```bash
./xcp.sh rule ls
```

شماره قانون، تگ خروجی و دامنه‌ها/IPهای منطبق را نمایش می‌دهد.

### `rule add`

افزودن قانون مسیریابی جدید به صورت تعاملی.

```bash
./xcp.sh rule add
```

خروجی (direct/proxy/blocked)، نوع قانون و مقادیر را درخواست می‌کند.

برای مثال‌های کامل به [قوانین مسیریابی](routing.md) مراجعه کنید.

### `rule rm`

حذف قانون مسیریابی با شماره.

```bash
./xcp.sh rule rm
```

قوانین فعلی را نمایش داده، شماره قانون را برای حذف درخواست می‌کند.

## نگهداری

### `update`

بروزرسانی اسکریپت و Xray به آخرین نسخه.

```bash
./xcp.sh update
```

منوی تعاملی برای بروزرسانی:
- فقط اسکریپت (از GitHub)
- فقط Xray
- هر دو (پیشنهادی)

تنظیمات حفظ می‌شود. نسخه پشتیبان اسکریپت به عنوان `script.sh.bak` ذخیره می‌شود.

### `uninstall`

حذف کامل Xray.

```bash
./xcp.sh uninstall
```

باینری، تنظیمات، لاگ‌ها و سرویس systemd حذف می‌شود.
