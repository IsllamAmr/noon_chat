# ترقية المشروع (Project Upgrade)

تم ترقية مشروع **Noon Chat** إلى إصدارات حديثة من FlutterFire وباقي الحزم.

## ما تم ترقيته

### إصدار التطبيق
- **قبل:** 1.0.1+1002  
- **بعد:** 1.0.2+1003  

### بيئة Dart
- **قبل:** `sdk: ^3.10.7`  
- **بعد:** `sdk: ">=3.2.0 <4.0.0"` (متوافق مع FlutterFire 4.x)

### حزم Firebase (FlutterFire BoM 4.10.0)
| الحزمة | قبل | بعد |
|--------|-----|-----|
| firebase_core | ^3.0.0 | ^4.5.0 |
| firebase_auth | ^5.0.0 | ^6.2.0 |
| cloud_firestore | ^5.0.0 | ^6.1.3 |
| firebase_storage | ^12.0.0 | ^13.1.0 |
| firebase_messaging | ^15.2.4 | ^16.1.2 |
| cloud_functions | ^5.0.0 | ^6.0.7 |

### ملاحظات
- كود التطبيق (مثل `Firebase.initializeApp()`) بقي كما هو ومتوافق مع الإصدارات الجديدة.
- تأكد من وجود `google-services.json` (Android) و `GoogleService-Info.plist` (iOS) في المشروع.

## خطوات بعد الترقية

1. **تثبيت Flutter** إن لم يكن مثبتاً:  
   [https://docs.flutter.dev/get-started/install](https://docs.flutter.dev/get-started/install)

2. **من مجلد المشروع نفّذ:**
   ```bash
   flutter pub get
   flutter run
   ```

3. **(اختياري)** لتوليد خيارات Firebase من FlutterFire CLI:
   ```bash
   dart pub global activate flutterfire_cli
   flutterfire configure
   ```
   ثم في `main.dart` يمكن استخدام:
   ```dart
   await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
   ```

---

*تمت الترقية في مارس 2026.*
