# Preserve source file names and line numbers for readable crash diagnostics
-keepattributes SourceFile,LineNumberTable
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod

# kotlinx.serialization runtime & generated $$serializer classes
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class com.iosbox.app.**$$serializer { *; }
-keepclassmembers class com.iosbox.app.** {
    *** Companion;
}
-keepclasseswithmembers class com.iosbox.app.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-if @kotlinx.serialization.Serializable class **
-keepclassmembers class <1> {
    static <1>$Companion Companion;
}

# Room generated implementations and schema types
-keep class * extends androidx.room.RoomDatabase
-keep class com.iosbox.app.core.storage.FugueDatabase_Impl { *; }
-keep @androidx.room.Entity class com.iosbox.app.core.storage.** { *; }
-keep @androidx.room.Dao class com.iosbox.app.core.storage.** { *; }

# Keep AndroidManifest components and WebView/JS bridges intact if added later
-keepclassmembers class * extends android.app.Service {
    public <init>();
}

# Optional JVM/TLS providers referenced defensively by OkHttp, Tink, and Protobuf
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn org.codehaus.mojo.animal_sniffer.**
-dontwarn sun.misc.Unsafe

# PDFBox Android font/CMap resources & optional desktop/crypto refs
-keep class com.tom_roush.pdfbox.pdmodel.font.** { *; }
-dontwarn com.tom_roush.pdfbox.**
-dontwarn com.tom_roush.fontbox.**
-dontwarn java.awt.**
-dontwarn javax.imageio.**
