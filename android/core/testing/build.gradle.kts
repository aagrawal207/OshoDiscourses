plugins {
    alias(libs.plugins.osho.jvm.library)
}

dependencies {
    api(projects.core.domain)
    api(libs.kotlinx.coroutines.core)
}
