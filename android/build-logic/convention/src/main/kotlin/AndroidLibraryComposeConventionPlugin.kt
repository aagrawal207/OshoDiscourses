import com.agraabhi.oshodiscourses.buildlogic.configureCompose
import org.gradle.api.Plugin
import org.gradle.api.Project

/** An Android library with Compose UI. */
class AndroidLibraryComposeConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("osho.android.library")
        configureCompose()
    }
}
