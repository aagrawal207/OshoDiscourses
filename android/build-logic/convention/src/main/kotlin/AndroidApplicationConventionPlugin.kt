import com.agraabhi.oshodiscourses.buildlogic.configureAndroidApplication
import com.agraabhi.oshodiscourses.buildlogic.configureCompose
import org.gradle.api.Plugin
import org.gradle.api.Project

/** The `:app` module: Android application with Compose. */
class AndroidApplicationConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("com.android.application")
        pluginManager.apply("org.jetbrains.kotlin.plugin.serialization")
        configureAndroidApplication()
        configureCompose()
    }
}
