import com.agraabhi.oshodiscourses.buildlogic.lib
import com.agraabhi.oshodiscourses.buildlogic.libs
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.dependencies

/**
 * A feature screen module. Features see only `:core:*`; `:app` wires the
 * implementation modules behind the `:core:domain` contracts.
 */
class AndroidFeatureConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("osho.android.library.compose")
        pluginManager.apply("osho.android.screenshot")

        val catalog = libs
        dependencies {
            add("implementation", project(":core:model"))
            add("implementation", project(":core:domain"))
            add("implementation", project(":core:ui"))
            // Fakes back previews; R8 drops them from release since nothing else references them.
            add("implementation", project(":core:testing"))
            add("testImplementation", project(":core:testing"))

            add("implementation", catalog.lib("androidx-lifecycle-runtime-compose"))
            add("implementation", catalog.lib("androidx-lifecycle-viewmodel-compose"))
            add("implementation", catalog.lib("androidx-navigation3-runtime"))
            add("implementation", catalog.lib("kotlinx-serialization-json"))
            add("implementation", catalog.lib("coil-compose"))
            add("implementation", catalog.lib("haze"))
            add("implementation", catalog.lib("haze-blur"))
            add("implementation", catalog.lib("haze-materials"))
        }
    }
}
