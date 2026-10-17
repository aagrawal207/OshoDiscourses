import com.agraabhi.oshodiscourses.buildlogic.bundle
import com.agraabhi.oshodiscourses.buildlogic.libs
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies
import org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension

/** A pure Kotlin module with no Android dependency. */
class JvmLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("org.jetbrains.kotlin.jvm")
        pluginManager.apply("org.jetbrains.kotlin.plugin.serialization")

        extensions.configure<KotlinJvmProjectExtension> {
            jvmToolchain(21)
        }

        // Same task name as Android modules, so one `testDebugUnitTest` runs every unit test.
        tasks.register("testDebugUnitTest") {
            group = "verification"
            dependsOn(tasks.named("test"))
        }

        val catalog = libs
        dependencies {
            add("testImplementation", catalog.bundle("jvm-test"))
        }
    }
}
