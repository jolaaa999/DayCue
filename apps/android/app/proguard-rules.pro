# R8 规则。本工程没有反射驱动的框架（Room 用生成代码，Compose 用编译器插件），
# 所以只需要处理「序列化」和「协程」这两处已知会被裁掉的东西。

# kotlinx.serialization：@Serializable 类在运行期靠生成的 Companion 反查序列化器，
# 泛型签名被裁掉时会抛 SerializationException，因此保留。
-keepattributes *Annotation*, InnerClasses, Signature, RuntimeVisibleAnnotations
-keepclassmembers class **$$serializer { *; }
-keepclasseswithmembers class * {
    kotlinx.serialization.KSerializer serializer(...);
}
-if @kotlinx.serialization.Serializable class **
-keepclassmembers class <1> {
    static <1>$Companion Companion;
}

# OkHttp：4.x 内部有可选的 Conscrypt/BouncyCastle 引用，缺失时会被它自己 catch 掉。
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**

# WorkManager 的 Worker 由系统按类名实例化，名字不能被混淆。
-keep class * extends androidx.work.ListenableWorker { public <init>(...); }

# 契约模型：将来若给数据类加了默认值与 when 分支，保留行号便于定位后端契约不匹配的问题。
-keepattributes SourceFile, LineNumberTable
