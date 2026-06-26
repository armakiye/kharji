# راهنمای build اپ ردیاب هزینه

## روش ۱ — آسان‌ترین: Codemagic (آنلاین، رایگان)

بهترین گزینه برای کسی که Android Studio نصب نداره.

### مراحل:
1. برو روی https://codemagic.io و اکانت رایگان بساز
2. فایل‌های پروژه رو zip کن و آپلود کن
   (یا پروژه رو توی GitHub بذار و وصل کن)
3. گزینه Flutter رو انتخاب کن
4. روی Build بزن
5. APK رو دانلود کن

زمان build: ~5 دقیقه
محدودیت رایگان: 500 دقیقه در ماه ✓

---

## روش ۲ — Flutter روی ویندوز/مک

### پیش‌نیازها:
- Flutter SDK: https://flutter.dev/docs/get-started/install
- Android Studio: https://developer.android.com/studio
- Java 17+

### مراحل:
```bash
# ۱. وارد پوشه پروژه شو
cd sms_expense

# ۲. پکیج‌ها رو نصب کن
flutter pub get

# ۳. APK بساز
flutter build apk --release

# فایل APK اینجاست:
# build/app/outputs/flutter-apk/app-release.apk
```

---

## روش ۳ — GitHub + GitHub Actions (رایگان، خودکار)

1. یه repo جدید توی GitHub بساز
2. فایل‌های پروژه رو push کن
3. فایل `.github/workflows/build.yml` بساز:

```yaml
name: Build APK
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.19.0'
      - run: flutter pub get
      - run: flutter build apk --release
      - uses: actions/upload-artifact@v3
        with:
          name: app-release
          path: build/app/outputs/flutter-apk/app-release.apk
```

4. بعد از push، توی Actions > Artifacts فایل APK رو دانلود کن

---

## نصب APK روی گوشی

1. APK رو به گوشی منتقل کن
2. توی تنظیمات > امنیت > «نصب از منابع ناشناس» رو فعال کن
3. فایل APK رو باز کن و نصب کن
4. اول باز کردن: مجوز دسترسی به پیامک رو بده

---

## نکته مهم

بعد از نصب، اپ خودکار پیامک‌های بانکی امروز رو اسکن می‌کنه.
برای اسکن دستی دکمه 🔄 بالای صفحه رو بزن.
