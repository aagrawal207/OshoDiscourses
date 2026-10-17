plugins {
    alias(libs.plugins.osho.android.library)
}

android {
    ndkVersion = libs.versions.ndk.get()

    defaultConfig {
        // DeepFilterNet ships prebuilt for these ABIs only; see scripts/build-deepfilter.sh.
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        consumerProguardFiles("consumer-rules.pro")
    }

    // Signal fixtures shared by the JVM tests and the native instrumented tests.
    sourceSets {
        getByName("test").kotlin.srcDir("src/sharedTest/kotlin")
        getByName("androidTest").kotlin.srcDir("src/sharedTest/kotlin")
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.31.6"
        }
    }
}

/**
 * Stages only the bundled DeepFilterNet model as a generated asset. Pointing assets at the
 * iOS Resources folder would also package its catalogs, storyboard and Swift files.
 */
abstract class StageDeepFilterModel : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val model: RegularFileProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun stage() {
        val directory = outputDir.get().asFile
        directory.deleteRecursively()
        directory.mkdirs()
        // AGP gunzips assets ending in .gz, but the bridge reads the gzip archive itself.
        model.get().asFile.copyTo(directory.resolve("DeepFilterNet3_onnx.model"))
    }
}

val stageDeepFilterModel = tasks.register<StageDeepFilterModel>("stageDeepFilterModel") {
    model.set(layout.projectDirectory.file("../../OshoDiscourses/Resources/DeepFilterNet3_onnx.tar.gz"))
    outputDir.set(layout.buildDirectory.dir("generated/deepfilterModel"))
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(stageDeepFilterModel, StageDeepFilterModel::outputDir)
    }
}

dependencies {
    api(projects.core.domain)
    implementation(libs.androidx.media3.common)
    implementation(libs.androidx.media3.exoplayer)

    testImplementation(projects.core.testing)
    testImplementation(libs.robolectric)

    androidTestImplementation(projects.core.testing)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.junit4)
    androidTestImplementation(libs.kotlin.test)
    androidTestImplementation(libs.truth)
    androidTestImplementation(libs.kotlinx.coroutines.test)
}
