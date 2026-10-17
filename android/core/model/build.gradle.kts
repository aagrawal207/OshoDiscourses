plugins {
    alias(libs.plugins.osho.jvm.library)
}

// The iOS app's shipped catalogs are the single source; they load from the
// classpath instead of being copied. Assets.xcassets holds Contents.json files.
sourceSets {
    main {
        resources {
            srcDir(rootDir.resolve("../OshoDiscourses/Resources"))
            include("**/*.json")
            exclude("Assets.xcassets/**")
        }
    }
}

dependencies {
    api(libs.kotlinx.serialization.json)
}
