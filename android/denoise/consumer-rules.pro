# JNI resolves these by their mangled Java names, so R8 must not rename them.
-keepclasseswithmembernames class com.agraabhi.oshodiscourses.denoise.nativebridge.** {
    native <methods>;
}
