# ============================================================
# 高德地图 / 定位 / 搜索 SDK 的 ProGuard/R8 保留规则
# 原因：AMap SDK 以纯 JAR（非 AAR）发布，未携带 consumer 混淆规则；
#       Release 开启 R8 后会把未被直接引用的 SDK 类剥离，
#       导致启动时（定位隐私初始化 / 地图创建）崩溃。
# ============================================================
-keep class com.amap.api.** { *; }
-keep class com.autonavi.** { *; }
-keep class com.loc.** { *; }
-keep class com.amap.flutter.** { *; }
-dontwarn com.amap.api.**
-dontwarn com.autonavi.**
-dontwarn com.loc.**

# 高德定位服务（AndroidManifest 中声明）
-keep class com.amap.api.location.APSService { *; }
