# کلاینت‌ها

اپلیکیشن‌های گرافیکی برای اتصال به سرور پروکسی.

## اندروید

| اپلیکیشن    | پروتکل | لینک                                                                                                                                              |
| ----------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| v2rayNG     | همه    | [GitHub](https://github.com/2dust/v2rayNG) / [Play Store](https://play.google.com/store/apps/details?id=com.v2ray.ang)                            |
| SagerNet    | همه    | [GitHub](https://github.com/SagerNet/SagerNet)                                                                                                    |
| Shadowsocks | SS     | [GitHub](https://github.com/shadowsocks/shadowsocks-android) / [Play Store](https://play.google.com/store/apps/details?id=com.github.shadowsocks) |

## iOS

| اپلیکیشن     | پروتکل | لینک                                                                         |
| ------------ | ------ | ---------------------------------------------------------------------------- |
| Shadowrocket | همه    | [App Store](https://apps.apple.com/app/shadowrocket/id932747118) (پولی)      |
| Streisand    | همه    | [App Store](https://apps.apple.com/app/streisand/id6450534064)               |
| OneClick     | همه    | [App Store](https://apps.apple.com/app/oneclick-safe-easy-fast/id1545555197) |

## ویندوز

| اپلیکیشن    | پروتکل | لینک                                                         |
| ----------- | ------ | ------------------------------------------------------------ |
| v2rayN      | همه    | [GitHub](https://github.com/2dust/v2rayN)                    |
| Nekoray     | همه    | [GitHub](https://github.com/MatsuriDayo/nekoray)             |
| Shadowsocks | SS     | [GitHub](https://github.com/shadowsocks/shadowsocks-windows) |

## مک

| اپلیکیشن        | پروتکل | لینک                                                     |
| --------------- | ------ | -------------------------------------------------------- |
| V2rayU          | همه    | [GitHub](https://github.com/yanue/V2rayU)                |
| Nekoray         | همه    | [GitHub](https://github.com/MatsuriDayo/nekoray)         |
| ShadowsocksX-NG | SS     | [GitHub](https://github.com/shadowsocks/ShadowsocksX-NG) |

## لینوکس

| اپلیکیشن    | پروتکل | لینک                                                       |
| ----------- | ------ | ---------------------------------------------------------- |
| Nekoray     | همه    | [GitHub](https://github.com/MatsuriDayo/nekoray)           |
| v2rayA      | همه    | [GitHub](https://github.com/v2rayA/v2rayA)                 |
| Shadowsocks | SS     | [GitHub](https://github.com/shadowsocks/shadowsocks-libev) |

## تنظیمات اتصال

از این تنظیمات در کلاینت خود استفاده کنید:

| تنظیم    | مقدار                                                     |
| -------- | --------------------------------------------------------- |
| Server   | آی‌پی سرور EDGE                                           |
| Port     | 443 (VLESS) / 8388 (Shadowsocks)                          |
| Method   | `aes-256-gcm`                                             |
| Password | از `./xcp.sh user ls`                                     |

**VLESS + REALITY** گزینه اصلی روی شبکه‌های محدودشده است: پورت ۴۴۳ را در اختیار می‌گیرد، دست‌دادن TLS یک سایت واقعی را قرض می‌گیرد و UDP را حمل می‌کند. دستور `./xcp.sh user ls` یک لینک اشتراک چاپ می‌کند که v2rayNG، Hiddify، Streisand، NekoBox، v2rayN و sing-box مستقیم وارد می‌کنند، و `user add` همان را به شکل QR کد نشان می‌دهد.

**Shadowsocks** گزینه سازگاری است و روی هر دو نقش کار می‌کند. یک حساب هر دو پروتکل را پوشش می‌دهد.
