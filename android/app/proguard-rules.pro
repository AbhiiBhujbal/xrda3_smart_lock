# Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }

# Tuya / ThingClips
-keep class com.thingclips.**{*;}
-keep class com.alibaba.fastjson.**{*;}
-dontwarn com.alibaba.fastjson.**
-keep class com.thingclips.smart.mqttclient.mqttv3.** { *; }

# OkHttp & Okio
-keep class okhttp3.** { *; }
-keep class okio.** { *; }

# Matter SDK
-keep class chip.** { *; }
-dontwarn chip.**
