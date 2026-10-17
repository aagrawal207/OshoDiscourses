import com.agraabhi.oshodiscourses.buildlogic.bundle
import com.agraabhi.oshodiscourses.buildlogic.libs
import io.github.takahirom.roborazzi.RoborazziExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.tasks.testing.Test
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies
import org.gradle.kotlin.dsl.withType

/**
 * Robolectric + Roborazzi screenshot tests on the JVM. Reference images live in
 * `src/test/screenshots` so `verifyRoborazziDebug` can compare against them.
 */
class AndroidScreenshotConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("io.github.takahirom.roborazzi")

        extensions.configure<RoborazziExtension> {
            outputDir.set(layout.projectDirectory.dir("src/test/screenshots"))
        }

        tasks.withType<Test>().configureEach {
            // Native graphics renders real pixels; the legacy mode draws nothing.
            systemProperty("robolectric.graphicsMode", "NATIVE")
            systemProperty("robolectric.pixelCopyRenderMode", "hardware")
            maxHeapSize = "2g"
        }

        val catalog = libs
        dependencies {
            add("testImplementation", catalog.bundle("screenshot-test"))
        }
    }
}
