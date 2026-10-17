# kotlinx.serialization, Media3, Play Billing, Play Review and Play services ship their own consumer rules.

# review-ktx is built against a newer Play services annotation that is compile-time only.
-dontwarn com.google.android.gms.common.annotation.NoNullnessRewrite
